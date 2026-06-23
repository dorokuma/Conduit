import 'package:conduit/features/hosts/data/dartssh2_ssh_key_service.dart';
import 'package:conduit/features/hosts/domain/ssh_key.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  const service = Dartssh2SshKeyService();

  group('generateEd25519', () {
    test('produces a parsable, unencrypted Ed25519 key', () {
      final generated = service.generateEd25519(comment: 'me@conduit');

      expect(generated.details.algorithm, SshKeyAlgorithm.ed25519);
      expect(generated.details.comment, 'me@conduit');
      expect(generated.details.isSecurityKey, isFalse);
      expect(generated.details.fingerprintSha256, startsWith('SHA256:'));
      expect(generated.details.publicKeyOpenSsh, startsWith('ssh-ed25519 '));
      expect(generated.details.publicKeyOpenSsh, endsWith(' me@conduit'));

      expect(SSHKeyPair.isEncryptedPem(generated.privateKeyPem), isFalse);
      final pairs = SSHKeyPair.fromPem(generated.privateKeyPem);
      expect(pairs, isNotEmpty);
    });

    test('every generated key is unique', () {
      final a = service.generateEd25519();
      final b = service.generateEd25519();
      expect(a.details.fingerprintSha256, isNot(b.details.fingerprintSha256));
    });

    test('round-trips through inspect as valid', () {
      final generated = service.generateEd25519(comment: 'label');
      final inspection = service.inspect(generated.privateKeyPem);

      expect(inspection.status, SshKeyStatus.valid);
      expect(inspection.isUsable, isTrue);
      expect(
        inspection.details?.fingerprintSha256,
        generated.details.fingerprintSha256,
      );
    });

    test('encrypts the key when a passphrase is given', () {
      final generated = service.generateEd25519(
        comment: 'locked@conduit',
        passphrase: 's3cret pass',
      );

      expect(SSHKeyPair.isEncryptedPem(generated.privateKeyPem), isTrue);
      expect(generated.details.algorithm, SshKeyAlgorithm.ed25519);

      final pairs = SSHKeyPair.fromPem(generated.privateKeyPem, 's3cret pass');
      expect(pairs, isNotEmpty);
      expect(pairs.first.toPublicKey().encode(), isNotEmpty);
    });

    test('encrypted key reports needs-passphrase then unlocks', () {
      final generated = service.generateEd25519(passphrase: 'open sesame');

      expect(
        service.inspect(generated.privateKeyPem).status,
        SshKeyStatus.needsPassphrase,
      );
      expect(
        service.inspect(generated.privateKeyPem, passphrase: 'wrong').status,
        SshKeyStatus.wrongPassphrase,
      );
      final unlocked = service.inspect(
        generated.privateKeyPem,
        passphrase: 'open sesame',
      );
      expect(unlocked.status, SshKeyStatus.valid);
      expect(
        unlocked.details?.fingerprintSha256,
        generated.details.fingerprintSha256,
      );
    });
  });

  group('verify', () {
    test('confirms the right passphrase and rejects the wrong one', () async {
      final generated = service.generateEd25519(passphrase: 'off thread pass');

      final ok = await service.verify(
        generated.privateKeyPem,
        passphrase: 'off thread pass',
      );
      expect(ok.status, SshKeyStatus.valid);
      expect(
        ok.details?.fingerprintSha256,
        generated.details.fingerprintSha256,
      );

      final bad = await service.verify(
        generated.privateKeyPem,
        passphrase: 'nope',
      );
      expect(bad.status, SshKeyStatus.wrongPassphrase);
    });
  });

  group('inspect', () {
    test('reports invalid for blank or junk input', () {
      expect(service.inspect('').status, SshKeyStatus.invalid);
      expect(service.inspect('   ').status, SshKeyStatus.invalid);
      expect(service.inspect('not a key at all').status, SshKeyStatus.invalid);
    });

    test('flags an encrypted key with no passphrase', () {
      final pem = _encryptedEd25519Pem();
      expect(service.inspect(pem).status, SshKeyStatus.needsPassphrase);
    });

    test('flags a wrong passphrase on an encrypted key', () {
      final pem = _encryptedEd25519Pem();
      expect(
        service.inspect(pem, passphrase: 'nope').status,
        SshKeyStatus.wrongPassphrase,
      );
    });

    test('unlocks an encrypted key with the right passphrase', () {
      final pem = _encryptedEd25519Pem();
      final inspection = service.inspect(pem, passphrase: 'correct horse');
      expect(inspection.status, SshKeyStatus.valid);
      expect(inspection.details?.algorithm, SshKeyAlgorithm.ed25519);
    });

    test('classifies a hardware-key stub as a security key', () {
      final inspection = service.inspect(fakeSecurityKeyPem());

      expect(inspection.status, SshKeyStatus.securityKeyStub);
      expect(inspection.isUsable, isTrue);
      expect(inspection.details?.algorithm, SshKeyAlgorithm.securityKeyEd25519);
      expect(inspection.details?.isSecurityKey, isTrue);
      expect(
        inspection.details?.publicKeyOpenSsh,
        startsWith('sk-ssh-ed25519@openssh.com '),
      );
      expect(inspection.details?.fingerprintSha256, startsWith('SHA256:'));
      expect(inspection.details?.comment, isEmpty);
      expect(inspection.details?.publicKeyOpenSsh, isNot(contains('ssh:')));
    });
  });
}

String _encryptedEd25519Pem() {
  return '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCgQkDNsd
r4GLdQkU+S1vKmAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIJ/wW3nHHcMUe8Lk
H5DJQaho/vD4YShbXC+mrpFFS7tFAAAAkICI61lVLtvnDF04HOXsxjBUmvjvoESz0vu9N+
5aLeo+eX+9+tvDk+6otr6ODZIdc+uTh5pPc/ymC+UCGyP0jSqwMWBvOBKRMEEqkL/Dxuq0
Z4X/lkR3ID24N771c1GU4OHAqAtoVAGe1Gop3oVaRMMqdsWYtEGJ1uniseZ1qs6zbuUxnE
+PIDLoLkYUOhglCw==
-----END OPENSSH PRIVATE KEY-----''';
}
