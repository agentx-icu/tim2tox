import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_message_manager.dart';
import 'package:test/test.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

import '../test_fixtures.dart';
import '../test_helper.dart';

const _avatarMaxBytes = 10 * 1024 * 1024;
const _oversizeAvatarResult = -8;

void main() {
  test('declares the explicit high-level qTox avatar C FFI seam', () {
    final compile = _compileAvatarCallSite();
    expect(
      compile.exitCode,
      0,
      reason: 'Missing tim2tox_ffi_send_avatar borrowed-buffer API.\n'
          '${compile.stderr}',
    );
  });

  final nativeLibraryAvailable = _builtLibraryFile().existsSync();
  group(
    'qTox avatar two-node wire behavior',
    () {
      final tempRoot =
          'scenario_qtox_avatar_wire_${pid}_${DateTime.now().microsecondsSinceEpoch}';
      late TestScenario scenario;
      late TestNode alice;
      late TestNode bob;
      late FfiChatService bobService;
      late MockPreferencesService bobPreferences;
      late String testDataDir;
      late String alicePublicKey;
      late String bobPublicKey;
      late String aliceToxId;
      late String bobToxId;
      var bobServiceCreated = false;

      setUpAll(() async {
        await setupTestEnvironment();
        testDataDir = await getTestDataDir(tempRoot);

        if (shouldRunVirtual) {
          await VirtualClock.enableEarly();
        }
        scenario = await createTestScenario([
          'qtox-avatar-alice',
          'qtox-avatar-bob',
        ]);
        alice = scenario.getNode('qtox-avatar-alice')!;
        bob = scenario.getNode('qtox-avatar-bob')!;
        await alice.initSDK(
          initPath: path.join(testDataDir, 'alice', 'init'),
          logPath: path.join(testDataDir, 'alice', 'logs'),
        );
        await bob.initSDK(
          initPath: path.join(testDataDir, 'bob', 'init'),
          logPath: path.join(testDataDir, 'bob', 'logs'),
        );
        if (shouldRunVirtual) {
          await VirtualClock.enableForScenario(scenario);
        }

        await Future.wait([alice.login(), bob.login()]);
        await waitUntil(
          () => alice.loggedIn && bob.loggedIn,
          timeout: const Duration(seconds: 10),
          description: 'qTox avatar peers logged in',
        );
        await configureLocalBootstrapVirtual(scenario);
        await establishFriendshipVirtual(scenario, alice, bob);
        await pumpFriendConnectionVirtual(scenario, alice, bob);

        alicePublicKey = alice.getPublicKey();
        bobPublicKey = bob.getPublicKey();
        aliceToxId = alice.getToxId();
        bobToxId = bob.getToxId();
        expect(aliceToxId, hasLength(76));
        expect(bobToxId, hasLength(76));
        await waitForFriendConnectionVirtual(
          scenario,
          alice,
          bobToxId,
          timeout: const Duration(seconds: 90),
        );
        await waitForFriendConnectionVirtual(
          scenario,
          bob,
          aliceToxId,
          timeout: const Duration(seconds: 90),
        );

        bobPreferences = MockPreferencesService();
        final capturedInstanceId = bob.runWithInstance(() {
          bobService = FfiChatService(
            preferencesService: bobPreferences,
            loggerService: MockLoggerService(),
            historyDirectory: path.join(
              testDataDir,
              'bob-service',
              'history',
            ),
            queueFilePath: path.join(
              testDataDir,
              'bob-service',
              'offline_queue.json',
            ),
            fileRecvPath: path.join(
              testDataDir,
              'bob-service',
              'file_recv',
            ),
            avatarsPath: path.join(
              testDataDir,
              'bob-service',
              'avatars',
            ),
          );
          bobServiceCreated = true;
          return bobService.tim2toxFfi.getCurrentInstanceId();
        });
        expect(capturedInstanceId, bob.testInstanceHandle);

        FfiChatService.clearPollingRegistryForTests();
        FfiChatService.registerInstanceForPolling(bob.testInstanceHandle!);
        await bob.runWithInstanceAsync(bobService.startPolling);
      });

      tearDownAll(() async {
        if (bobServiceCreated && bob.testInstanceHandle != null) {
          await bob.runWithInstanceAsync(bobService.dispose);
        }
        FfiChatService.clearPollingRegistryForTests();
        await scenario.dispose();
        await cleanupTestDataDir(tempRoot);
        await teardownTestEnvironment();
      });

      test(
        'set max avatar then update after caller buffers are freed',
        () async {
          final api = _QtoxAvatarApi.open();
          final firstAvatar = _avatarBytes(_avatarMaxBytes, seed: 17);
          final secondAvatar = _avatarBytes(1024, seed: 91);
          final updates = <String>[];
          var fileRequestCount = 0;
          var progressCount = 0;
          final subscription = bob.runWithInstance(
            () => bobService.avatarUpdated.listen(updates.add),
          );
          final fileRequestSubscription = bob.runWithInstance(
            () => bobService.fileRequests.listen((_) => fileRequestCount++),
          );
          final progressSubscription = bob.runWithInstance(
            () => bobService.progressUpdates.listen((_) => progressCount++),
          );

          try {
            final firstResult = alice.runWithInstance(
              () => api.sendAvatar(
                instanceId: alice.testInstanceHandle!,
                peerId: bobPublicKey,
                bytes: firstAvatar,
              ),
            );
            expect(
              firstResult,
              1,
              reason: 'The inclusive 65,536-byte maximum must send.',
            );
            await _waitForAvatarUpdates(scenario, updates, 1);

            final firstPath = await bob.runWithInstanceAsync(
              () => bobPreferences.getFriendAvatarPath(alicePublicKey),
            );
            expect(firstPath, isNotNull);
            expect(await File(firstPath!).readAsBytes(), firstAvatar);
            _expectNoAvatarHistory(bob, bobService, alicePublicKey);

            final secondResult = alice.runWithInstance(
              () => api.sendAvatar(
                instanceId: alice.testInstanceHandle!,
                peerId: bobPublicKey,
                bytes: secondAvatar,
              ),
            );
            expect(secondResult, 1);
            await _waitForAvatarUpdates(scenario, updates, 2);

            final secondPath = await bob.runWithInstanceAsync(
              () => bobPreferences.getFriendAvatarPath(alicePublicKey),
            );
            expect(secondPath, isNotNull);
            expect(secondPath, isNot(firstPath));
            expect(await File(secondPath!).readAsBytes(), secondAvatar);
            _expectNoAvatarHistory(bob, bobService, alicePublicKey);
            expect(fileRequestCount, 0);
            expect(progressCount, 0);
          } finally {
            await subscription.cancel();
            await fileRequestSubscription.cancel();
            await progressSubscription.cancel();
          }
        },
        timeout: const Timeout(Duration(seconds: 180)),
      );

      test(
        'same raw hash is canceled without replacing the cached avatar',
        () async {
          final api = _QtoxAvatarApi.open();
          final avatar = _avatarBytes(4096, seed: 33);
          final updates = <String>[];
          final subscription = bob.runWithInstance(
            () => bobService.avatarUpdated.listen(updates.add),
          );

          try {
            expect(
              alice.runWithInstance(
                () => api.sendAvatar(
                  instanceId: alice.testInstanceHandle!,
                  peerId: bobPublicKey,
                  bytes: avatar,
                ),
              ),
              1,
            );
            await _waitForAvatarUpdates(scenario, updates, 1);
            final cachedPath = await bob.runWithInstanceAsync(
              () => bobPreferences.getFriendAvatarPath(alicePublicKey),
            );
            expect(cachedPath, isNotNull);

            expect(
              alice.runWithInstance(
                () => api.sendAvatar(
                  instanceId: alice.testInstanceHandle!,
                  peerId: bobPublicKey,
                  bytes: avatar,
                ),
              ),
              1,
            );
            await pumpTestTick(
              scenario,
              advanceMs: 50,
              iterationsPerInstance: 120,
            );

            expect(
              updates,
              hasLength(1),
              reason:
                  'The receiver must compare the raw file_id and cancel a same-hash offer.',
            );
            expect(
              await bob.runWithInstanceAsync(
                () => bobPreferences.getFriendAvatarPath(alicePublicKey),
              ),
              cachedPath,
            );
            _expectNoAvatarHistory(bob, bobService, alicePublicKey);
          } finally {
            await subscription.cancel();
          }
        },
        timeout: const Timeout(Duration(seconds: 150)),
      );

      test(
        'oversize avatar is rejected before a transfer or history row',
        () async {
          final api = _QtoxAvatarApi.open();
          final updates = <String>[];
          final subscription = bob.runWithInstance(
            () => bobService.avatarUpdated.listen(updates.add),
          );

          try {
            final result = alice.runWithInstance(
              () => api.sendAvatar(
                instanceId: alice.testInstanceHandle!,
                peerId: bobPublicKey,
                bytes: _avatarBytes(_avatarMaxBytes + 1, seed: 7),
              ),
            );

            expect(result, _oversizeAvatarResult);
            await pumpTestTick(
              scenario,
              advanceMs: 50,
              iterationsPerInstance: 20,
            );
            expect(updates, isEmpty);
            _expectNoAvatarHistory(bob, bobService, alicePublicKey);
          } finally {
            await subscription.cancel();
          }
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );

      test(
        'zero-size avatar removes the cached avatar without history',
        () async {
          final api = _QtoxAvatarApi.open();
          final updates = <String>[];
          final subscription = bob.runWithInstance(
            () => bobService.avatarUpdated.listen(updates.add),
          );

          try {
            expect(
              alice.runWithInstance(
                () => api.sendAvatar(
                  instanceId: alice.testInstanceHandle!,
                  peerId: bobPublicKey,
                  bytes: _avatarBytes(512, seed: 61),
                ),
              ),
              1,
            );
            await _waitForAvatarUpdates(scenario, updates, 1);
            expect(
              await bob.runWithInstanceAsync(
                () => bobPreferences.getFriendAvatarPath(alicePublicKey),
              ),
              isNotNull,
            );

            expect(
              alice.runWithInstance(
                () => api.sendAvatar(
                  instanceId: alice.testInstanceHandle!,
                  peerId: bobPublicKey,
                  bytes: null,
                ),
              ),
              1,
            );
            await _waitForAvatarUpdates(scenario, updates, 2);

            expect(
              await bob.runWithInstanceAsync(
                () => bobPreferences.getFriendAvatarPath(alicePublicKey),
              ),
              isNull,
            );
            _expectNoAvatarHistory(bob, bobService, alicePublicKey);
          } finally {
            await subscription.cancel();
          }
        },
        timeout: const Timeout(Duration(seconds: 150)),
      );

      test(
        'ordinary image remains DATA and creates chat history',
        () async {
          final genericImage = File(
            path.join(testDataDir, 'ordinary-image.png'),
          );
          await genericImage.writeAsBytes(_avatarBytes(256, seed: 5));
          final previousAvatarPath = await bob.runWithInstanceAsync(
            () => bobPreferences.getFriendAvatarPath(alicePublicKey),
          );

          final sendResult = await alice.runWithInstanceAsync(() async {
            final fileMessage = TIMMessageManager.instance.createFileMessage(
              filePath: genericImage.path,
              fileName: 'ordinary-image.png',
            );
            expect(fileMessage.messageInfo, isNotNull);
            return TIMMessageManager.instance.sendMessage(
              message: fileMessage.messageInfo!,
              receiver: bobToxId,
              groupID: null,
            );
          });
          expect(
            sendResult.code,
            0,
            reason:
                'Alice must send the generic image through her TIM instance.',
          );
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.runWithInstance(
              () => bobService.getHistory(alicePublicKey).isNotEmpty,
            ),
            timeout: const Duration(seconds: 90),
            description: 'ordinary image DATA history row',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );

          expect(
            bob
                .runWithInstance(() => bobService.getHistory(alicePublicKey))
                .any((message) => message.fileName == 'ordinary-image.png'),
            isTrue,
          );
          expect(
            await bob.runWithInstanceAsync(
              () => bobPreferences.getFriendAvatarPath(alicePublicKey),
            ),
            previousAvatarPath,
            reason:
                'A generic image must not be promoted to TOX_FILE_KIND_AVATAR.',
          );
        },
        timeout: const Timeout(Duration(seconds: 150)),
      );

      test(
        'an avatar event for another instance cannot mutate this service',
        () async {
          final api = _QtoxAvatarApi.open();
          final updates = <String>[];
          final subscription = bob.runWithInstance(
            () => bobService.avatarUpdated.listen(updates.add),
          );
          final previousPath = await bob.runWithInstanceAsync(
            () => bobPreferences.getFriendAvatarPath(bobPublicKey),
          );

          FfiChatService.registerInstanceForPolling(alice.testInstanceHandle!);
          try {
            expect(
              bob.runWithInstance(
                () => api.sendAvatar(
                  instanceId: bob.testInstanceHandle!,
                  peerId: alicePublicKey,
                  bytes: _avatarBytes(128, seed: 73),
                ),
              ),
              1,
            );
            await pumpTestTick(
              scenario,
              advanceMs: 50,
              iterationsPerInstance: 120,
            );

            expect(updates, isEmpty);
            expect(
              await bob.runWithInstanceAsync(
                () => bobPreferences.getFriendAvatarPath(bobPublicKey),
              ),
              previousPath,
            );
            _expectNoAvatarHistory(bob, bobService, bobPublicKey);
          } finally {
            FfiChatService.unregisterInstanceForPolling(
              alice.testInstanceHandle!,
            );
            await subscription.cancel();
          }
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    },
    skip: nativeLibraryAvailable
        ? false
        : 'Generated Tim2Tox native library is unavailable; build_ffi.sh could not download nlohmann/json.',
  );
}

class _QtoxAvatarApi {
  _QtoxAvatarApi(this._ffi);

  final Tim2ToxFfi _ffi;

  static _QtoxAvatarApi open() => _QtoxAvatarApi(Tim2ToxFfi.open());

  int sendAvatar({
    required int instanceId,
    required String peerId,
    required Uint8List? bytes,
  }) {
    return bytes == null
        ? _ffi.deleteAvatar(instanceId, peerId)
        : _ffi.sendAvatar(instanceId, peerId, bytes);
  }
}

File _builtLibraryFile() {
  final libraryName = switch (Platform.operatingSystem) {
    'macos' => 'libtim2tox_ffi.dylib',
    'linux' => 'libtim2tox_ffi.so',
    'windows' => 'tim2tox_ffi.dll',
    _ => throw UnsupportedError(
        'Native scenario is unsupported on ${Platform.operatingSystem}',
      ),
  };
  return File('../build/ffi/$libraryName').absolute;
}

ProcessResult _compileAvatarCallSite() {
  final tempRoot = Directory.systemTemp.createTempSync(
    'tim2tox_qtox_avatar_scenario_abi_${pid}_',
  );
  try {
    final source = File('${tempRoot.path}/avatar_abi.c');
    final headerPath = File('../ffi/tim2tox_ffi.h').absolute.path;
    source.writeAsStringSync('''
#include "$headerPath"

typedef int (*send_avatar_fn)(
    int64_t, const char *, const uint8_t *, size_t);

static send_avatar_fn send_avatar = &tim2tox_ffi_send_avatar;

int main(void) {
    return send_avatar == 0;
}
''');
    return Process.runSync(Platform.environment['CC'] ?? 'cc', [
      '-std=c11',
      '-Werror',
      '-fsyntax-only',
      source.path,
    ]);
  } finally {
    tempRoot.deleteSync(recursive: true);
  }
}

Uint8List _avatarBytes(int length, {required int seed}) => Uint8List.fromList(
      List<int>.generate(length, (index) => (index * 31 + seed) & 0xff),
    );

Future<void> _waitForAvatarUpdates(
  TestScenario scenario,
  List<String> updates,
  int count,
) =>
    waitUntilWithVirtualPump(
      scenario,
      () => updates.length >= count,
      timeout: const Duration(seconds: 90),
      description: '$count qTox avatar update(s)',
      advanceMs: 50,
      iterationsPerInstance: 1,
    );

void _expectNoAvatarHistory(
  TestNode bob,
  FfiChatService bobService,
  String alicePublicKey,
) {
  expect(
    bob.runWithInstance(() => bobService.getHistory(alicePublicKey)),
    isEmpty,
  );
}
