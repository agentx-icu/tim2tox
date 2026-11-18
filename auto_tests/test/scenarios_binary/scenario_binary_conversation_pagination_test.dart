import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_response_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/enum/log_level_enum.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_conversation_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_manager.dart';

import '../test_fixtures.dart';
import '../test_helper.dart';

void main() {
  test('binary conversation list continues from the previous page', () async {
    await setupTestEnvironment();
    addTearDown(teardownTestEnvironment);
    setupNativeLibraryForTim2Tox();
    final node = await createTestNode('conversation_pagination_node');
    addTearDown(node.dispose);
    await node.initSDK();

    // Adding an existing public key locally does not require a live peer.
    const keys = {
      '10C00EB250C3233E343E2AEBA07115A5C28920E9C8D29492F6D00B29049EDC7E',
      '7E5668E0EE09E19F320AD47902419331FFEE147BB3606769CFBE921A2A2FD34C',
    };
    for (final key in keys) {
      final result = await node.runWithInstanceAsync(
        () => TIMFriendshipManager.instance.acceptFriendApplication(
          responseType:
              FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
          userID: key,
        ),
      );
      expect(result.code, 0);
    }

    final manager = TIMConversationManager.instance;
    // The native conversation cache debounces refreshes after an accept.
    await waitUntilAsync(() async {
      final list = await node.runWithInstanceAsync(
        () => manager.getConversationList(nextSeq: '0', count: keys.length),
      );
      return list.data?.conversationList?.length == keys.length;
    }, description: 'both friends to appear in the native conversation cache');

    final first = await node.runWithInstanceAsync(
      () => manager.getConversationList(nextSeq: '0', count: 1),
    );
    expect(first.code, 0);
    expect(first.data?.conversationList, hasLength(1));
    expect(first.data?.isFinished, isFalse);
    expect(first.data?.nextSeq, '1');

    final second = await node.runWithInstanceAsync(
      () =>
          manager.getConversationList(nextSeq: first.data!.nextSeq!, count: 1),
    );
    expect(second.code, 0);
    expect(second.data?.conversationList, hasLength(1));
    expect(second.data?.isFinished, isTrue);
    expect(second.data?.nextSeq, '0');
    expect({
      first.data!.conversationList!.single.userID?.toUpperCase(),
      second.data!.conversationList!.single.userID?.toUpperCase(),
    }, keys);

    final pastEnd = await node.runWithInstanceAsync(
      () => manager.getConversationList(nextSeq: '4294967296', count: 1),
    );
    expect(pastEnd.code, 0);
    expect(pastEnd.data?.conversationList, isEmpty);
    expect(pastEnd.data?.isFinished, isTrue);
    expect(pastEnd.data?.nextSeq, '0');
  });

  test('binary conversations and blacklist belong to the active profile',
      () async {
    await setupTestEnvironment();
    addTearDown(teardownTestEnvironment);
    setupNativeLibraryForTim2Tox();
    final node = await createTestNode('conversation_profile_switch_node');
    addTearDown(node.dispose);
    final oldProfile = await getTestDataDir('old-profile');
    final nextProfile = await getTestDataDir('next-profile');
    await node.initSDK(initPath: nextProfile);

    final friendship = TIMFriendshipManager.instance;
    final conversations = TIMConversationManager.instance;
    const nextFriend =
        '10C00EB250C3233E343E2AEBA07115A5C28920E9C8D29492F6D00B29049EDC7E';
    const oldFriend =
        '7E5668E0EE09E19F320AD47902419331FFEE147BB3606769CFBE921A2A2FD34C';

    Future<void> addFriend(String key) async {
      final result = await node.runWithInstanceAsync(
        () => friendship.acceptFriendApplication(
          responseType:
              FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
          userID: key,
        ),
      );
      expect(result.code, 0);
    }

    Future<void> switchTo(String profile) =>
        node.runWithInstanceAsync(() async {
          final sdk = TIMManager.instance;
          expect(sdk.unInitSDK(), isTrue);
          expect(
            await sdk.initSDK(
              sdkAppID: 0,
              logLevel: LogLevelEnum.V2TIM_LOG_INFO,
              uiPlatform: 0,
              initPath: profile,
              logPath: profile,
            ),
            isTrue,
          );
        });

    Future<String?> onlyConversationPeer() async {
      final result = await node.runWithInstanceAsync(
        () => conversations.getConversationList(nextSeq: '0', count: 2),
      );
      expect(result.code, 0);
      final list = result.data?.conversationList;
      return list?.length == 1 ? list!.single.userID : null;
    }

    await addFriend(nextFriend);
    await switchTo(oldProfile);
    await addFriend(oldFriend);
    await waitUntilAsync(
      () async => await onlyConversationPeer() == oldFriend,
      description: 'the old profile conversation to be cached',
    );

    final blocked = await node.runWithInstanceAsync(
      () => friendship.addToBlackList(userIDList: [oldFriend]),
    );
    expect(blocked.code, 0);
    final blocklist = await node.runWithInstanceAsync(friendship.getBlackList);
    expect(blocklist.data?.map((friend) => friend.userID), [oldFriend]);

    await switchTo(nextProfile);
    expect(await onlyConversationPeer(), nextFriend);
    final nextBlocklist =
        await node.runWithInstanceAsync(friendship.getBlackList);
    expect(nextBlocklist.code, 0);
    expect(nextBlocklist.data, isEmpty);
  });
}
