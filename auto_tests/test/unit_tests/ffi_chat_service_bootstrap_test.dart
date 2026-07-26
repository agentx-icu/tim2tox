import 'dart:io';

import 'package:test/test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

import '../test_fixtures.dart';

void main() {
  ffi_lib.Tim2ToxFfi? library;

  setUpAll(() {
    try {
      library = ffi_lib.Tim2ToxFfi.open();
    } on Object {
      library = null;
    }
  });

  test(
      'tryBootstrapNode attempts native bootstrap without writing injected preferences',
      () async {
    final lib = library;
    if (lib == null) {
      markTestSkipped('tim2tox FFI library is not loadable');
      return;
    }

    final previousCurrent = lib.getCurrentInstanceId();
    final tempRoot =
        Directory.systemTemp.createTempSync('tim2tox_try_bootstrap_');
    var source = 0;
    var target = 0;
    FfiChatService? service;

    try {
      final sourcePath = Directory('${tempRoot.path}/source')..createSync();
      final targetPath = Directory('${tempRoot.path}/target')..createSync();
      final prefs = MockPreferencesService();
      const originalNode = (
        host: 'bootstrap.example.invalid',
        port: 33445,
        pubkey:
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );
      await prefs.setCurrentBootstrapNode(
        originalNode.host,
        originalNode.port,
        originalNode.pubkey,
      );
      service = FfiChatService(
        preferencesService: prefs,
        historyDirectory: tempRoot.path,
        queueFilePath: '${tempRoot.path}/offline_queue.json',
        fileRecvPath: tempRoot.path,
        avatarsPath: tempRoot.path,
      );
      source = service.createTestInstanceEx(
        sourcePath.path,
        localDiscoveryEnabled: false,
        ipv6Enabled: false,
      );
      target = service.createTestInstanceEx(
        targetPath.path,
        localDiscoveryEnabled: false,
        ipv6Enabled: false,
      );

      expect(lib.setCurrentInstance(source), 1);
      final sourceDhtId = service.getDhtId();
      final sourcePort = service.getUdpPort();
      expect(sourceDhtId, hasLength(64));
      expect(sourcePort, greaterThan(0));

      expect(lib.setCurrentInstance(target), 1);

      final accepted = await service.tryBootstrapNode(
        '127.0.0.1',
        sourcePort,
        sourceDhtId!,
      );

      expect(
        accepted,
        isTrue,
        reason: 'the local native bootstrap request should be accepted',
      );
      expect(
        await prefs.getCurrentBootstrapNode(),
        originalNode,
        reason: 'a bootstrap attempt must not persist or replace preferences',
      );

      final legacyAccepted = await service.testBootstrapNode(
        '127.0.0.1',
        sourcePort,
        sourceDhtId,
      );
      expect(
        legacyAccepted,
        isTrue,
        reason: 'the legacy API must delegate to the Tox bootstrap request',
      );
      expect(
        await prefs.getCurrentBootstrapNode(),
        originalNode,
        reason: 'the compatibility method must also remain non-persisting',
      );

      for (final invalid in [
        (host: '', port: sourcePort, pubkey: sourceDhtId),
        (host: 'bad\nhost', port: sourcePort, pubkey: sourceDhtId),
        (host: '127.0.0.1', port: 0, pubkey: sourceDhtId),
        (host: '127.0.0.1', port: 65536, pubkey: sourceDhtId),
        (host: '127.0.0.1', port: sourcePort, pubkey: 'not-hex'),
      ]) {
        expect(
          await service.tryBootstrapNode(
            invalid.host,
            invalid.port,
            invalid.pubkey,
          ),
          isFalse,
          reason: 'invalid bootstrap endpoint must be rejected: $invalid',
        );
      }
      expect(
        await prefs.getCurrentBootstrapNode(),
        originalNode,
        reason: 'invalid attempts must not mutate preferences',
      );
    } finally {
      try {
        if (service != null) {
          await service.dispose();
        }
      } finally {
        lib.setCurrentInstance(previousCurrent);
        if (target != 0) {
          lib.destroyTestInstance(target);
        }
        if (source != 0) {
          lib.destroyTestInstance(source);
        }
        lib.setCurrentInstance(previousCurrent);
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      }
    }
  });
}
