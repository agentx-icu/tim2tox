// Locks the ONE rule that separates the two identities `FfiChatService`
// carries, because getting it wrong is silent and user-visible:
//
//   * `selfId` is `V2TIMManagerImpl::GetLoginUser()` — the login ALIAS the
//     integrator supplies. toxee passes the constant `'FlutterUIKitClient'`
//     from every one of its login paths. The SDK stamps outbound messages with
//     the same value, so `selfId` is the CORRECT identity for message-level
//     self-recognition (`isSelf`, `fromUserId`, msgID composition) and must
//     stay there — changing msgID composition would also break history dedup.
//
//   * `prefsAccountScopeToxId` is the real Tox address. It is the ONLY correct
//     value for the `userToxId` scope of `ExtendedPreferencesService`'s
//     per-account key families (blacklist, per-peer/per-group receive option).
//     Scoping those by the alias filed every local account's mutes and blocked
//     list into ONE shared slot that no account-teardown path could collect.
//
// Two layers of guard:
//   1. a behavioural unit test over the pure decision rule
//      (`FfiChatService.accountScopeFromToxId`) — a login alias must be
//      REJECTED, a Tox address must survive byte-for-byte;
//   2. a source-text contract over the call sites, because they cannot be
//      driven from a unit test (constructing `FfiChatService` needs the native
//      library). It is the only automated guard that a future edit does not
//      quietly reintroduce `ffiService.selfId` as a persistence scope — or,
//      in the other direction, "helpfully" replace the message-identity uses.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

/// Every `ExtendedPreferencesService` member whose trailing OPTIONAL positional
/// argument is the account scope (`userToxId`), mapped to how many REQUIRED
/// arguments precede it. These are the calls that must never again be handed
/// `selfId`.
const Map<String, int> _accountScopedPrefsApis = <String, int>{
  'getBlackList': 0,
  'setBlackList': 1,
  'addToBlackList': 1,
  'removeFromBlackList': 1,
  'getC2CReceiveMessageOpt': 1,
  'setC2CReceiveMessageOpt': 2,
  'getGroupReceiveMessageOpt': 1,
  'setGroupReceiveMessageOpt': 2,
};

/// Split an argument list on top-level commas only, so a nested call's own
/// commas do not shift the positions.
List<String> splitTopLevelArgs(String args) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  for (final rune in args.split('')) {
    if (rune == '(' || rune == '[' || rune == '{') depth++;
    if (rune == ')' || rune == ']' || rune == '}') depth--;
    if (rune == ',' && depth == 0) {
      parts.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(rune);
    }
  }
  final tail = buffer.toString().trim();
  if (tail.isNotEmpty) parts.add(tail);
  return parts.where((p) => p.isNotEmpty).toList();
}

