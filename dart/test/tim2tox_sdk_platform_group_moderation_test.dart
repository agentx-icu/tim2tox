import 'dart:io';

void main() {
  final source = File('lib/sdk/tim2tox_sdk_platform.dart').readAsStringSync();

  // The platform IS what the routed facade (manager/v2_tim_group_manager.dart,
  // `V2TIMGroupManager`) dispatches to when `isPlatformRouted`, so every
  // group-member operation here must reach the NATIVE adapter
  // (native_im/adapter/tim_group_manager.dart, `TIMGroupManager` → Dart*
  // bindings). Going through the facade would call back into this platform
  // forever.
  _assertContains(
    source,
    "import 'package:tencent_cloud_chat_sdk/native_im/adapter/tim_group_manager.dart';",
    'the platform must use the native group adapter',
  );
  for (final forbidden in const [
    'manager/v2_tim_group_manager.dart',
    'V2TIMGroupManager(',
    'V2TIMGroupManager.',
    'v2TIMGroupManager',
    'getGroupManager()',
    'TencentImSDKPlugin',
  ]) {
    _assertNotContains(
      source,
      forbidden,
      'the platform must never call the routed group facade ($forbidden)',
    );
  }
  final serviceSource =
      File('lib/service/ffi_chat_service.dart').readAsStringSync();
  for (final forbidden in const [
    'manager/v2_tim_group_manager.dart',
    'V2TIMGroupManager(',
    'V2TIMGroupManager.',
    'v2TIMGroupManager',
    'getGroupManager()',
    'TencentImSDKPlugin',
  ]) {
    _assertNotContains(
      serviceSource,
      forbidden,
      'FfiChatService must never call the routed group facade ($forbidden)',
    );
  }

  _assertContains(
    _methodBody(
      source,
      'Future<V2TimCallback> setGroupMemberRole({',
      'Future<V2TimCallback> transferGroupOwner({',
    ),
    'TIMGroupManager.instance.setGroupMemberRole(',
    'setGroupMemberRole should delegate to the native group manager',
  );
  _assertContains(
    source,
    'EnumUtils.convertGroupMemberRoleType(role)',
    'setGroupMemberRole should preserve the V2TIM role enum mapping',
  );
  _assertNotContains(
    _methodBody(
      source,
      'Future<V2TimCallback> setGroupMemberRole({',
      'Future<V2TimCallback> transferGroupOwner({',
    ),
    "desc: 'success'",
    'setGroupMemberRole should not keep the unconditional success stub',
  );

  // MM-8: an NGC founder role cannot be handed over (toxcore's
  // gc_set_peer_role rejects GR_FOUNDER as a target), and the native adapter's
  // transferGroupOwner (DartSetGroupInfo with only `owner`) used to report a
  // transfer that never happened. The platform refuses honestly instead:
  // the unsupported-capability code with a message that says why.
  final transferBody = _methodBody(
    source,
    'Future<V2TimCallback> transferGroupOwner({',
    'Future<V2TimCallback> setGroupApplicationRead() async {',
  );
  _assertContains(
    transferBody,
    'TIMErrCode.ERR_SDK_INTERFACE_NOT_SUPPORT.value',
    'transferGroupOwner should refuse with the unsupported capability code',
  );
  _assertContains(
    transferBody,
    "desc: 'Group ownership cannot be transferred on Tox'",
    'transferGroupOwner should explain why the transfer is refused',
  );
  _assertNotContains(
    transferBody,
    'TIMGroupManager.instance.transferGroupOwner(',
    'transferGroupOwner must not delegate to the adapter that fakes success',
  );
  _assertNotContains(
    transferBody,
    'code: 0',
    'transferGroupOwner should not report success',
  );

  // Mute is real now: native maps a mute to the NGC OBSERVER role
  // (DartModifyGroupMemberInfo with shutup_time), so the platform delegates
  // to the native group manager instead of refusing.
  final muteBody = _methodBody(
    source,
    'Future<V2TimCallback> muteGroupMember({',
    'Future<V2TimValueCallback<List<V2TimGroupMemberOperationResult>>>\n      inviteUserToGroup({',
  );
  _assertContains(
    muteBody,
    'TIMGroupManager.instance.muteGroupMember(',
    'muteGroupMember should delegate to the native group manager',
  );
  _assertNotContains(
    muteBody,
    'code: 0',
    'muteGroupMember should not report an unconditional success',
  );

  _assertContains(
    _methodBody(
      source,
      'Future<V2TimCallback> setGroupApplicationRead() async {',
      'Future<V2TimValueCallback<List<V2TimUserStatus>>> getUserStatus({',
    ),
    'TIMErrCode.ERR_SDK_INTERFACE_NOT_SUPPORT.value',
    'setGroupApplicationRead should return the unsupported capability code',
  );
  _assertContains(
    source,
    "desc: 'Not supported'",
    'setGroupApplicationRead should keep the unsupported description',
  );
  _assertNotContains(
    _methodBody(
      source,
      'Future<V2TimCallback> setGroupApplicationRead() async {',
      'Future<V2TimValueCallback<List<V2TimUserStatus>>> getUserStatus({',
    ),
    'code: 0',
    'setGroupApplicationRead should not report success',
  );
}

String _methodBody(String source, String startMarker, String endMarker) {
  final startIndex = source.indexOf(startMarker);
  if (startIndex < 0) {
    throw StateError('missing start marker: $startMarker');
  }

  final endIndex = source.indexOf(endMarker, startIndex);
  if (endIndex <= startIndex) {
    throw StateError('missing end marker: $endMarker');
  }

  return source.substring(startIndex, endIndex);
}

void _assertContains(String haystack, String needle, String message) {
  if (!haystack.contains(needle)) {
    throw StateError(message);
  }
}

void _assertNotContains(String haystack, String needle, String message) {
  if (haystack.contains(needle)) {
    throw StateError(message);
  }
}
