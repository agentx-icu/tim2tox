// Legacy qTox AV-conference PCM ownership and lifecycle contract.
//
// This is intentionally RED until Tim2Tox forwards
// `HandleAVConferenceAudio` to Dart and exposes the legacy
// `toxav_group_send_audio` plus enable/disable/mute controls.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:ffi/ffi.dart' as pkgffi;
import 'package:test/test.dart';
import 'package:tencent_cloud_chat_sdk/enum/V2TimGroupListener.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_group_member_info.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_friendship_manager.dart';
import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';
import 'package:tim2tox_dart/ffi/tim2tox_ffi.dart' as ffi_lib;
import 'package:tim2tox_dart/service/toxav_service.dart';

import '../test_fixtures.dart';
import '../test_helper.dart';

Future<void> _pumpAv(
  TestScenario scenario, {
  int advanceMs = 20,
  int iterationsPerInstance = 1,
  Duration wallSleep = const Duration(milliseconds: 20),
}) async {
  await pumpTestTickAv(
    scenario,
    advanceMs: advanceMs,
    iterationsPerInstance: iterationsPerInstance,
    wallSleep: wallSleep,
  );
  if (VirtualClock.enabled) return;

  final bindings = ffi_lib.Tim2ToxFfi.open();
  for (final node in scenario.nodes) {
    final handle = node.testInstanceHandle;
    if (handle == null) continue;
    try {
      bindings.avIterate(handle);
    } on ArgumentError {
      // A node without an attached 1:1 ToxAV session needs no AV iterate.
    }
  }
}

Future<({String senderGroupId, String receiverGroupId})>
    _createJoinedConference(
  TestScenario scenario,
  TestNode alice,
  TestNode bob,
) async {
  alice.clearCallbackReceived('onGroupCreated');
  final bindings = ffi_lib.Tim2ToxFfi.open();
  final name = 'qTox legacy PCM contract'.toNativeUtf8();
  final type = 'av_conference'.toNativeUtf8();
  final output = pkgffi.malloc<ffi.Int8>(128);
  late int createdLength;
  late String conferenceId;
  try {
    createdLength = alice.runWithInstance(
      () => bindings.createGroup(name, type, output, 128),
    );
    expect(createdLength, greaterThan(0));
    conferenceId = output.cast<pkgffi.Utf8>().toDartString(
          length: createdLength,
        );
  } finally {
    pkgffi.malloc.free(output);
    pkgffi.malloc.free(type);
    pkgffi.malloc.free(name);
  }

  await waitUntilWithAvVirtualPump(
    scenario,
    () => alice.callbackReceived['onGroupCreated'] == true,
    timeout: const Duration(seconds: 10),
    description: 'Alice conference creation callback',
  );

  final bobPublicKey = bob.getPublicKey();
  String? invitedGroupId;
  final listener = V2TimGroupListener(
    onMemberInvited: (
      String groupID,
      V2TimGroupMemberInfo opUser,
      List<V2TimGroupMemberInfo> memberList,
    ) {
      final invitedIds = memberList
          .map((member) => (member.userID ?? '').toUpperCase())
          .toSet();
      if (!invitedIds.contains(bobPublicKey.toUpperCase())) return;
      invitedGroupId = groupID;
    },
  );

  bob.runWithInstance(
    () => TIMGroupManager.instance.addGroupListener(listener),
  );
  try {
    for (var attempt = 0; invitedGroupId == null && attempt < 3; attempt++) {
      final result = await alice.runWithInstanceAsync(
        () async => TIMGroupManager.instance.inviteUserToGroup(
          groupID: conferenceId,
          userList: [bobPublicKey],
        ),
      );
      expect(result.code, equals(0));
      try {
        await waitUntilWithAvVirtualPump(
          scenario,
          () => invitedGroupId != null,
          timeout: const Duration(seconds: 30),
          description: 'Bob conference invite attempt ${attempt + 1}',
        );
      } on TimeoutException {
        // The post-loop assertion records the deterministic failure.
      }
    }
    expect(invitedGroupId, isNotNull, reason: 'Bob did not receive the invite');
  } finally {
    bob.runWithInstance(
      () => TIMGroupManager.instance.removeGroupListener(listener: listener),
    );
  }

  await _pumpAv(scenario, advanceMs: 5000, iterationsPerInstance: 2);
  final bobJoined = await bob.runWithInstanceAsync(
    () async => TIMGroupManager.instance.getJoinedGroupList(),
  );
  expect(bobJoined.code, equals(0));
  expect(
    bobJoined.data!.any((group) => group.groupID == invitedGroupId),
    isTrue,
  );
  return (
    senderGroupId: conferenceId,
    receiverGroupId: invitedGroupId!,
  );
}

