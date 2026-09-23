import 'package:path/path.dart' as p;
import 'dart:convert';
import 'dart:io';

/// User-visible message transport semantics.
enum ChatMessageContentKind { normal, action, custom }

const String tim2ToxContentKindLocalCustomDataKey = 'tim2toxContentKind';

ChatMessageContentKind chatMessageContentKindFromJson(Object? value) {
  if (value == ChatMessageContentKind.action.name) {
    return ChatMessageContentKind.action;
  }
  if (value == ChatMessageContentKind.custom.name) {
    return ChatMessageContentKind.custom;
  }
  return ChatMessageContentKind.normal;
}

ChatMessageContentKind chatMessageContentKindFromLocalCustomData(String? data) {
  if (data == null || data.isEmpty) return ChatMessageContentKind.normal;
  try {
    final decoded = jsonDecode(data);
    if (decoded is Map<String, dynamic>) {
      return chatMessageContentKindFromJson(
        decoded[tim2ToxContentKindLocalCustomDataKey],
      );
    }
  } on FormatException {
    // Unknown local metadata is not an ACTION marker.
  }
  return ChatMessageContentKind.normal;
}

String mergeChatMessageContentKindLocalCustomData(
  String? data,
  ChatMessageContentKind contentKind,
) {
  if (contentKind == ChatMessageContentKind.normal) return data ?? '';
  final merged = <String, dynamic>{};
  if (data != null && data.isNotEmpty) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) merged.addAll(decoded);
    } on FormatException {
      // V2TIM localCustomData is conventionally JSON. An opaque legacy value
      // cannot be merged safely, so the typed marker takes precedence.
    }
  }
  merged[tim2ToxContentKindLocalCustomDataKey] = contentKind.name;
  return jsonEncode(merged);
}

/// `localCustomData` key under which the native advanced listener delivers an
/// inbound NGC group message's `Tox_Group_Message_Id` (a uint32 the sender
/// mints and every member decodes identically). The polled `gtext:` /
/// `gaction:` line carries the same value as its `|m<id>` header segment.
const String toxGroupMsgIdLocalCustomDataKey = 'toxGroupMsgId';

/// Prefix of the cross-path / cross-peer group message identity
/// ([toxGroupMessageAlias]) stored in [ChatMessage.altMsgIds].
const String toxGroupMessageAliasPrefix = 'gmid:';

/// The `Tox_Group_Message_Id` carried in a V2TIM message's `localCustomData`,
/// or null when absent. Tolerant: empty, non-JSON, non-object, a missing key,
/// or a value that is not an integral uint32 all mean "no id" — a garbled id
/// must never cost the message itself, it only loses exact dedupe.
int? toxGroupMsgIdFromLocalCustomData(String? data) {
  if (data == null || data.isEmpty) return null;
  final trimmed = data.trimLeft();
  if (!trimmed.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return null;
    final value = decoded[toxGroupMsgIdLocalCustomDataKey];
    final int? id = value is int
        ? value
        : (value is double && value == value.truncateToDouble()
            ? value.toInt()
            : null);
    if (id == null || id < 0 || id > 0xFFFFFFFF) return null;
    return id;
  } on FormatException {
    return null;
  }
}

/// The cross-path identity of one NGC group message, scoped so that a 32-bit
/// random pseudo id cannot collide across groups or authors. Both inbound
/// paths stamp it into [ChatMessage.altMsgIds]: the poll path from the
/// `gtext:` header, the binary-replacement path from [MessageConverter] via
/// [toxGroupMsgIdFromLocalCustomData]. Both see the same per-group sender key.
String toxGroupMessageAlias({
  required String groupId,
  required String senderPk,
  required int pseudoMsgId,
}) =>
    '$toxGroupMessageAliasPrefix$groupId|${senderPk.toUpperCase()}|$pseudoMsgId';

/// The group identity alias a row carries, or null (C2C, legacy conference,
/// custom packets, or a native library that predates the id).
String? toxGroupMessageAliasOf(ChatMessage message) {
  for (final id in message.altMsgIds) {
    if (id.startsWith(toxGroupMessageAliasPrefix)) return id;
  }
  final primary = message.msgID;
  if (primary != null && primary.startsWith(toxGroupMessageAliasPrefix)) {
    return primary;
  }
  return null;
}

/// Whether two rows are the same logical group message by IDENTITY:
/// true when both carry the same [toxGroupMessageAlias], false when both carry
/// one and they differ (two genuine messages, however identical their text),
/// null when at least one side has no identity — only then may a caller fall
/// back to its content+time heuristic.
bool? chatMessagesShareGroupIdentity(ChatMessage a, ChatMessage b) {
  final aliasA = toxGroupMessageAliasOf(a);
  if (aliasA == null) return null;
  final aliasB = toxGroupMessageAliasOf(b);
  if (aliasB == null) return null;
  return aliasA == aliasB;
}

