import 'dart:io';

import 'package:test/test.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

import '../test_fixtures.dart';

class _SpyFfiChatService extends FfiChatService {
  _SpyFfiChatService({
    required super.preferencesService,
    required super.loggerService,
    required super.bootstrapService,
  });

  bool sendAvatarToAllFriendsCalled = false;
  String? avatarPathOverride;

  @override
  Future<void> sendAvatarToAllFriends({String? avatarPathOverride}) async {
    sendAvatarToAllFriendsCalled = true;
    this.avatarPathOverride = avatarPathOverride;
  }
}

void main() {
  group('FfiChatService Avatar Sync', () {
    late MockPreferencesService prefs;
    late _SpyFfiChatService service;

    setUpAll(() async {
      await setupTestEnvironment();
    });

    tearDownAll(() async {
      await teardownTestEnvironment();
    });

    setUp(() async {
      prefs = MockPreferencesService();
      service = _SpyFfiChatService(
        preferencesService: prefs,
        loggerService: MockLoggerService(),
        bootstrapService: MockBootstrapService(),
      );
    });

    tearDown(() async {
      await service.dispose();
    });

    test('updateAvatar should trigger avatar sync to friends', () async {
      final testDir = await getTestDataDir('avatar_sync_unit');
      final avatarFile = File(
          '$testDir/avatar_sync_unit_${DateTime.now().microsecondsSinceEpoch}.png');
      await avatarFile.writeAsBytes(<int>[1, 2, 3, 4, 5]);
      await prefs.setAvatarPath(avatarFile.path);

      try {
        await service.updateAvatar(avatarFile.path);

        expect(
          service.sendAvatarToAllFriendsCalled,
          isTrue,
          reason:
              'Updating self avatar should trigger avatar sync dispatch to friends.',
        );
        expect(service.avatarPathOverride, avatarFile.path);
        expect(
          await prefs.getSelfAvatarHash(),
          isNotNull,
          reason: 'Local avatar hash should still be updated.',
        );
      } finally {
        if (await avatarFile.exists()) {
          await avatarFile.delete();
        }
      }
    });

    test('deleting avatar clears local state and fans out deletion', () async {
      final testDir = await getTestDataDir('avatar_delete_sync_unit');
      final avatarFile = File(
          '$testDir/avatar_delete_sync_${DateTime.now().microsecondsSinceEpoch}.png');
      await avatarFile.writeAsBytes(<int>[9, 8, 7, 6]);
      await prefs.setAvatarPath(avatarFile.path);
      await prefs.setSelfAvatarHash('old-hash');

      try {
        await service.updateAvatar(null);

        expect(await prefs.getAvatarPath(), isNull);
        expect(await prefs.getSelfAvatarHash(), isNull);
        expect(service.sendAvatarToAllFriendsCalled, isTrue);
        expect(service.avatarPathOverride, isNull);
      } finally {
        if (await avatarFile.exists()) {
          await avatarFile.delete();
        }
      }
    });
  });
}
