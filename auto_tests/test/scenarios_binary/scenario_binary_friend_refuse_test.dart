/// Friend-application REFUSE regression (binary-replacement path).
///
/// Guards the bug where the unified accept+refuse native binding
/// `DartHandleFriendAddRequest` (third_party/tim2tox/ffi/dart_compat_friendship.cpp)
/// ignored `friend_response_action` and unconditionally called
/// `AcceptFriendApplication` -> `tox_friend_add_norequest`. The Tencent SDK routes
/// BOTH accept and refuse through this one binding (see
/// tencent_cloud_chat_sdk/.../tim_friendship_manager.dart: acceptFriendApplication
/// sends action 0/1, refuseFriendApplication sends action 2 =
/// CFriendResponseAction.responseActionReject). So DECLINING a friend request
/// silently ADDED the friend — a refuse was handled as an accept.
///
/// Drives the SAME single-instance binary-replacement path the real app uses
/// (`TIMFriendshipManager.instance.{accept,refuse}FriendApplication` ->
/// `NativeLibraryManager.bindings.DartHandleFriendAddRequest`) and asserts:
///   - accept (control): ACCEPT a key -> it IS a friend. Proves the binding's add
///     path works here, so the refuse assertion below is meaningful (not a
///     trivial pass).
///   - refuse (regression): REFUSE a DIFFERENT key -> NOT a friend. FAILS without
///     the fix (the reject was accepted -> friend added), PASSES with action==2
///     routed to RefuseFriendApplication.
///
/// The two targets are REAL Tox public keys (valid curve25519 points, from the
/// bootstrap node list). This matters: `tox_friend_add_norequest` rejects a
/// syntactically-valid-but-not-on-curve key, so a synthetic key would make the
/// refuse test FALSE-PASS even without the fix (the buggy accept-on-reject would
/// also fail to add it). Adding a bootstrap key is a purely LOCAL Tox operation
/// (no network/connection needed); the peer never has to respond.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_response_type_enum.dart';
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Friend application refuse (binary replacement path)', () {
    late TestNode node;

    setUpAll(() async {
      await setupTestEnvironment();
      setupNativeLibraryForTim2Tox();
      node = await createTestNode('friend_refuse_node');
      await node.initSDK();
    });

    tearDownAll(() async {
      await node.dispose();
      await teardownTestEnvironment();
    });

    // Two distinct REAL Tox public keys (valid curve points, from the bootstrap
    // node list). Either is accepted by tox_friend_add_norequest as a LOCAL add.
    const acceptPubKey =
        '10C00EB250C3233E343E2AEBA07115A5C28920E9C8D29492F6D00B29049EDC7E';
    const refusePubKey =
        '7E5668E0EE09E19F320AD47902419331FFEE147BB3606769CFBE921A2A2FD34C';

    // Friend list entries are public keys; compare on the normalized 64-hex
    // prefix so this is robust to 64- vs 76-char id formatting and case.
    Future<bool> hasFriend(String pubKey) async {
      final want = pubKey.toUpperCase();
      final friends = await node.getFriendList(useCache: false);
      return friends.any((f) {
        final n = f.toUpperCase();
        final prefix = n.length >= 64 ? n.substring(0, 64) : n;
        return prefix == want;
      });
    }

    test(
      'accept (action!=2) ADDS the friend — control proving the binding adds',
      () async {
        expect(await hasFriend(acceptPubKey), isFalse,
            reason: 'accept target should start absent');

        final res = await node.runWithInstanceAsync(
          () => TIMFriendshipManager.instance.acceptFriendApplication(
            responseType:
                FriendResponseTypeEnum.V2TIM_FRIEND_ACCEPT_AGREE_AND_ADD,
            userID: acceptPubKey,
          ),
        );
        expect(res.code, equals(0),
            reason: 'acceptFriendApplication should succeed (code 0)');
        // tox_friend_add_norequest is synchronous; small settle for the FFI cb.
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(await hasFriend(acceptPubKey), isTrue,
            reason: 'accept must add the friend via tox_friend_add_norequest');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'refuse (friend_response_action=2) does NOT add the friend — regression',
      () async {
        expect(await hasFriend(refusePubKey), isFalse,
            reason: 'refuse target should start absent');

        await node.runWithInstanceAsync(
          () => TIMFriendshipManager.instance.refuseFriendApplication(
            userID: refusePubKey,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          await hasFriend(refusePubKey),
          isFalse,
          reason:
              'DECLINE must NOT befriend: DartHandleFriendAddRequest must route '
              'friend_response_action=2 (reject) to RefuseFriendApplication, not '
              'AcceptFriendApplication. Friend present here == the decline bug.',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
