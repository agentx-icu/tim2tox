// Native group notifications posted without user_data (the DartNotifyGroup*
// family: groupQuitNotification incl. kick, groupJoinNotification,
// groupJoinFailedNotification, groupInviteNotification, groupChatIdStored,
// groupTypeStored) reach ONE process-global handler. Native stamps each with
// the emitting session (`instance_id`, `session_epoch`); the platform applies
// one only when its service owns the instance AND the epoch is still that
// instance's live native session.
//
// This is the decision rule. The platform handler wiring is exercised in
// toxee's test/tim2tox_sdk_platform_native_session_scope_test.dart (the
// platform only compiles against the patched SDK the integrator vendors), and
// the native stamping in ffi/dart_compat_group.cpp.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/service/polling_event_ownership.dart';

void main() {
  group('acceptsNativeSessionNotification', () {
    bool accepts(Map<String, dynamic> data,
            {Set<int> owned = const {0}, Map<int, int> live = const {0: 5}}) =>
        acceptsNativeSessionNotification(
          data: data,
          ownsInstance: owned.contains,
          liveSessionEpoch: (id) => live[id] ?? 0,
        );

    test('accepts only the owned instance at its live epoch', () {
      expect(accepts({'instance_id': 0, 'session_epoch': 5}), isTrue);
      expect(accepts({'instance_id': 7, 'session_epoch': 5}), isFalse,
          reason: 'foreign instance');
      expect(accepts({'instance_id': 0, 'session_epoch': 4}), isFalse,
          reason: 'ended session of the same instance (account switch)');
      expect(accepts({'instance_id': 0, 'session_epoch': 0}), isFalse,
          reason: 'no session');
      expect(accepts({'instance_id': 0, 'session_epoch': 5}, live: const {}),
          isFalse,
          reason: 'instance currently has no live session');
      expect(accepts({'instance_id': -1, 'session_epoch': 5}), isFalse,
          reason: 'destroyed-instance sentinel');
      expect(
          accepts({'instance_id': 7, 'session_epoch': 9},
              owned: const {0, 7}, live: const {0: 5, 7: 9}),
          isTrue,
          reason: 'a shared service that owns a registered test node');
    });

    test('rejects unstamped or malformed payloads', () {
      expect(accepts({'group_id': 'g'}), isFalse);
      expect(accepts({'instance_id': 0}), isFalse);
      expect(accepts({'session_epoch': 5}), isFalse);
      expect(accepts({'instance_id': '0', 'session_epoch': 5}), isFalse);
      expect(accepts({'instance_id': 0, 'session_epoch': '5'}), isFalse);
    });
  });

  group('native stamping contract', () {
    String readSource(String relative) {
      for (final candidate in [
        File('../$relative'),
        File(relative),
        File('third_party/tim2tox/$relative'),
      ]) {
        if (candidate.existsSync()) return candidate.readAsStringSync();
      }
      throw StateError('tim2tox source not found: $relative');
    }

    test('every DartNotifyGroup* JSON carries the session stamp', () {
      final group = readSource('ffi/dart_compat_group.cpp');
      for (final fn in const [
        'void DartNotifyGroupQuit(',
        'void DartNotifyGroupJoin(',
        'void DartNotifyGroupIdentityStored(',
        'void DartNotifyGroupTypeStored(',
        'void DartNotifyGroupJoinFailed(',
        'void DartNotifyGroupKicked(',
        'void DartNotifyGroupInvite(',
      ]) {
        final start = group.indexOf(fn);
        expect(start, greaterThanOrEqualTo(0), reason: fn);
        final end = group.indexOf('\n    }\n', start);
        final body = group.substring(start, end);
        expect(body, contains('int64_t instance_id, int64_t session_epoch'),
            reason: fn);
        expect(
            body,
            contains(
                'AppendGroupNotifySessionStamp(json, instance_id, session_epoch);'),
            reason: fn);
      }
      // Durable notifications are keyed and discarded per instance.
      expect(group, contains('std::to_string(instance_id)'));
      final bridge = readSource('ffi/callback_bridge.cpp');
      expect(bridge, contains('void DiscardDurableCallbacksForInstance('));
      final manager = readSource('source/V2TIMManagerImpl.cpp');
      expect(
          manager,
          contains(
              'DiscardDurableCallbacksForInstance(GetInstanceIdFromManager(this));'));
      expect(manager,
          contains('session_epoch_.store(++g_next_session_epoch'));
    });
  });
}
