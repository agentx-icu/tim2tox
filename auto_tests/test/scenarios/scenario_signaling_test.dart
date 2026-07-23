// Signaling Test — virtual-clock variant
//
// Mirrors scenario_signaling_test.dart 1:1 but drives the harness via the
// virtual-clock helpers (VirtualClock + pumpTestTick + *Virtual helpers).
// The Accept / Cancel sub-tests keep their wall-clock-era retry loops:
// Tox custom-packet signaling drops are real (friend P2P warming up on a
// 2-node local bootstrap) and the retry is independent of clock mode.
// The Group signaling sub-test creates a group and invites a peer; that
// invite path gets the standard onGroupInvited retry pattern.

import 'dart:async';
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_signaling_manager.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimSignalingListener.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import '../test_helper.dart';
import '../test_fixtures.dart';

void main() {
  group('Signaling Tests', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;

    setUpAll(() async {
      await setupTestEnvironment();
      // Signaling depends on event_thread's task_queue. We need event_thread
      // fully suppressed (not just stopped post-init) — enableEarly sets a
      // process-global flag BEFORE initAllNodes so the V2TIMManagerImpl
      // constructor reads it and InitSDK never spawns event_thread.
      if (shouldRunVirtual) await VirtualClock.enableEarly();
      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;

      await scenario.initAllNodes();
      // Refresh per-instance test_mode for visibility (the constructor
      // already inherited from enableEarly, but enableForScenario also seeds
      // the virtual clock and is idempotent on test_mode).
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      // Parallelize login
      await Future.wait([
        alice.login(),
        bob.login(),
      ]);

      // Wait for both nodes to be connected
      await waitUntil(() => alice.loggedIn && bob.loggedIn);

      // Configure local bootstrap
      await configureLocalBootstrapVirtual(scenario);

      // Establish friendship (uses Tox IDs and waits for P2P connection)
      await establishFriendshipVirtual(scenario, alice, bob);
    });

    tearDownAll(() async {
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    // Lightweight setUp for per-test cleanup if needed
    setUp(() async {
      // Reset any per-test state if necessary
      // Most tests don't need cleanup since they use shared scenario
    });

    test('Send and receive signaling invite', () async {
      var bobReceivedInvite = false;
      String? receivedInviteID;
      String? receivedInviter;
      String? receivedData;

      // Setup Bob's signaling listener on bob's instance
      final bobSignalingListener = V2TimSignalingListener(
        onReceiveNewInvitation:
            (inviteID, inviter, groupID, inviteeList, data) {
          bobReceivedInvite = true;
          receivedInviteID = inviteID;
          receivedInviter = inviter;
          receivedData = data;
        },
        onInviteeAccepted: (inviteID, invitee, data) {},
        onInviteeRejected: (inviteID, invitee, data) {},
        onInvitationCancelled: (inviteID, inviter, data) {},
        onInvitationTimeout: (inviteID, inviteeList) {},
      );

      // Ensure C++ current instance is Bob for the whole registration (platform addSignalingListener is async)
      await bob.runWithInstanceAsync(() async {
        ffi_lib.Tim2ToxFfi.open().setCurrentInstance(bob.testInstanceHandle!);
        await TencentCloudChatSdkPlatform.instance
            .addSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance.addSignalingListener(bobSignalingListener);
      });

      // Alice sends a signaling invite to Bob (use Tox ID for invitee)
      final inviteData = '{"type":"video_call","room_id":"test_room_123"}';
      final inviteResult = await alice
          .runWithInstanceAsync(() async => TIMSignalingManager.instance.invite(
                invitee: bob.getToxId(),
                data: inviteData,
                timeout: 30,
                onlineUserOnly: false,
              ));

      print(
          '[Signaling] Send invite: code=${inviteResult.code} desc=${inviteResult.desc} data=${inviteResult.data}');
      expect(inviteResult.code, equals(0));
      expect(inviteResult.data, isNotNull);
      expect(inviteResult.data, isNotEmpty);

      final inviteID = inviteResult.data!;

      // Give Alice's event thread a moment to run the send task, then pump so Bob can receive
      await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 80);
      await pumpTestTick(scenario, advanceMs: 300, iterationsPerInstance: 1);

      // Wait for Bob to receive the invite (pump so both instances run tox_iterate and event threads can process)
      await waitUntilWithVirtualPump(
        scenario,
        () => bobReceivedInvite,
        timeout: const Duration(seconds: 30),
        description: 'bobReceivedInvite (inviteID=$inviteID)',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      expect(receivedInviteID, equals(inviteID));
      // C++ may send inviter as 64-char public key or full 76-char Tox ID
      expect(
        receivedInviter,
        anyOf(
            equals(alice.getToxId()),
            equals(alice.getToxId().length >= 64
                ? alice.getToxId().substring(0, 64)
                : alice.getToxId())),
      );
      // Native may send data as JSON string or parsed Map.toString(); accept if content matches
      expect(receivedData, isNotNull);
      expect((receivedData ?? '').contains('video_call'), isTrue);
      expect((receivedData ?? '').contains('test_room_123'), isTrue);

      // Clean up
      await bob.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .removeSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance
            .removeSignalingListener(listener: bobSignalingListener);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Accept signaling invite', () async {
      var aliceReceivedAccept = false;
      String? acceptedInviteID;
      String? acceptedInvitee;

      // Setup Alice's signaling listener on alice's instance
      final aliceSignalingListener = V2TimSignalingListener(
        onReceiveNewInvitation:
            (inviteID, inviter, groupID, inviteeList, data) {},
        onInviteeAccepted: (inviteID, invitee, data) {
          aliceReceivedAccept = true;
          acceptedInviteID = inviteID;
          acceptedInvitee = invitee;
        },
        onInviteeRejected: (inviteID, invitee, data) {},
        onInvitationCancelled: (inviteID, inviter, data) {},
        onInvitationTimeout: (inviteID, inviteeList) {},
      );

      await alice.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .addSignalingListener(listener: aliceSignalingListener);
        TIMSignalingManager.instance
            .addSignalingListener(aliceSignalingListener);
      });

      // Setup Bob's signaling listener on bob's instance to receive invite
      var bobReceivedInvite = false;
      String? bobInviteID;

      final bobSignalingListener = V2TimSignalingListener(
        onReceiveNewInvitation:
            (inviteID, inviter, groupID, inviteeList, data) {
          bobReceivedInvite = true;
          bobInviteID = inviteID;
        },
        onInviteeAccepted: (inviteID, invitee, data) {},
        onInviteeRejected: (inviteID, invitee, data) {},
        onInvitationCancelled: (inviteID, inviter, data) {},
        onInvitationTimeout: (inviteID, inviteeList) {},
      );

      await bob.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .addSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance.addSignalingListener(bobSignalingListener);
      });

      // Alice sends invite (use Tox ID for invitee)
      final inviteResult = await alice
          .runWithInstanceAsync(() async => TIMSignalingManager.instance.invite(
                invitee: bob.getToxId(),
                data: '{"type":"video_call"}',
                timeout: 30,
              ));

      expect(inviteResult.code, equals(0));
      final inviteID = inviteResult.data!;

      // Wait for Bob to receive invite (pump so Bob's Tox can process the packet)
      await waitUntilWithVirtualPump(
        scenario,
        () => bobReceivedInvite,
        timeout: const Duration(seconds: 30),
        description: 'bobReceivedInvite',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      // Bob accepts the invite on bob's instance
      final acceptResult = await bob
          .runWithInstanceAsync(() async => TIMSignalingManager.instance.accept(
                inviteID: bobInviteID!,
                data: '{"type":"accept"}',
              ));

      expect(acceptResult.code, equals(0));
      // Aggressive immediate pump to push the SIGNALING_ACCEPT packet out
      // before the back-and-forth needs to settle over a flaky friend link.
      await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 250);

      // Wait for Alice to receive accept notification. Friend P2P in
      // 2-node local bootstrap is flaky — bump to 90s and retry the accept
      // if needed. This retry is preserved verbatim from the wall-clock
      // variant because the underlying Tox custom-packet drops are
      // independent of clock mode.
      var aliceWaited = false;
      for (var attempt = 0; !aliceWaited && attempt < 2; attempt++) {
        if (attempt > 0) {
          // Re-fire accept; original packet may have been dropped while
          // friend P2P was still warming up on the back-direction link.
          await bob.runWithInstanceAsync(
              () async => TIMSignalingManager.instance.accept(
                    inviteID: bobInviteID!,
                    data: '{"type":"accept"}',
                  ));
          await pumpTestTick(scenario,
              advanceMs: 50, iterationsPerInstance: 250);
        }
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => aliceReceivedAccept,
            timeout: const Duration(seconds: 40),
            description: 'aliceReceivedAccept',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          aliceWaited = true;
        } on TimeoutException catch (e) {
          // Expected between retry attempts (the post-loop expect enforces the
          // real assertion); a non-timeout error is a real bug and propagates.
          print('[Test] Attempt timed out; retrying: $e');
        }
      }
      expect(aliceReceivedAccept, isTrue,
          reason: 'Alice never received onInviteeAccepted after retries');

      expect(acceptedInviteID, equals(inviteID));
      expect(
        acceptedInvitee,
        anyOf(
            equals(bob.getToxId()),
            equals(bob.getToxId().length >= 64
                ? bob.getToxId().substring(0, 64)
                : bob.getToxId())),
      );

      // Clean up
      await alice.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .removeSignalingListener(listener: aliceSignalingListener);
        TIMSignalingManager.instance
            .removeSignalingListener(listener: aliceSignalingListener);
      });
      await bob.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .removeSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance
            .removeSignalingListener(listener: bobSignalingListener);
      });
    }, timeout: const Timeout(Duration(seconds: 240)));

    test('Reject signaling invite', () async {
      var aliceReceivedReject = false;
      String? rejectedInviteID;
      String? rejectedInvitee;

      // Setup Alice's signaling listener on alice's instance
      final aliceSignalingListener = V2TimSignalingListener(
        onReceiveNewInvitation:
            (inviteID, inviter, groupID, inviteeList, data) {},
        onInviteeAccepted: (inviteID, invitee, data) {},
        onInviteeRejected: (inviteID, invitee, data) {
          aliceReceivedReject = true;
          rejectedInviteID = inviteID;
          rejectedInvitee = invitee;
        },
        onInvitationCancelled: (inviteID, inviter, data) {},
        onInvitationTimeout: (inviteID, inviteeList) {},
      );

      await alice.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .addSignalingListener(listener: aliceSignalingListener);
        TIMSignalingManager.instance
            .addSignalingListener(aliceSignalingListener);
      });

      // Setup Bob's signaling listener on bob's instance
      var bobReceivedInvite = false;
      String? bobInviteID;

      final bobSignalingListener = V2TimSignalingListener(
        onReceiveNewInvitation:
            (inviteID, inviter, groupID, inviteeList, data) {
          bobReceivedInvite = true;
          bobInviteID = inviteID;
        },
        onInviteeAccepted: (inviteID, invitee, data) {},
        onInviteeRejected: (inviteID, invitee, data) {},
        onInvitationCancelled: (inviteID, inviter, data) {},
        onInvitationTimeout: (inviteID, inviteeList) {},
      );

      await bob.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .addSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance.addSignalingListener(bobSignalingListener);
      });

      // Alice sends invite (use Tox ID for invitee)
      final inviteResult = await alice
          .runWithInstanceAsync(() async => TIMSignalingManager.instance.invite(
                invitee: bob.getToxId(),
                data: '{"type":"video_call"}',
                timeout: 30,
              ));

      expect(inviteResult.code, equals(0));
      final inviteID = inviteResult.data!;

      // Wait for Bob to receive invite (pump so Bob's Tox can process the packet)
      await waitUntilWithVirtualPump(
        scenario,
        () => bobReceivedInvite,
        timeout: const Duration(seconds: 30),
        description: 'bobReceivedInvite',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      // Bob rejects the invite on bob's instance
      final rejectResult = await bob
          .runWithInstanceAsync(() async => TIMSignalingManager.instance.reject(
                inviteID: bobInviteID!,
                data: '{"type":"reject","reason":"busy"}',
              ));

      expect(rejectResult.code, equals(0));

      // Wait for Alice to receive reject notification (pump so Alice's Tox can process the packet)
      await waitUntilWithVirtualPump(
        scenario,
        () => aliceReceivedReject,
        timeout: const Duration(seconds: 30),
        description: 'aliceReceivedReject',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      expect(rejectedInviteID, equals(inviteID));
      expect(
        rejectedInvitee,
        anyOf(
            equals(bob.getToxId()),
            equals(bob.getToxId().length >= 64
                ? bob.getToxId().substring(0, 64)
                : bob.getToxId())),
      );

      // Clean up
      await alice.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .removeSignalingListener(listener: aliceSignalingListener);
        TIMSignalingManager.instance
            .removeSignalingListener(listener: aliceSignalingListener);
      });
      await bob.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .removeSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance
            .removeSignalingListener(listener: bobSignalingListener);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Cancel signaling invite', () async {
      var bobReceivedCancel = false;
      String? cancelledInviteID;
      String? cancelledInviter;

      // Setup Bob's signaling listener on bob's instance
      final bobSignalingListener = V2TimSignalingListener(
        onReceiveNewInvitation:
            (inviteID, inviter, groupID, inviteeList, data) {},
        onInviteeAccepted: (inviteID, invitee, data) {},
        onInviteeRejected: (inviteID, invitee, data) {},
        onInvitationCancelled: (inviteID, inviter, data) {
          bobReceivedCancel = true;
          cancelledInviteID = inviteID;
          cancelledInviter = inviter;
        },
        onInvitationTimeout: (inviteID, inviteeList) {},
      );

      await bob.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .addSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance.addSignalingListener(bobSignalingListener);
      });

      // Alice sends invite (use Tox ID for invitee)
      final inviteResult = await alice
          .runWithInstanceAsync(() async => TIMSignalingManager.instance.invite(
                invitee: bob.getToxId(),
                data: '{"type":"video_call"}',
                timeout: 30,
              ));

      expect(inviteResult.code, equals(0));
      final inviteID = inviteResult.data!;

      // Wait a bit for invite to be sent (pump so both instances process)
      await pumpTestTick(scenario, advanceMs: 1000, iterationsPerInstance: 1);
      await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 100);

      // Alice cancels the invite on alice's instance
      final cancelResult = await alice
          .runWithInstanceAsync(() async => TIMSignalingManager.instance.cancel(
                inviteID: inviteID,
                data: '{"type":"cancel","reason":"changed_mind"}',
              ));

      expect(cancelResult.code, equals(0));
      await pumpTestTick(scenario, advanceMs: 50, iterationsPerInstance: 250);

      // Wait for Bob to receive cancel notification. Friend P2P flake — retry.
      // This retry is preserved verbatim from the wall-clock variant because
      // the underlying Tox custom-packet drops are independent of clock mode.
      var bobWaited = false;
      for (var attempt = 0; !bobWaited && attempt < 2; attempt++) {
        if (attempt > 0) {
          await alice.runWithInstanceAsync(
              () async => TIMSignalingManager.instance.cancel(
                    inviteID: inviteID,
                    data: '{"type":"cancel","reason":"changed_mind"}',
                  ));
          await pumpTestTick(scenario,
              advanceMs: 50, iterationsPerInstance: 250);
        }
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bobReceivedCancel,
            timeout: const Duration(seconds: 45),
            description: 'bobReceivedCancel',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          bobWaited = true;
        } on TimeoutException catch (e) {
          // Expected between retry attempts (the post-loop expect enforces the
          // real assertion); a non-timeout error is a real bug and propagates.
          print('[Test] Attempt timed out; retrying: $e');
        }
      }
      expect(bobReceivedCancel, isTrue,
          reason: 'Bob never received onInvitationCancelled after retries');

      expect(cancelledInviteID, equals(inviteID));
      expect(
        cancelledInviter,
        anyOf(
            equals(alice.getToxId()),
            equals(alice.getToxId().length >= 64
                ? alice.getToxId().substring(0, 64)
                : alice.getToxId())),
      );

      // Clean up
      await bob.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .removeSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance
            .removeSignalingListener(listener: bobSignalingListener);
      });
    }, timeout: const Timeout(Duration(seconds: 150)));

    test('Signaling invite timeout', () async {
      var aliceReceivedTimeout = false;
      String? timeoutInviteID;

      // Setup Alice's signaling listener on alice's instance
      final aliceSignalingListener = V2TimSignalingListener(
        onReceiveNewInvitation:
            (inviteID, inviter, groupID, inviteeList, data) {},
        onInviteeAccepted: (inviteID, invitee, data) {},
        onInviteeRejected: (inviteID, invitee, data) {},
        onInvitationCancelled: (inviteID, inviter, data) {},
        onInvitationTimeout: (inviteID, inviteeList) {
          aliceReceivedTimeout = true;
          timeoutInviteID = inviteID;
        },
      );

      await alice.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .addSignalingListener(listener: aliceSignalingListener);
        TIMSignalingManager.instance
            .addSignalingListener(aliceSignalingListener);
      });

      // Alice sends invite with short timeout (use Tox ID for invitee)
      final inviteResult = await alice
          .runWithInstanceAsync(() async => TIMSignalingManager.instance.invite(
                invitee: bob.getToxId(),
                data: '{"type":"video_call"}',
                timeout: 5, // 5 seconds timeout
              ));

      expect(inviteResult.code, equals(0));
      final inviteID = inviteResult.data!;

      // Don't accept or reject - wait for timeout (pump so timeout can fire)
      await waitUntilWithVirtualPump(
        scenario,
        () => aliceReceivedTimeout,
        timeout: const Duration(seconds: 10),
        description: 'aliceReceivedTimeout',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      expect(timeoutInviteID, equals(inviteID));

      // Clean up
      await alice.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .removeSignalingListener(listener: aliceSignalingListener);
        TIMSignalingManager.instance
            .removeSignalingListener(listener: aliceSignalingListener);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Group signaling invite', () async {
      // Create a group on alice's instance first
      final createResult = await alice.runWithInstanceAsync(
          () async => TIMGroupManager.instance.createGroup(
                groupType: 'Meeting',
                groupName: 'Signaling Test Group',
                groupID: '',
              ));

      expect(createResult.code, equals(0));
      final groupId = createResult.data!;

      // Add Bob to the group (native expects 64-char public key)
      // Apply invite-retry pattern so onGroupInvited is reliably observed
      // even when the tox_group_invite_friend packet is dropped on the
      // first try.
      final bobPk = bob.getToxId().length >= 64
          ? bob.getToxId().substring(0, 64)
          : bob.getToxId();
      var inviteArrived = false;
      for (var attempt = 0; !inviteArrived && attempt < 3; attempt++) {
        bob.clearCallbackReceived('onGroupInvited');
        final groupInvResult = await alice.runWithInstanceAsync(
            () async => TIMGroupManager.instance.inviteUserToGroup(
                  groupID: groupId,
                  userList: [bobPk],
                ));
        expect(groupInvResult.code, equals(0),
            reason: 'inviteUserToGroup failed: ${groupInvResult.desc}');
        try {
          await waitUntilWithVirtualPump(
            scenario,
            () => bob.callbackReceived['onGroupInvited'] == true,
            timeout: const Duration(seconds: 15),
            description: 'Bob onGroupInvited (attempt ${attempt + 1})',
            advanceMs: 50,
            iterationsPerInstance: 1,
          );
          inviteArrived = true;
        } catch (_) {
          // retry
        }
      }
      // Group signaling invite test does not strictly require Bob to have
      // joined the group; the original test only delayed ~2s. We mirror
      // that by always advancing some virtual time before continuing.
      await pumpTestTick(scenario, advanceMs: 2000, iterationsPerInstance: 1);
      if (!inviteArrived) {
        print(
            '[Signaling] Bob did not observe onGroupInvited; proceeding with group signaling invite anyway (mirrors wall-clock behavior).');
      }

      // Setup Bob's signaling listener on bob's instance
      var bobReceivedGroupInvite = false;
      String? bobGroupInviteID;
      String? bobGroupID;

      final bobSignalingListener = V2TimSignalingListener(
        onReceiveNewInvitation:
            (inviteID, inviter, groupID, inviteeList, data) {
          if (groupID == groupId) {
            bobReceivedGroupInvite = true;
            bobGroupInviteID = inviteID;
            bobGroupID = groupID;
          }
        },
        onInviteeAccepted: (inviteID, invitee, data) {},
        onInviteeRejected: (inviteID, invitee, data) {},
        onInvitationCancelled: (inviteID, inviter, data) {},
        onInvitationTimeout: (inviteID, inviteeList) {},
      );

      await bob.runWithInstanceAsync(() async {
        ffi_lib.Tim2ToxFfi.open().setCurrentInstance(bob.testInstanceHandle!);
        await TencentCloudChatSdkPlatform.instance
            .addSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance.addSignalingListener(bobSignalingListener);
      });

      // Alice sends group signaling invite (native may expect 64-char for inviteeList)
      final groupInviteResult = await alice.runWithInstanceAsync(
          () async => TIMSignalingManager.instance.inviteInGroup(
                groupID: groupId,
                inviteeList: [bobPk],
                data: '{"type":"group_video_call"}',
                timeout: 30,
              ));

      expect(groupInviteResult.code, equals(0));
      expect(groupInviteResult.data, isNotNull);
      expect(groupInviteResult.data, isNotEmpty);

      // Wait for Bob to receive group invite (pump so Bob's Tox can process the packet)
      await waitUntilWithVirtualPump(
        scenario,
        () => bobReceivedGroupInvite,
        timeout: const Duration(seconds: 30),
        description: 'bobReceivedGroupInvite',
        advanceMs: 50,
        iterationsPerInstance: 1,
      );

      expect(bobGroupInviteID, isNotNull);
      expect(bobGroupID, equals(groupId));

      // Clean up
      await bob.runWithInstanceAsync(() async {
        await TencentCloudChatSdkPlatform.instance
            .removeSignalingListener(listener: bobSignalingListener);
        TIMSignalingManager.instance
            .removeSignalingListener(listener: bobSignalingListener);
      });
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
