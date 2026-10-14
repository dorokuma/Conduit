import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/local_shell/data/rootfs_downloader.dart';
import 'package:conduit/features/local_shell/domain/rootfs_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  const abcSha =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
  final abcBytes = utf8.encode('abc');

  Map<String, Object?> validJson() => {
    'version': '2026.06.01',
    'archiveUrl': 'https://mirror.example/arch-aarch64.tar.gz',
    'sha256': abcSha,
    'downloadSizeBytes': 178000000,
  };

  group('RootfsManifest.fromJson', () {
    test('parses a valid manifest', () {
      final manifest = RootfsManifest.fromJson(validJson());
      expect(manifest.version, '2026.06.01');
      expect(manifest.archiveUrl.host, 'mirror.example');
      expect(manifest.sha256, abcSha);
      expect(manifest.downloadSizeBytes, 178000000);
    });

    test('ignores unknown keys from older manifests', () {
      final json = validJson()
        ..['pacmanMirror'] = r'http://mirror.archlinuxarm.org/$arch/$repo'
        ..['keyringName'] = 'archlinuxarm';
      final manifest = RootfsManifest.fromJson(json);
      expect(manifest.version, '2026.06.01');
    });

    test('rejects a missing archive url', () {
      final json = validJson()..remove('archiveUrl');
      expect(
        () => RootfsManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a malformed checksum', () {
      final json = validJson()..['sha256'] = 'not-a-real-digest';
      expect(
        () => RootfsManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('checksum verification', () {
    test('verifySha256 accepts the matching digest', () {
      expect(verifySha256(abcBytes, abcSha), isTrue);
      expect(verifySha256(abcBytes, abcSha.toUpperCase()), isTrue);
    });

    test('verifySha256 rejects a mismatch', () {
      expect(verifySha256(utf8.encode('abd'), abcSha), isFalse);
    });

    test('Sha256Verifier matches across chunk boundaries', () {
      final verifier = Sha256Verifier(abcSha)
        ..addChunk(abcBytes.sublist(0, 1))
        ..addChunk(abcBytes.sublist(1));
      expect(verifier.verify(), isTrue);
    });

    test('Sha256Verifier rejects corrupted streams', () {
      final verifier = Sha256Verifier(abcSha)..addChunk(utf8.encode('xyz'));
      expect(verifier.verify(), isFalse);
    });

    test('HttpRootfsDownloader closes internal client but keeps injected client open', () async {
      final tempDir = await Directory.systemTemp.createTemp('conduit_dl_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      final dest = File('${tempDir.path}/rootfs.tar.gz')
        ..writeAsBytesSync(abcBytes);
      final manifest = RootfsManifest(
        version: '2026.06.01',
        archiveUrl: Uri.parse('https://mirror.example/arch.tar.gz'),
        sha256: abcSha,
        downloadSizeBytes: abcBytes.length,
      );
      var closeCount = 0;

      await HttpOverrides.runZoned(
        () async {
          await HttpRootfsDownloader().download(
            manifest: manifest,
            destination: dest.path,
          );
          expect(closeCount, 1);

          final externalClient = http.Client();
          await HttpRootfsDownloader(externalClient).download(
            manifest: manifest,
            destination: dest.path,
          );
          expect(closeCount, 1);
          externalClient.close();
          expect(closeCount, 2);
        },
        createHttpClient: (_) => _CloseTrackingHttpClient(() => closeCount++),
      );
    });
  });
}

class _CloseTrackingHttpClient implements HttpClient {
  _CloseTrackingHttpClient(this._onClose);
  final void Function() _onClose;

  @override
  void close({bool force = false}) => _onClose();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
