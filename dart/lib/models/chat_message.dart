import 'dart:io';

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

  /// Check if file path is a temporary path
  bool get isTempPath {
    if (filePath == null) return false;
    return filePath!.startsWith('/tmp/receiving_') ||
        filePath!.contains('/file_recv/') ||
        filePath!.startsWith('/tmp/');
  }

  /// Check if file path is a final path (not temporary)
  bool get isFinalPath {
    if (filePath == null) return false;
    return !isTempPath &&
        (filePath!.contains('/avatars/') ||
            filePath!.contains('/Downloads/') ||
            filePath!.contains('/file_recv/'));
  }
}
