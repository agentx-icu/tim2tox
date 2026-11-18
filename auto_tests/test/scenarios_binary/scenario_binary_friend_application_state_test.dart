import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimFriendshipListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_application_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/log_level_enum.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';
import 'package:tim2tox_dart/sdk/tim2tox_sdk_platform.dart';

import '../test_fixtures.dart';
import '../test_helper.dart';

void main() {
  test('marking friend requests read preserves them until deletion', () async {
    await setupTestEnvironment();
    addTearDown(teardownTestEnvironment);
    if (shouldRunVirtual) await VirtualClock.enableEarly();
    final scenario = await createTestScenario(['alice', 'bob', 'receiver']);
    addTearDown(scenario.dispose);
    await scenario.initAllNodes();
    if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);
    final alice = scenario.getNode('alice')!;
    final bob = scenario.getNode('bob')!;
    final receiver = scenario.getNode('receiver')!;
    final manager = TIMFriendshipManager.instance;
    final service = await createTestFfiChatService();
    addTearDown(() => receiver.runWithInstanceAsync(service.dispose));
    final platform = Tim2ToxSdkPlatform(ffiService: service);
    addTearDown(platform.dispose);

    final markEmpty = await receiver.runWithInstanceAsync(
      manager.setFriendApplicationRead,
    );
    expect(markEmpty.code, 0);

    await Future.wait([
      alice.login(timeout: const Duration(milliseconds: 500)),
      bob.login(timeout: const Duration(milliseconds: 500)),
      receiver.login(timeout: const Duration(milliseconds: 500)),
    ]);
    receiver.disableAutoAccept();
    await configureLocalBootstrapVirtual(scenario);

    final received = <String>{};
    final listener = V2TimFriendshipListener(
      onFriendApplicationListAdded: (applications) {
        received.addAll(applications.map((application) => application.userID));
      },
    );
    receiver
        .runWithInstance(() => manager.addFriendListener(listener: listener));
    addTearDown(() => receiver.runWithInstance(
        () => manager.removeFriendListener(listener: listener)));

    Future<void> sendRequest(TestNode sender) async {
      final result = await sender.runWithInstanceAsync(
        () => manager.addFriend(
          userID: receiver.getToxId(),
          addWording: 'Hello from ${sender.alias}',
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_SINGLE,
        ),
      );
      expect(result.code, 0);
      await waitUntilWithVirtualPump(
        scenario,
        () => received.contains(sender.getPublicKey()),
        description: 'friend request from ${sender.alias}',
      );
    }

    Future<void> expectRequests(Set<String> keys, int unread) async {
      final result = await receiver.runWithInstanceAsync(
        manager.getFriendApplicationList,
      );
      expect(result.code, 0);
      expect(result.data?.unreadCount, unread);
      final projected = await receiver.runWithInstanceAsync(
        platform.getFriendApplicationList,
      );
      expect(projected.code, 0);
      expect(projected.data?.unreadCount, unread);
      expect(
        projected.data?.friendApplicationList
            ?.map((app) => app?.userID)
            .toSet(),
        keys,
      );
      expect(
        result.data?.friendApplicationList?.map((app) => app?.userID).toSet(),
        keys,
      );
    }

    Future<void> deleteRequest(
        String key, FriendApplicationTypeEnum type) async {
      final result = await receiver.runWithInstanceAsync(
        () => platform.deleteFriendApplication(type: type.index, userID: key),
      );
      expect(result.code, 0);
    }

    await sendRequest(alice);
    final aliceKey = alice.getPublicKey();
    await expectRequests({aliceKey}, 1);

    final markRead = await receiver.runWithInstanceAsync(
      platform.setFriendApplicationRead,
    );
    expect(markRead.code, 0);
    await expectRequests({aliceKey}, 0);

    await sendRequest(bob);
    final bobKey = bob.getPublicKey();
    await expectRequests({aliceKey, bobKey}, 1);

    await deleteRequest(
        aliceKey, FriendApplicationTypeEnum.V2TIM_FRIEND_APPLICATION_SEND_OUT);
    await expectRequests({aliceKey, bobKey}, 1);
    await deleteRequest(alice.getToxId().toLowerCase(),
        FriendApplicationTypeEnum.V2TIM_FRIEND_APPLICATION_COME_IN);
    await expectRequests({bobKey}, 1);
    final nextProfile = '${await getTestDataDir()}/second-profile';
    await receiver.runWithInstanceAsync(() async {
      final sdk = TIMManager.instance;
      expect(sdk.unInitSDK(), isTrue);
      expect(
        await sdk.initSDK(
          sdkAppID: 0,
          logLevel: LogLevelEnum.V2TIM_LOG_INFO,
          uiPlatform: 0,
          initPath: nextProfile,
          logPath: nextProfile,
        ),
        isTrue,
      );
    });
    await expectRequests({}, 0);
  }, timeout: const Timeout(Duration(seconds: 180)));
}