/// Sorts [messages] in place by timestamp, STABLY: rows with equal timestamps
/// keep their relative input order (history lists are kept in arrival order,
/// and that order is what is persisted). `List.sort` is not stable past 32
/// elements, so equal timestamps — whole-second native rows, same-ms bursts —
/// used to come back in arbitrary order after a reload. With [newestFirst],
/// ties come out latest-arrival first (the exact reverse of oldest-first).
void sortChatMessagesChronologically(
  List<ChatMessage> messages, {
  bool newestFirst = false,
}) {
  if (messages.length < 2) return;
  final indexed = List<(int, ChatMessage)>.generate(
    messages.length,
    (i) => (i, messages[i]),
    growable: false,
  );
  indexed.sort((a, b) {
    final byTime = a.$2.timestamp.compareTo(b.$2.timestamp);
    final order = byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    return newestFirst ? -order : order;
  });
  for (var i = 0; i < indexed.length; i++) {
    messages[i] = indexed[i].$2;
  }
}

({String text, ChatMessageContentKind contentKind}) parseOutgoingChatText(
  String text,
) {
  if (text.length >= 4 && text.substring(0, 4).toLowerCase() == '/me ') {
    return (
      text: text.substring(4),
      contentKind: ChatMessageContentKind.action,
    );
  }
  return (text: text, contentKind: ChatMessageContentKind.normal);
}

/// Chat message model
class ChatMessage {
  ChatMessage({
    required this.text,
    required this.fromUserId,
    required this.isSelf,
    required this.timestamp,
    this.groupId,
    this.filePath,
    this.fileName,
    this.mediaKind,
    this.isPending = false,
    this.isReceived = false,
    this.isRead = false,
    this.msgID,
    this.version = 1, // Message format version for migration support
    this.fileSize, // File size in bytes
    this.mimeType, // MIME type of the file
    this.fileHash, // SHA256 hash of file content (optional)
    this.altMsgIds = const [], // ids of cross-path duplicates absorbed here
    this.cloudCustomData, // structured reply/forward metadata (JSON string)
    this.needReadReceipt = false, // sender asked for read receipts (groups)
    this.contentKind = ChatMessageContentKind.normal,
    this.sourceInstanceId,
  });

  final String text;
  final String fromUserId;
  final bool isSelf;
  final DateTime timestamp;
  final String? groupId;
  final String? filePath;
  final String? fileName;
  final String? mediaKind; // 'image' | 'video' | 'audio' | 'file' | 'custom'
  final bool isPending;
  final bool isReceived;
  final bool isRead;
  final String? msgID;

  /// Additional msgIDs that resolve to this same logical message.
  ///
  /// toxee's hybrid runtime delivers one inbound message through two paths
  /// (binary-replacement V2TimAdvancedMsgListener with a native
  /// `msg_<n>_<nanos>_<seq>` id, and the FfiChatService poll path with a
  /// `<millis>_<n>_<toxId>` id). When [MessageHistoryPersistence.appendHistory]
  /// content-dedups the two copies into this one row, the id that did NOT
  /// become [msgID] is recorded here so later exact-id lookups (updateMessage /
  /// removeMessage / revoke via either path) still resolve to this row. Stored
  /// ON the row so it persists, reloads, and is trimmed together with the
  /// message — no external alias map to desync or leak.
  final List<String> altMsgIds;

  /// Structured per-message metadata as a JSON string (the V2TIM
  /// `cloudCustomData`). Carries the reply quote
  /// (`{"messageReply":{messageID,messageAbstract,messageSender,...}}`) that the
  /// UIKit composer builds when replying to a message. Persisted sender-side so
  /// the quote survives a reload (previously it lived only on the in-memory
  /// V2TimMessage and was lost on cold start).
  ///
  /// WIRE LIMITATION: toxee's Tox send (`_ffi.sendText`) carries plain text
  /// only, so this is NOT delivered to the peer today — it is a local
  /// sender-side record. The peer-receives-the-quote leg needs a Tox
  /// wire-format change (out of scope). Null for plain messages.
  final String? cloudCustomData;
  final bool needReadReceipt;

  final ChatMessageContentKind contentKind;

  /// Polling instance that produced this live event.
  ///
  /// This is dispatch-only metadata and is deliberately omitted from JSON so
  /// persisted history remains instance-agnostic.
  final int? sourceInstanceId;

  // New fields for enhanced data integrity
  final int version; // Message format version
  final int? fileSize; // File size in bytes
  final String? mimeType; // MIME type
  final String? fileHash; // SHA256 hash (optional, for integrity verification)