/// Return the text of every argument list that follows `name(` in [source],
/// paren-matched so nested calls are captured whole.
List<String> callArgumentLists(String source, String name) {
  final results = <String>[];
  final needle = '$name(';
  var from = 0;
  while (true) {
    final start = source.indexOf(needle, from);
    if (start < 0) break;
    // Skip declarations (`Future<...> getBlackList(...) async {`) and the
    // interface itself — we only care about invocations, which are always
    // preceded by a `.` or `?.`.
    final precededByDot = start > 0 && source[start - 1] == '.';
    var depth = 0;
    var i = start + needle.length - 1;
    for (; i < source.length; i++) {
      final c = source[i];
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (precededByDot && i < source.length) {
      results.add(source.substring(start + needle.length, i));
    }
    from = start + needle.length;
  }
  return results;
}

void main() {
  const String toxAddress =
      '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF'
      '89ABCDEF0123';
  const String publicKeyOnly =
      '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';

  group('accountScopeFromToxId — the identity rule', () {
    test('rejects the V2TIM login alias toxee passes to login()', () {
      // THE regression this whole change exists to prevent. Before the fix the
      // alias flowed straight through into the persistence scope.
      expect(
          FfiChatService.accountScopeFromToxId('FlutterUIKitClient'), isNull);
    });

    test('rejects any other non-Tox-shaped identifier', () {
      expect(FfiChatService.accountScopeFromToxId(null), isNull);
      expect(FfiChatService.accountScopeFromToxId(''), isNull);
      expect(FfiChatService.accountScopeFromToxId('   '), isNull);
      expect(FfiChatService.accountScopeFromToxId('user-42'), isNull);
      // Right alphabet, wrong length — a truncated FFI read must not become a
      // scope that collides with a different account's prefix.
      expect(FfiChatService.accountScopeFromToxId('0123456789ABCDEF'), isNull);
      expect(
        FfiChatService.accountScopeFromToxId('${toxAddress}00'),
        isNull,
      );
      // 76 characters but not hex.
      expect(
        FfiChatService.accountScopeFromToxId('Z' * 76),
        isNull,
      );
    });

    test('accepts a full Tox address and returns it byte-for-byte', () {
      expect(
        FfiChatService.accountScopeFromToxId(toxAddress),
        toxAddress,
      );
      // Surrounding whitespace is trimmed, but the id itself is NOT normalised:
      // scoped keys are byte-compared against what the host stored, so case
      // folding here would orphan every existing entry.
      expect(
        FfiChatService.accountScopeFromToxId('  $toxAddress  '),
        toxAddress,
      );
      final lower = toxAddress.toLowerCase();
      expect(FfiChatService.accountScopeFromToxId(lower), lower);
    });

    test('accepts the bare-public-key degenerate form', () {
      // `V2TIMManagerImpl::Login` stores just the public key when
      // `ToxManager::getAddress()` comes back short. Still account-unique, and
      // its first 16 chars — all a scoped key uses — match the 76-char form.
      expect(
        FfiChatService.accountScopeFromToxId(publicKeyOnly),
        publicKeyOnly,
      );
      expect(
        publicKeyOnly.substring(0, 16),
        toxAddress.substring(0, 16),
        reason: 'the two accepted forms must agree on the scope prefix',
      );
    });
  });

  group('call-site contract', () {
    final service = File(
      '${Directory.current.path}/lib/service/ffi_chat_service.dart',
    );
    final platform = File(
      '${Directory.current.path}/lib/sdk/tim2tox_sdk_platform.dart',
    );
    final converters = File(
      '${Directory.current.path}/lib/sdk/tim2tox_sdk_platform_converters.dart',
    );

    test('the sources this contract reads are where it expects them', () {
      for (final f in <File>[service, platform, converters]) {
        expect(f.existsSync(), isTrue,
            reason: 'missing ${f.path} — run this suite from the package root '
                '(third_party/tim2tox/dart)');
      }
    });

    test('no account-scoped prefs call is handed selfId', () async {
      for (final file in <File>[service, platform, converters]) {
        final source = await file.readAsString();
        for (final api in _accountScopedPrefsApis.keys) {
          for (final args in callArgumentLists(source, api)) {
            expect(
              args.contains('selfId'),
              isFalse,
              reason: '${file.path}: `$api($args)` passes the V2TIM login '
                  'alias as the account scope. Use '
                  '`prefsAccountScopeToxId` (nullable) instead — see '
                  'FfiChatService.accountScopeFromToxId.',
            );
          }
        }
      }
    });

    test('every account-scoped prefs call that names a scope uses the Tox one',
        () async {
      // The positive half of the guard above: proves the call sites did not
      // just drop the argument (which would silently re-derive the scope from
      // the host's active account on paths that must be explicit).
      var scopedCalls = 0;
      for (final file in <File>[service, platform, converters]) {
        final source = await file.readAsString();
        for (final entry in _accountScopedPrefsApis.entries) {
          for (final args in callArgumentLists(source, entry.key)) {
            final parts = splitTopLevelArgs(args);
            if (parts.length <= entry.value) continue; // scope omitted
            final scopeArg = parts.last;
            scopedCalls++;
            expect(
              scopeArg,
              anyOf(
                contains('prefsAccountScopeToxId'),
                // Locals the call sites bind the getter to first.
                equals('currentUserToxId'),
                equals('accountScope'),
                equals('scope'),
              ),
              reason: '${file.path}: `${entry.key}(...)` scopes on '
                  '`$scopeArg`, which is not derived from the Tox identity.',
            );
          }
        }
      }
      expect(scopedCalls, greaterThanOrEqualTo(8),
          reason: 'the scan found almost no scoped calls — the extractor is '
              'probably broken, so the guard above proves nothing');
    });

    test('message identity still uses selfId (class ① untouched)', () async {
      final source = await service.readAsString();
      // msgID composition: changing it would break history de-duplication
      // across the binary-replacement and platform paths.
      expect(source, contains(r'_${_msgIDSequence++}_$_selfId'));
      // Self-recognition on inbound messages.
      expect(source, contains(r'isSelf: from == _selfId'));
      expect(source, contains(r'fromUserId: _selfId'));
    });

    test('the blacklist refresh scopes on the Tox identity, not the alias',
        () async {
      final source = await service.readAsString();
      final start = source.indexOf('Future<void> refreshBlockedUsers()');
      expect(start, greaterThan(0));
      final body = source.substring(start, start + 600);
      expect(body, contains('prefsAccountScopeToxId'));
      // A null scope must NOT be passed down: the blacklist key builders on the
      // host turn a null scope into one global slot shared by every account.
      expect(body, contains('if (scope == null)'));
      expect(body, isNot(contains('getBlackList(_selfId)')));
    });
  });
}
