import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_status.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_custom_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_file_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_image_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_sound_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_text_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_video_elem.dart';

/// Wire desc for a refused group media send. Deliberately contains "group"
/// and "file": integrators pattern-match the desc to localize it (toxee's
/// SendFailureNotifier maps it to its "file transfer in groups is not
/// supported" string).
const String kGroupMediaUnsupportedDesc =
    'File transfer in group chats is not supported';

/// True for a message Tox cannot carry into a group: a pure media message
/// (image / file / sound / video with no text element). `tox_file_send` is
/// friend-only, so such a send can never succeed — it is refused up front and
/// NOT persisted as a retryable failed row.
bool isUnsupportedGroupMedia(V2TimMessage message) {
  if (message.textElem != null) return false;
  return message.imageElem != null ||
      message.fileElem != null ||
      message.soundElem != null ||
      message.videoElem != null;
}

/// Destination of a persisted failed row. The row's own `userID`/`groupID`
/// are authoritative; legacy rows only carry the conversation key, where every
/// toxee group ID starts with `tox_` (`tox_conf_`, `tox_group_`) and C2C peer
/// IDs are raw hex public keys that never do.
({String? userID, String? groupID}) failedRowTarget(
  Map<String, dynamic> entry,
  String conversationKey,
) {
  String? userID = entry['userID'] as String?;
  String? groupID = entry['groupID'] as String?;
  if ((userID == null || userID.isEmpty) &&
      (groupID == null || groupID.isEmpty)) {
    if (conversationKey.startsWith('tox_')) {
      groupID = conversationKey;
    } else {
      userID = conversationKey;
    }
  }
  if (groupID != null && groupID.isNotEmpty) return (userID: null, groupID: groupID);
  return (userID: userID, groupID: null);
}

/// Rebuild the V2TimMessage a failed-message row (see
/// `Tim2ToxFailedMessagePersistence.saveFailedMessage`, schema v1/v2) stands
/// for, INCLUDING its media element — the single rebuild used by
/// `reSendMessage`, by the history merge in `getHistoryMessageListV2`, and by
/// integrators rendering a conversation preview off a failed row.
///
/// Returns `(message: null, error: …)` when a media row has no usable local
/// path (nothing to render or resend). The rebuilt message carries the row's
/// timestamp and `SEND_FAIL`; a resend overrides both.
({V2TimMessage? message, String? error}) rebuildFailedMessage(
  Map<String, dynamic> entry, {
  required String conversationKey,
  String fallbackID = '',
}) {
  final storedID = entry['id'] as String?;
  final storedMsgID = entry['msgID'] as String?;
  final id = storedID == null || storedID.isEmpty
      ? (storedMsgID == null || storedMsgID.isEmpty ? fallbackID : storedMsgID)
      : storedID;
  final msgID =
      storedMsgID == null || storedMsgID.isEmpty ? (id.isEmpty ? fallbackID : id) : storedMsgID;
  final mediaKind = entry['mediaKind'] as String?;
  final text = entry['text'] as String? ?? '';
  final filePath = entry['filePath'] as String?;
  final fileName = entry['fileName'] as String?;
  final fileSize = entry['fileSize'] as int?;
  final localUrl = entry['localUrl'] as String?;
  final customData = entry['customData'] as String?;

  int elemType =
      entry['elemType'] as int? ?? MessageElemType.V2TIM_ELEM_TYPE_TEXT;
  // mediaKind takes precedence when present (v2 entries).
  switch (mediaKind) {
    case 'image':
      elemType = MessageElemType.V2TIM_ELEM_TYPE_IMAGE;
    case 'file':
      elemType = MessageElemType.V2TIM_ELEM_TYPE_FILE;
    case 'audio':
      elemType = MessageElemType.V2TIM_ELEM_TYPE_SOUND;
    case 'video':
      elemType = MessageElemType.V2TIM_ELEM_TYPE_VIDEO;
    case 'custom':
      elemType = MessageElemType.V2TIM_ELEM_TYPE_CUSTOM;
  }

  final rebuilt = V2TimMessage(elemType: elemType);
  rebuilt.msgID = msgID;
  rebuilt.id = id;
  rebuilt.isSelf = entry['isSelf'] as bool? ?? true;
  rebuilt.timestamp = entry['timestamp'] as int?;
  rebuilt.status = MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL;
  if (entry['needReadReceipt'] == true) rebuilt.needReadReceipt = true;
  final target = failedRowTarget(entry, conversationKey);
  rebuilt.userID = target.userID;
  rebuilt.groupID = target.groupID;

  // Always include a textElem when the entry had text (e.g. text
  // messages, file-with-caption). For pure media this stays null.
  if (text.isNotEmpty) {
    rebuilt.textElem = V2TimTextElem(text: text);
  }

  final path = filePath ?? localUrl;
  String? missingPath(String kind) => path == null || path.isEmpty
      ? '$kind entry missing filePath/localUrl for msgID=$msgID'
      : null;
  Object? elem;
  switch (elemType) {
    case MessageElemType.V2TIM_ELEM_TYPE_IMAGE:
      final error = missingPath('image');
      if (error != null) return (message: null, error: error);
      elem = rebuilt.imageElem = V2TimImageElem(path: path);
    case MessageElemType.V2TIM_ELEM_TYPE_FILE:
      final error = missingPath('file');
      if (error != null) return (message: null, error: error);
      elem = rebuilt.fileElem = V2TimFileElem(
        path: path,
        fileName: fileName ?? path!.split('/').last,
        fileSize: fileSize,
        localUrl: localUrl,
      );
    case MessageElemType.V2TIM_ELEM_TYPE_SOUND:
      final error = missingPath('sound');
      if (error != null) return (message: null, error: error);
      elem = rebuilt.soundElem = V2TimSoundElem(
        path: path,
        dataSize: fileSize,
        duration: entry['soundDuration'] as int?,
      );
    case MessageElemType.V2TIM_ELEM_TYPE_VIDEO:
      final error = missingPath('video');
      if (error != null) return (message: null, error: error);
      elem = rebuilt.videoElem = V2TimVideoElem(
        videoPath: path,
        videoSize: fileSize,
        duration: entry['videoDuration'] as int?,
      );
    case MessageElemType.V2TIM_ELEM_TYPE_CUSTOM:
      elem = rebuilt.customElem = V2TimCustomElem(data: customData ?? '');
    default:
      // text-only or unknown elemType — treat as text.
      rebuilt.elemType = MessageElemType.V2TIM_ELEM_TYPE_TEXT;
      rebuilt.textElem ??= V2TimTextElem(text: text);
      elem = rebuilt.textElem;
  }
  rebuilt.elemList.add(elem);
  return (message: rebuilt, error: null);
}

