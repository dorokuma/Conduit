import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:conduit/features/hosts/domain/ssh_key.dart';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

class Dartssh2SshKeyService implements SshKeyService {
  const Dartssh2SshKeyService();

  @override
  SshKeyInspection inspect(String pem, {String passphrase = ''}) {
    final text = pem.trim();
    if (text.isEmpty) {
      return const SshKeyInspection.invalid();
    }

    final bool encrypted;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(text);
    } catch (_) {
      return const SshKeyInspection.invalid();
    }

    if (encrypted && passphrase.isEmpty) {
      return const SshKeyInspection.needsPassphrase();
    }

    final List<SSHKeyPair> pairs;
    try {
      pairs = SSHKeyPair.fromPem(text, encrypted ? passphrase : null);
    } catch (_) {
      return encrypted
          ? const SshKeyInspection.wrongPassphrase()
          : const SshKeyInspection.invalid();
    }

    if (pairs.isEmpty) {
      return const SshKeyInspection.invalid();
    }

    final details = _detailsFor(pairs.first);
    return details.isSecurityKey
        ? SshKeyInspection.securityKeyStub(details)
        : SshKeyInspection.valid(details);
  }

  @override
  Future<SshKeyInspection> verify(String pem, {String passphrase = ''}) {
    return Isolate.run(
      () => const Dartssh2SshKeyService().inspect(pem, passphrase: passphrase),
    );
  }

  @override
  GeneratedSshKey generateEd25519({
    String comment = '',
    String passphrase = '',
  }) {
    final signingKey = ed25519.SigningKey.generate();
    final publicKey = Uint8List.fromList(signingKey.verifyKey.asTypedList);
    final privateKey = Uint8List.fromList(signingKey.asTypedList);
    final keyPair = OpenSSHEd25519KeyPair(publicKey, privateKey, comment);
    return GeneratedSshKey(
      privateKeyPem: keyPair.toEncryptedPem(passphrase),
      details: _detailsFor(keyPair),
    );
  }

  SshKeyDetails _detailsFor(SSHKeyPair keyPair) {
    final encoded = keyPair.toPublicKey().encode();
    final type = SSHHostKey.getType(encoded);
    final comment = _commentFor(keyPair);
    final base64Key = base64.encode(encoded);
    final publicKeyOpenSsh = comment.isEmpty
        ? '$type $base64Key'
        : '$type $base64Key $comment';
    return SshKeyDetails(
      algorithm: _algorithmFor(type),
      fingerprintSha256: _fingerprint(encoded),
      publicKeyOpenSsh: publicKeyOpenSsh,
      comment: comment,
    );
  }

  SshKeyAlgorithm _algorithmFor(String type) => switch (type) {
    'ssh-ed25519' => SshKeyAlgorithm.ed25519,
    'ssh-rsa' => SshKeyAlgorithm.rsa,
    'ecdsa-sha2-nistp256' ||
    'ecdsa-sha2-nistp384' ||
    'ecdsa-sha2-nistp521' => SshKeyAlgorithm.ecdsa,
    'sk-ssh-ed25519@openssh.com' => SshKeyAlgorithm.securityKeyEd25519,
    'sk-ecdsa-sha2-nistp256@openssh.com' => SshKeyAlgorithm.securityKeyEcdsa,
    _ => SshKeyAlgorithm.unknown,
  };

  String _commentFor(SSHKeyPair keyPair) {
    if (keyPair is OpenSSHEd25519KeyPair) return keyPair.comment;
    if (keyPair is OpenSSHRsaKeyPair) return keyPair.comment;
    if (keyPair is OpenSSHEcdsaKeyPair) return keyPair.comment;
    return '';
  }

  String _fingerprint(Uint8List encoded) {
    final digest = sha256.convert(encoded).bytes;
    final base64Digest = base64.encode(digest).replaceAll('=', '');
    return 'SHA256:$base64Digest';
  }
}