  Map<String, dynamic> toJson() => {
        'text': text,
        'fromUserId': fromUserId,
        'isSelf': isSelf,
        'timestamp': timestamp.toIso8601String(),
        'groupId': groupId,
        'filePath': filePath,
        'fileName': fileName,
        'mediaKind': mediaKind,
        'contentKind': contentKind.name,
        'isPending': isPending,
        'isReceived': isReceived,
        'isRead': isRead,
        'msgID': msgID,
        'version': version,
        if (fileSize != null) 'fileSize': fileSize,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileHash != null) 'fileHash': fileHash,
        if (altMsgIds.isNotEmpty) 'altMsgIds': altMsgIds,
        // Backward compatible: gated so plain messages serialize byte-identically
        // (existing on-disk history has no cloudCustomData key).
        if (cloudCustomData != null) 'cloudCustomData': cloudCustomData,
        // Backward compatible: gated like cloudCustomData, so rows without the
        // flag keep serializing byte-identically.
        if (needReadReceipt) 'needReadReceipt': true,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        text: json['text'] as String,
        fromUserId: json['fromUserId'] as String,
        isSelf: json['isSelf'] as bool,
        timestamp: DateTime.parse(json['timestamp'] as String),
        groupId: json['groupId'] as String?,
        filePath: json['filePath'] as String?,
        fileName: json['fileName'] as String?,
        mediaKind: json['mediaKind'] as String?,
        contentKind: chatMessageContentKindFromJson(json['contentKind']),
        isPending: json['isPending'] as bool? ?? false,
        isReceived: json['isReceived'] as bool? ?? false,
        isRead: json['isRead'] as bool? ?? false,
        msgID: json['msgID'] as String?,
        version: json['version'] as int? ??
            1, // Default to version 1 for backward compatibility
        fileSize: json['fileSize'] as int?,
        mimeType: json['mimeType'] as String?,
        fileHash: json['fileHash'] as String?,
        // Backward compatible: pre-existing history has no altMsgIds key.
        altMsgIds:
            (json['altMsgIds'] as List?)?.map((e) => e as String).toList() ??
                const [],
        // Backward compatible: pre-existing history has no cloudCustomData key.
        cloudCustomData: json['cloudCustomData'] as String?,
        needReadReceipt: json['needReadReceipt'] as bool? ?? false,
      );

  ChatMessage copyWith({
    bool? isReceived,
    bool? isRead,
    bool? isPending,
    String? filePath,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? fileHash,
    List<String>? altMsgIds,
    String? cloudCustomData,
    bool? needReadReceipt,
    ChatMessageContentKind? contentKind,
    int? sourceInstanceId,
  }) {
    return ChatMessage(
      text: text,
      fromUserId: fromUserId,
      isSelf: isSelf,
      timestamp: timestamp,
      groupId: groupId,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      mediaKind: mediaKind,
      isPending: isPending ?? this.isPending,
      isReceived: isReceived ?? this.isReceived,
      isRead: isRead ?? this.isRead,
      msgID: msgID,
      version: version,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      fileHash: fileHash ?? this.fileHash,
      altMsgIds: altMsgIds ?? this.altMsgIds,
      cloudCustomData: cloudCustomData ?? this.cloudCustomData,
      needReadReceipt: needReadReceipt ?? this.needReadReceipt,
      contentKind: contentKind ?? this.contentKind,
      sourceInstanceId: sourceInstanceId ?? this.sourceInstanceId,
    );
  }

  /// Verify file integrity
  ///
  /// Checks if the file exists and optionally verifies size and hash.
  ///
  /// Returns true if file is valid, false otherwise.
  Future<bool> verifyFile(
      {bool checkSize = true, bool checkHash = false}) async {
    if (filePath == null || filePath!.isEmpty) return false;

    try {
      final file = File(filePath!);
      if (!await file.exists()) return false;

      if (checkSize && fileSize != null) {
        final actualSize = await file.length();
        if (actualSize != fileSize) return false;
      }

      // Hash verification would require crypto package
      // For now, we skip it as it's optional and expensive
      if (checkHash && fileHash != null) {
        // TODO: Implement hash verification if needed
        // final actualHash = await _computeFileHash(file);
        // return actualHash == fileHash;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Check if file path is a temporary path. Separator-agnostic (Windows
  /// paths mix `\` and `/`): a `receiving_*` basename, a `file_recv` segment,
  /// or the POSIX `/tmp` fallback.
  bool get isTempPath {
    if (filePath == null) return false;
    return p.basename(filePath!).startsWith('receiving_') ||
        _hasDirSegment(filePath!, 'file_recv') ||
        filePath!.startsWith('/tmp/');
  }

  /// Check if file path is a final path (not temporary)
  bool get isFinalPath {
    if (filePath == null) return false;
    return !isTempPath &&
        (_hasDirSegment(filePath!, 'avatars') ||
            _hasDirSegment(filePath!, 'Downloads') ||
            _hasDirSegment(filePath!, 'file_recv'));
  }

  static bool _hasDirSegment(String path, String segment) {
    final parts = p.split(path);
    return parts.length > 1 && parts.sublist(0, parts.length - 1).contains(segment);
  }
}