/// Merge persisted failed rows into one `getHistoryMessageListV2` page.
///
/// Failed sends that never reached the Dart history store (a send that threw,
/// or was refused, before `FfiChatService` recorded it) live only in
/// `Tim2ToxFailedMessagePersistence`; without this they vanished from the chat
/// on reload while the conversation preview kept showing them.
///
/// [page] is newest-first. A failed row is placed on the page whose time
/// window contains it: `(oldest row of the page, anchorTimestamp]`, where a
/// null [anchorTimestamp] (the initial page) is unbounded above and a finished
/// page ([isFinished]) is unbounded below. A failed row is therefore never the
/// OLDEST row of a page that has a successor, so it can never become the
/// `lastMsgID` anchor of the next request (history does not contain it). An
/// unfinished empty page takes none.
///
/// Rows whose id/msgID is in [historyIds] are not added again; if such a row
/// is on this page it is marked `SEND_FAIL` (the persistence is authoritative:
/// rows leave it only on a successful resend or a delete).
List<V2TimMessage> mergeFailedRowsIntoHistoryPage({
  required List<V2TimMessage> page,
  required List<({String conversationKey, Map<String, dynamic> entry})>
      failedRows,
  required Set<String> historyIds,
  required bool isFinished,
  required int? anchorTimestamp,
}) {
  if (failedRows.isEmpty) return page;
  final merged = List<V2TimMessage>.of(page);
  final failedIds = <String>{};
  final additions = <V2TimMessage>[];
  final seenAdded = <String>{};
  for (final row in failedRows) {
    final ids = <String>{
      if (row.entry['id'] case final String id when id.isNotEmpty) id,
      if (row.entry['msgID'] case final String m when m.isNotEmpty) m,
    };
    if (ids.isEmpty) continue;
    failedIds.addAll(ids);
    if (ids.any(historyIds.contains)) continue;
    if (ids.any(seenAdded.contains)) continue;
    final rebuilt = rebuildFailedMessage(
      row.entry,
      conversationKey: row.conversationKey,
    ).message;
    if (rebuilt == null) continue;
    final ts = rebuilt.timestamp ?? 0;
    if (anchorTimestamp != null && ts > anchorTimestamp) continue;
    if (!isFinished) {
      if (merged.isEmpty) continue;
      if (ts <= (page.last.timestamp ?? 0)) continue;
    }
    seenAdded.addAll(ids);
    additions.add(rebuilt);
  }
  for (final msg in merged) {
    if (failedIds.contains(msg.msgID) || failedIds.contains(msg.id)) {
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL;
    }
  }
  // Newest-first insertion that keeps the page's own relative order.
  additions.sort((a, b) => (b.timestamp ?? 0).compareTo(a.timestamp ?? 0));
  for (final add in additions) {
    final ts = add.timestamp ?? 0;
    final at = merged.indexWhere((m) => (m.timestamp ?? 0) < ts);
    if (at < 0) {
      merged.add(add);
    } else {
      merged.insert(at, add);
    }
  }
  return merged;
}