void main() {
  group('legacy qTox AV-conference PCM', () {
    late TestScenario scenario;
    late TestNode alice;
    late TestNode bob;
    late ToxAVService aliceAv;
    late ToxAVService bobAv;

    setUpAll(() async {
      await setupTestEnvironment();
      if (shouldRunVirtual) await VirtualClock.enableEarly();

      scenario = await createTestScenario(['alice', 'bob']);
      alice = scenario.getNode('alice')!;
      bob = scenario.getNode('bob')!;
      await scenario.initAllNodes();
      if (shouldRunVirtual) await VirtualClock.enableForScenario(scenario);

      await Future.wait([alice.login(), bob.login()]);
      await waitUntil(
        () => alice.loggedIn && bob.loggedIn,
        timeout: const Duration(seconds: 10),
        description: 'both nodes logged in',
      );
      await configureLocalBootstrapVirtual(scenario);
      alice.enableAutoAccept();
      bob.enableAutoAccept();
      await waitForConnectionVirtual(
        scenario,
        alice,
        timeout: const Duration(seconds: 15),
      );
      await waitForConnectionVirtual(
        scenario,
        bob,
        timeout: const Duration(seconds: 15),
      );
      await waitUntilWithVirtualPump(
        scenario,
        () => alice.getToxId().length == 76 && bob.getToxId().length == 76,
        timeout: const Duration(seconds: 10),
        description: 'Tox IDs available',
      );

      final aliceToxId = alice.getToxId();
      final bobToxId = bob.getToxId();
      await alice.runWithInstanceAsync(
        () async => TIMFriendshipManager.instance.addFriend(
          userID: bobToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          remark: 'Bob',
          addWording: 'qTox conference PCM',
        ),
      );
      await bob.runWithInstanceAsync(
        () async => TIMFriendshipManager.instance.addFriend(
          userID: aliceToxId,
          addType: FriendTypeEnum.V2TIM_FRIEND_TYPE_BOTH,
          remark: 'Alice',
          addWording: 'qTox conference PCM',
        ),
      );
      for (var tick = 0; tick < 30; tick++) {
        await _pumpAv(
          scenario,
          advanceMs: 100,
          wallSleep: const Duration(milliseconds: 30),
        );
      }
      await waitForFriendsInList(alice, [bob.getPublicKey()]);
      await waitForFriendsInList(bob, [alice.getPublicKey()]);
      await waitForFriendConnectionVirtual(
        scenario,
        alice,
        bobToxId,
        timeout: const Duration(seconds: 60),
      );
      await waitForFriendConnectionVirtual(
        scenario,
        bob,
        aliceToxId,
        timeout: const Duration(seconds: 60),
      );

      final bindings = ffi_lib.Tim2ToxFfi.open();
      expect(bindings.avIsAvailable, isTrue);
      final aliceInitialized = await alice.runWithInstanceAsync(() async {
        aliceAv = ToxAVService(bindings);
        return aliceAv.initialize();
      });
      final bobInitialized = await bob.runWithInstanceAsync(() async {
        bobAv = ToxAVService(bindings);
        return bobAv.initialize();
      });
      expect(aliceInitialized, isTrue);
      expect(bobInitialized, isTrue);
    });

    tearDownAll(() async {
      alice.runWithInstance(() => aliceAv.shutdown());
      bob.runWithInstance(() => bobAv.shutdown());
      await scenario.dispose();
      await teardownTestEnvironment();
    });

    test(
      'copies receive PCM, preserves metadata, and owns controls through teardown',
      () async {
        final conferenceIds = await _createJoinedConference(
          scenario,
          alice,
          bob,
        );
        final aliceConferenceId = conferenceIds.senderGroupId;
        final bobConferenceId = conferenceIds.receiverGroupId;
        const sampleCount = 960;
        const channels = 1;
        const sampleRate = 48000;
        final firstPcm = List<int>.generate(
          sampleCount,
          (index) => ((index * 977 + 12345) & 0xffff) - 0x8000,
        );
        final secondPcm = List<int>.generate(
          sampleCount,
          (index) => ((index * 541 + 22222) & 0xffff) - 0x8000,
        );

        var receiveCount = 0;
        String? receivedGroupId;
        int? receivedConferenceNumber;
        int? receivedPeerNumber;
        int? receivedSampleCount;
        int? receivedChannels;
        int? receivedSampleRate;
        List<int>? retainedFirstFrame;

        bob.runWithInstance(() {
          bobAv.setConferenceAudioReceiveCallback((
            String groupId,
            int conferenceNumber,
            int peerNumber,
            List<int> pcm,
            int samples,
            int channelCount,
            int samplingRate,
          ) {
            receiveCount++;
            receivedGroupId = groupId;
            receivedConferenceNumber = conferenceNumber;
            receivedPeerNumber = peerNumber;
            receivedSampleCount = samples;
            receivedChannels = channelCount;
            receivedSampleRate = samplingRate;
            retainedFirstFrame ??= pcm;
          });
        });

        final aliceEnabled = await alice.runWithInstanceAsync(
          () async => aliceAv.enableConferenceAudio(aliceConferenceId),
        );
        final bobEnabled = await bob.runWithInstanceAsync(
          () async => bobAv.enableConferenceAudio(bobConferenceId),
        );
        expect(aliceEnabled, isTrue);
        expect(bobEnabled, isTrue);
        expect(
          alice.runWithInstance(
            () => aliceAv.isConferenceAudioEnabled(aliceConferenceId),
          ),
          isTrue,
        );

        var acceptedSends = 0;
        for (var attempt = 0; receiveCount == 0 && attempt < 300; attempt++) {
          final accepted = await alice.runWithInstanceAsync(
            () async => aliceAv.sendConferenceAudioFrame(
              aliceConferenceId,
              firstPcm,
              sampleCount,
              channels,
              sampleRate,
            ),
          );
          if (accepted == true) acceptedSends++;
          await _pumpAv(scenario);
        }

        expect(acceptedSends, greaterThan(0));
        expect(receiveCount, greaterThan(0));
        expect(receivedGroupId, equals(bobConferenceId));
        expect(receivedConferenceNumber, isNonNegative);
        expect(receivedPeerNumber, isNonNegative);
        expect(receivedSampleCount, greaterThan(0));
        expect(receivedChannels, equals(channels));
        expect(receivedSampleRate, equals(sampleRate));
        expect(retainedFirstFrame, isA<Int16List>());
        expect(
          retainedFirstFrame!.length,
          equals(receivedSampleCount! * receivedChannels!),
        );

        final retainedSnapshot = List<int>.of(retainedFirstFrame!);
        await alice.runWithInstanceAsync(
          () async => aliceAv.sendConferenceAudioFrame(
            aliceConferenceId,
            secondPcm,
            sampleCount,
            channels,
            sampleRate,
          ),
        );
        for (var tick = 0; tick < 10; tick++) {
          await _pumpAv(scenario);
        }
        expect(
          retainedFirstFrame,
          orderedEquals(retainedSnapshot),
          reason: 'received PCM must remain valid after callback return',
        );

        final beforeMute = receiveCount;
        expect(
          await bob.runWithInstanceAsync(
            () async => bobAv.muteConferenceAudio(bobConferenceId, true),
          ),
          isTrue,
        );
        for (var attempt = 0; attempt < 10; attempt++) {
          await alice.runWithInstanceAsync(
            () async => aliceAv.sendConferenceAudioFrame(
              aliceConferenceId,
              secondPcm,
              sampleCount,
              channels,
              sampleRate,
            ),
          );
          await _pumpAv(scenario);
        }
        expect(receiveCount, equals(beforeMute));

        expect(
          await bob.runWithInstanceAsync(
            () async => bobAv.muteConferenceAudio(bobConferenceId, false),
          ),
          isTrue,
        );
        expect(
          await bob.runWithInstanceAsync(
            () async => bobAv.disableConferenceAudio(bobConferenceId),
          ),
          isTrue,
        );
        expect(
          bob.runWithInstance(
            () => bobAv.isConferenceAudioEnabled(bobConferenceId),
          ),
          isFalse,
        );

        final beforeTeardown = receiveCount;
        for (var attempt = 0; attempt < 10; attempt++) {
          await alice.runWithInstanceAsync(
            () async => aliceAv.sendConferenceAudioFrame(
              aliceConferenceId,
              secondPcm,
              sampleCount,
              channels,
              sampleRate,
            ),
          );
          await _pumpAv(scenario);
        }
        expect(receiveCount, equals(beforeTeardown));

        expect(
          await bob.runWithInstanceAsync(
            () async => bobAv.enableConferenceAudio(bobConferenceId),
          ),
          isTrue,
        );
        expect(
          bob.runWithInstance(
            () => bobAv.isConferenceAudioEnabled(bobConferenceId),
          ),
          isTrue,
        );

        var acceptedAfterReenable = 0;
        for (var attempt = 0;
            receiveCount == beforeTeardown && attempt < 300;
            attempt++) {
          final accepted = await alice.runWithInstanceAsync(
            () async => aliceAv.sendConferenceAudioFrame(
              aliceConferenceId,
              secondPcm,
              sampleCount,
              channels,
              sampleRate,
            ),
          );
          if (accepted == true) acceptedAfterReenable++;
          await _pumpAv(scenario);
        }
        expect(acceptedAfterReenable, greaterThan(0));
        expect(
          receiveCount,
          greaterThan(beforeTeardown),
          reason: 'disable then enable must restore native PCM delivery',
        );

        bob.runWithInstance(
          () => bobAv.setConferenceAudioReceiveCallback(null),
        );
        expect(
          await bob.runWithInstanceAsync(
            () async => bobAv.disableConferenceAudio(bobConferenceId),
          ),
          isTrue,
        );
        expect(
          await alice.runWithInstanceAsync(
            () async => aliceAv.disableConferenceAudio(aliceConferenceId),
          ),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(seconds: 240)),
    );

    test(
      'does not dispatch queued PCM until avIterate pumps the receiver',
      () async {
        final conferenceIds = await _createJoinedConference(
          scenario,
          alice,
          bob,
        );
        final aliceConferenceId = conferenceIds.senderGroupId;
        final bobConferenceId = conferenceIds.receiverGroupId;
        const sampleCount = 960;
        const channels = 1;
        const sampleRate = 48000;
        const enqueuedFrames = 5;
        final receivedMarkers = <int>[];

        bob.runWithInstance(() {
          bobAv.setConferenceAudioReceiveCallback((
            String groupId,
            int conferenceNumber,
            int peerNumber,
            List<int> pcm,
            int samples,
            int channelCount,
            int samplingRate,
          ) {
            if (groupId != bobConferenceId) return;
            receivedMarkers.add(pcm.first);
          });
        });

        expect(
          await alice.runWithInstanceAsync(
            () async => aliceAv.enableConferenceAudio(aliceConferenceId),
          ),
          isTrue,
        );
        expect(
          await bob.runWithInstanceAsync(
            () async => bobAv.enableConferenceAudio(bobConferenceId),
          ),
          isTrue,
        );

        for (var frameIndex = 0; frameIndex < enqueuedFrames; frameIndex++) {
          final accepted = await alice.runWithInstanceAsync(
            () async => aliceAv.sendConferenceAudioFrame(
              aliceConferenceId,
              List<int>.filled(sampleCount * channels, frameIndex),
              sampleCount,
              channels,
              sampleRate,
            ),
          );
          expect(
            accepted,
            isTrue,
            reason: 'frame $frameIndex should enter the AV conference pipeline',
          );
        }

        expect(
          receivedMarkers,
          isEmpty,
          reason: 'conference PCM must not reach Dart before avIterate drains',
        );

        for (var attempt = 0;
            receivedMarkers.isEmpty && attempt < 300;
            attempt++) {
          await _pumpAv(scenario, iterationsPerInstance: 1);
        }

        expect(
          receivedMarkers,
          isNotEmpty,
          reason: 'receiver avIterate should drain queued conference PCM',
        );
        expect(receivedMarkers, everyElement(inInclusiveRange(0, 4)));

        bob.runWithInstance(
          () => bobAv.setConferenceAudioReceiveCallback(null),
        );
        expect(
          await bob.runWithInstanceAsync(
            () async => bobAv.disableConferenceAudio(bobConferenceId),
          ),
          isTrue,
        );
        expect(
          await alice.runWithInstanceAsync(
            () async => aliceAv.disableConferenceAudio(aliceConferenceId),
          ),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(seconds: 240)),
    );
  });
}
