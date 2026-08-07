import 'dart:io';

void main() {
  final source = File('lib/sdk/tim2tox_sdk_platform.dart').readAsStringSync();

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

  _assertContains(
    _methodBody(
      source,
      'Future<V2TimCallback> transferGroupOwner({',
      'Future<V2TimCallback> setGroupApplicationRead() async {',
    ),
    'TIMGroupManager.instance.transferGroupOwner(',
    'transferGroupOwner should delegate to the native group manager',
  );
  _assertNotContains(
    _methodBody(
      source,
      'Future<V2TimCallback> transferGroupOwner({',
      'Future<V2TimCallback> setGroupApplicationRead() async {',
    ),
    "desc: 'success'",
    'transferGroupOwner should not keep the unconditional success stub',
  );

  _assertContains(
    _methodBody(
      source,
      'Future<V2TimCallback> muteGroupMember({',
      'Future<V2TimValueCallback<List<V2TimGroupMemberOperationResult>>>\n      inviteUserToGroup({',
    ),
    'TIMErrCode.ERR_SDK_INTERFACE_NOT_SUPPORT.value',
    'muteGroupMember should return the unsupported capability code',
  );
  _assertContains(
    source,
    "desc: 'Not supported'",
    'muteGroupMember should keep the unsupported description',
  );
  _assertNotContains(
    _methodBody(
      source,
      'Future<V2TimCallback> muteGroupMember({',
      'Future<V2TimValueCallback<List<V2TimGroupMemberOperationResult>>>\n      inviteUserToGroup({',
    ),
    'code: 0',
    'muteGroupMember should not report success',
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
