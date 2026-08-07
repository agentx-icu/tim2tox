import 'dart:io';

void main() {
  final platformSource =
      File('lib/sdk/tim2tox_sdk_platform.dart').readAsStringSync();
  final ffiSource = File('lib/ffi/tim2tox_ffi.dart').readAsStringSync();

  final createBody = _methodBody(
    platformSource,
    'Future<V2TimValueCallback<String>> createGroup({',
    'Future<V2TimCallback> joinGroup({',
  );
  _assertContains(
    createBody,
    'groupType: _nativeGroupTypeForCreate(groupType),',
    'createGroup must map and forward the caller group type to FfiChatService',
  );
  _assertNotContains(
    createBody,
    'ffiService.createGroup(groupName);',
    'createGroup must not rely on the FfiChatService default group type',
  );

  final createTypeMapping = _methodBody(
    platformSource,
    'String _nativeGroupTypeForCreate(String groupType)',
    'String _groupTypeForGroupInfo(String groupID)',
  );
  _assertContains(
    createTypeMapping,
    'case GroupType.Work:',
    'createGroup mapping must handle SDK Work groups explicitly',
  );
  _assertContains(
    createTypeMapping,
    "return 'Private';",
    'SDK Work groups must map to the native Private group type',
  );
  _assertContains(
    createTypeMapping,
    "case 'conference':",
    'createGroup mapping must preserve legacy conference group types',
  );

  final storedGroupTypeHelper = _methodBody(
    platformSource,
    'String _normalizeStoredGroupType(String storedType)',
    'String _groupTypeForGroupInfo(String groupID)',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'private':",
    'read-back mapping must collapse native Private to Work',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'group':",
    'read-back mapping must collapse generic group labels to Work',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'work':",
    'read-back mapping must collapse legacy Work labels to Work',
  );
  _assertContains(
    storedGroupTypeHelper,
    'return GroupType.Work;',
    'read-back mapping must normalize native Private/group/Work to Work',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'public':",
    'read-back mapping must preserve valid SDK Public groups',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'meeting':",
    'read-back mapping must preserve valid SDK Meeting groups',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'avchatroom':",
    'read-back mapping must preserve valid SDK AVChatRoom groups',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'community':",
    'read-back mapping must preserve valid SDK Community groups',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'conference':",
    'read-back mapping must preserve custom legacy conference labels',
  );
  _assertContains(
    storedGroupTypeHelper,
    "case 'av_conference':",
    'read-back mapping must preserve custom AV conference labels',
  );
  _assertContains(
    storedGroupTypeHelper,
    'return storedType;',
    'read-back mapping must keep unknown labels intact',
  );

  final groupsInfoBody = _methodBody(
    platformSource,
    'Future<V2TimValueCallback<List<V2TimGroupInfoResult>>> getGroupsInfo({',
    'Future<V2TimValueCallback<List<V2TimGroupInfo>>> getJoinedGroupList() async {',
  );
  _assertContains(
    groupsInfoBody,
    'groupType: _groupTypeForGroupInfo(groupID),',
    'getGroupsInfo must project the native stored group type',
  );
  _assertNotContains(
    groupsInfoBody,
    'groupType: GroupType.Work',
    'getGroupsInfo must not hardcode every group as Work',
  );

  final joinedGroupListBody = _methodBody(
    platformSource,
    'Future<V2TimValueCallback<List<V2TimGroupInfo>>> getJoinedGroupList() async {',
    'Future<V2TimValueCallback<V2TimGroupMemberInfoResult>> getGroupMemberList({',
  );
  _assertContains(
    joinedGroupListBody,
    'groupType: _groupTypeForGroupInfo(groupID),',
    'getJoinedGroupList must project the native stored group type',
  );
  _assertNotContains(
    joinedGroupListBody,
    'groupType: GroupType.Work',
    'getJoinedGroupList must not hardcode every group as Work',
  );

  final groupInfoTypeHelper = _methodBody(
    platformSource,
    'String _groupTypeForGroupInfo(String groupID)',
    '@override\n  Future<void> addGroupListener({',
  );
  _assertContains(
    groupInfoTypeHelper,
    '_normalizeStoredGroupType(storedType)',
    'group info lookup must normalize the stored native label before returning it',
  );
  _assertContains(
    groupInfoTypeHelper,
    '_storedGroupType(groupID) ?? GroupType.Work',
    'group info fallback must only use Work when native storage has no type',
  );

  _assertContains(
    ffiSource,
    'typedef _get_group_type_from_storage_c',
    'Tim2ToxFfi must bind the native group-type storage getter',
  );
  _assertContains(
    ffiSource,
    'getGroupTypeFromStorageNative',
    'Tim2ToxFfi must expose the native group-type storage getter',
  );
  _assertContains(
    ffiSource,
    "'tim2tox_ffi_get_group_type_from_storage'",
    'Tim2ToxFfi must bind the exact native getter symbol',
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
