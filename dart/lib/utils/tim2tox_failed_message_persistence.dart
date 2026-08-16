import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_status.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';

/// Utility class for persisting and restoring failed messages.
/// When [accountToxId] is provided, storage is scoped per account using the
/// full Tox ID (76 chars) as the key suffix.
///
/// H12 fix: previously the suffix was truncated to the first 16 chars of the
/// Tox ID. Two Tox IDs sharing a 16-char prefix would collide and overwrite
/// each other's failed-message queue. The full Tox ID is now used. A one-time
/// migration in the loader (see [_migrateLegacyPrefixKey]) copies any pre-fix
/// 16-char-prefixed entry into the new full-ID key before reading.
class FailedMessageLookupResult {
  const FailedMessageLookupResult({
    required this.conversationKey,
    required this.messageData,
    required this.accountToxId,
  });

  final String conversationKey;
  final Map<String, dynamic> messageData;
  final String? accountToxId;
}

class Tim2ToxFailedMessagePersistence {
  static const String _persistenceKey = 'tencent_cloud_chat_failed_messages';
  static const int _legacyAccountPrefixLen = 16;

  /// Schema version stored alongside each persisted entry.
  /// v1: text/id/msgID/elemType/etc. only.
  /// v2 (P0-12): adds optional media fields (filePath, fileName, fileSize,
  ///             mediaKind, localUrl, customData, soundDuration, videoDuration)
  ///             so file/image/sound/video/custom resends can rebuild the
  ///             original V2TimMessage. Loaders MUST tolerate missing fields
  ///             — v1 entries are still readable.
  static const int _schemaVersion = 2;

  static String _storageKey(String? accountToxId) {
    if (accountToxId == null || accountToxId.isEmpty) return _persistenceKey;
    return '${_persistenceKey}_$accountToxId';
  }

  /// Legacy (pre-H12) storage key — first 16 chars of Tox ID. Returns null
  /// if the account has no legacy key (no accountToxId, or shorter than the
  /// legacy prefix length — those were stored verbatim under the new key).
  static String? _legacyStorageKey(String? accountToxId) {
    if (accountToxId == null || accountToxId.isEmpty) return null;
    if (accountToxId.length < _legacyAccountPrefixLen) return null;
    final prefix = accountToxId.substring(0, _legacyAccountPrefixLen);
    return '${_persistenceKey}_$prefix';
  }

  static bool _matchesMessageID(
    Map<String, dynamic> messageData,
    Set<String> messageIDs,
  ) {
    if (messageIDs.isEmpty) return false;
    final id = messageData['id'] as String?;
    final msgID = messageData['msgID'] as String?;
    return (id != null && messageIDs.contains(id)) ||
        (msgID != null && messageIDs.contains(msgID));
  }

  static Map<String, dynamic>? _decodeStore(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return null;
    final decoded = json.decode(jsonString);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  static List<Map<String, dynamic>> _decodeRows(dynamic rawRows) {
    if (rawRows is! List) {
      throw const FormatException('failed-message conversation is not a list');
    }
    return rawRows.map((rawRow) {
      if (rawRow is! Map) {
        throw const FormatException('failed-message row is not a map');
      }
      return Map<String, dynamic>.from(rawRow);
    }).toList();
  }

  static bool _sameMessage(
    Map<String, dynamic> left,
    Map<String, dynamic> right,
  ) {
    final identifiers = <String>{
      if (left['id'] case final String id when id.isNotEmpty) id,
      if (left['msgID'] case final String msgID when msgID.isNotEmpty) msgID,
    };
    return _matchesMessageID(right, identifiers);
  }

  static Map<String, dynamic> _mergeStores(
    Map<String, dynamic> fullStore,
    Map<String, dynamic> legacyStore,
  ) {
    final merged = Map<String, dynamic>.from(fullStore);
    for (final legacyConversation in legacyStore.entries) {
      final fullRows = merged.containsKey(legacyConversation.key)
          ? _decodeRows(merged[legacyConversation.key])
          : <Map<String, dynamic>>[];
      for (final legacyRow in _decodeRows(legacyConversation.value)) {
        if (!fullRows.any((fullRow) => _sameMessage(fullRow, legacyRow))) {
          fullRows.add(legacyRow);
        }
      }
      merged[legacyConversation.key] = fullRows;
    }
    return merged;
  }

  static FailedMessageLookupResult? _findInStore({
    required Map<String, dynamic>? store,
    required String messageID,
    required String? accountToxId,
  }) {
    if (store == null || store.isEmpty) return null;
    for (final entry in store.entries) {
      final rawList = entry.value;
      if (rawList is! List) continue;
      for (final rawMessage in rawList) {
        if (rawMessage is! Map) continue;
        final messageData = Map<String, dynamic>.from(rawMessage);
        if (!_matchesMessageID(messageData, {messageID})) continue;
        return FailedMessageLookupResult(
          conversationKey: entry.key,
          messageData: messageData,
          accountToxId: accountToxId,
        );
      }
    }
    return null;
  }

  /// Migrate a legacy 16-char-prefixed key to the full-Tox-ID key. Runs on
  /// the first read/write touching a given [accountToxId]. Safe to call
  /// repeatedly: once migrated, the legacy key is gone and this is a no-op.
  static Future<void> _migrateLegacyPrefixKey(
    SharedPreferences prefs,
    String? accountToxId,
  ) async {
    if (accountToxId == null || accountToxId.isEmpty) return;
    final legacyKey = _legacyStorageKey(accountToxId);
    if (legacyKey == null) return;
    final newKey = _storageKey(accountToxId);
    if (legacyKey == newKey) return;
    final legacyValue = prefs.getString(legacyKey);
    if (legacyValue == null) return;
    final legacyStore = _decodeStore(legacyValue);
    if (legacyStore == null) return;
    final fullValue = prefs.getString(newKey);
    final fullStore =
        fullValue == null ? <String, dynamic>{} : _decodeStore(fullValue);
    if (fullStore == null) return;

    final mergedStore = _mergeStores(fullStore, legacyStore);
    final wroteFullStore =
        await prefs.setString(newKey, json.encode(mergedStore));
    if (wroteFullStore) {
      await prefs.remove(legacyKey);
    }
  }

  static const int _messageTimeoutSeconds =
      5; // Default timeout: 5 seconds for text messages
  static const int _fileMessageTimeoutSeconds =
      300; // 5 minutes for file/image/video messages
  static const int _baseFileTimeoutSeconds = 60; // Base timeout: 60 seconds
  static const int _fileSizePerSecondBytes =
      100 * 1024; // Assume 100KB/s upload speed minimum

  /// Save a failed message to local storage.
  /// [accountToxId] optional; when set, storage is scoped to this account.
  static Future<void> saveFailedMessage({
    required V2TimMessage message,
    String? userID,
    String? groupID,
    String? accountToxId,
  }) async {
    try {
      // Create message data to save. v2 schema (P0-12): extra optional
      // fields for media messages so reSendMessage can rebuild a usable
      // V2TimMessage. All new fields are optional and absent on text-only
      // entries (and on legacy v1 entries) — loaders must default to null.
      String? mediaKind;
      String? filePath;
      String? fileName;
      int? fileSize;
      String? localUrl;
      String? customData;
      int? soundDuration;
      int? videoDuration;
      if (message.imageElem != null) {
        mediaKind = 'image';
        filePath = message.imageElem!.path;
        // imageList[].localUrl is the fallback path on the receive side; pick the first non-empty.
        final imgs = message.imageElem!.imageList;
        if (imgs != null) {
          for (final img in imgs) {
            if (img != null &&
                img.localUrl != null &&
                img.localUrl!.isNotEmpty) {
              localUrl = img.localUrl;
              if (img.size != null && img.size! > 0) fileSize = img.size;
              break;
            }
          }
        }
      } else if (message.fileElem != null) {
        mediaKind = 'file';
        filePath = message.fileElem!.path;
        fileName = message.fileElem!.fileName;
        fileSize = message.fileElem!.fileSize;
        localUrl = message.fileElem!.localUrl;
      } else if (message.soundElem != null) {
        mediaKind = 'audio';
        filePath = message.soundElem!.path;
        fileSize = message.soundElem!.dataSize;
        localUrl = message.soundElem!.localUrl;
        soundDuration = message.soundElem!.duration;
      } else if (message.videoElem != null) {
        mediaKind = 'video';
        filePath = message.videoElem!.videoPath;
        fileSize = message.videoElem!.videoSize;
        localUrl = message.videoElem!.localVideoUrl;
        videoDuration = message.videoElem!.duration;
      } else if (message.customElem != null) {
        mediaKind = 'custom';
        customData = message.customElem!.data;
      }

      final messageData = <String, dynamic>{
        'id': message.id,
        'msgID': message.msgID,
        'timestamp': message.timestamp,
        'elemType': message.elemType,
        'text': message.textElem?.text,
        'userID': message.userID,
        'groupID': message.groupID,
        'isSelf': message.isSelf,
        'status': MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'schemaVersion': _schemaVersion,
        if (mediaKind != null) 'mediaKind': mediaKind,
        if (filePath != null) 'filePath': filePath,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
        if (localUrl != null) 'localUrl': localUrl,
        if (customData != null) 'customData': customData,
        if (soundDuration != null) 'soundDuration': soundDuration,
        if (videoDuration != null) 'videoDuration': videoDuration,
      };

      await saveFailedMessageData(
        messageData: messageData,
        userID: userID,
        groupID: groupID,
        accountToxId: accountToxId,
      );
    } catch (e) {
      // Ignore errors during persistence
    }
  }

  /// Persist an already serialized failed-message row.
  ///
  /// This is the storage seam used by [saveFailedMessage] after extracting SDK
  /// model fields. Keeping the SharedPreferences transaction independent of
  /// `V2TimMessage` also lets the standalone package test persistence without
  /// loading an integrator-specific native SDK replacement.
  static Future<void> saveFailedMessageData({
    required Map<String, dynamic> messageData,
    String? userID,
    String? groupID,
    String? accountToxId,
  }) async {
    try {
      final conversationKey = groupID ?? userID ?? '';
      if (conversationKey.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacyPrefixKey(prefs, accountToxId);
      final key = _storageKey(accountToxId);
      final failedMessagesMap =
          _decodeStore(prefs.getString(key)) ?? <String, dynamic>{};
      final rawRows = failedMessagesMap[conversationKey];
      final conversationFailedMessages = rawRows is List
          ? rawRows
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList()
          : <Map<String, dynamic>>[];
      final finalizedData = Map<String, dynamic>.from(messageData);
      final id = finalizedData['id'];
      final msgID = finalizedData['msgID'];
      final existingIndex = conversationFailedMessages.indexWhere(
        (row) => row['id'] == id || row['msgID'] == msgID,
      );

      if (existingIndex >= 0) {
        conversationFailedMessages[existingIndex] = finalizedData;
      } else {
        conversationFailedMessages.add(finalizedData);
      }

      failedMessagesMap[conversationKey] = conversationFailedMessages;
      await prefs.setString(key, json.encode(failedMessagesMap));
    } catch (e) {
      // Ignore errors during persistence.
    }
  }

  /// Remove a message from failed messages (when it's successfully sent or deleted).
  /// [accountToxId] optional; when set, storage is scoped to this account.
  static Future<void> removeFailedMessage({
    required String messageID,
    String? userID,
    String? groupID,
    String? accountToxId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacyPrefixKey(prefs, accountToxId);
      final key = _storageKey(accountToxId);
      final jsonString = prefs.getString(key);
      if (jsonString == null || jsonString.isEmpty) return;

      final failedMessagesMap = json.decode(jsonString) as Map<String, dynamic>;
      final conversationKey = groupID ?? userID ?? '';
      if (conversationKey.isEmpty ||
          !failedMessagesMap.containsKey(conversationKey)) {
        return;
      }

      final conversationFailedMessages = List<Map<String, dynamic>>.from(
          failedMessagesMap[conversationKey] as List);

      conversationFailedMessages
          .removeWhere((m) => m['id'] == messageID || m['msgID'] == messageID);

      if (conversationFailedMessages.isEmpty) {
        failedMessagesMap.remove(conversationKey);
      } else {
        failedMessagesMap[conversationKey] = conversationFailedMessages;
      }

      final updatedJsonString = json.encode(failedMessagesMap);
      await prefs.setString(key, updatedJsonString);
    } catch (e) {
      // Ignore errors
    }
  }

  /// Remove failed rows by message ids when the caller has no conversation
  /// context (for example deleteMessages/revokeMessage only receives msgIDs).
  ///
  /// When [accountToxId] is provided, only that account's failed-message key is
  /// scanned. The method still preserves legacy 16-char-prefix migration by
  /// migrating before the scan.
  /// Returns the NUMBER of failed rows actually removed.
  ///
  /// The count matters because a failed (never-sent) message lives ONLY here —
  /// it is not in `FfiChatService`'s history. `Tim2ToxSdkPlatform.deleteMessages`
  /// adds this count to the history count so its `desc` can distinguish "this
  /// call removed something" from "the messages were already absent"; both are
  /// reported as SUCCESS (delete-for-me is idempotent), so the count is
  /// diagnostic, not a verdict. Never report a removal that did not happen:
  /// callers read the total to log a no-op.
  static Future<int> removeFailedMessagesByIDs({
    required Set<String> messageIDs,
    String? accountToxId,
  }) async {
    if (messageIDs.isEmpty) return 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacyPrefixKey(prefs, accountToxId);
      final key = _storageKey(accountToxId);
      final failedMessagesMap = _decodeStore(prefs.getString(key));
      if (failedMessagesMap == null || failedMessagesMap.isEmpty) return 0;

      var removed = 0;
      for (final entry in failedMessagesMap.entries.toList()) {
        final rawList = entry.value;
        if (rawList is! List) continue;
        final conversationFailedMessages = rawList
            .whereType<Map>()
            .map((raw) => Map<String, dynamic>.from(raw))
            .toList();
        final filtered = conversationFailedMessages
            .where((message) => !_matchesMessageID(message, messageIDs))
            .toList();
        if (filtered.length == conversationFailedMessages.length) continue;
        removed += conversationFailedMessages.length - filtered.length;
        if (filtered.isEmpty) {
          failedMessagesMap.remove(entry.key);
        } else {
          failedMessagesMap[entry.key] = filtered;
        }
      }

      if (removed > 0) {
        await prefs.setString(key, json.encode(failedMessagesMap));
      }
      return removed;
    } catch (e) {
      // Ignore errors.
      return 0;
    }
  }

  /// Find one failed row by either `id` or `msgID` within the scoped account.
  static Future<FailedMessageLookupResult?> findFailedMessageByID({
    required String messageID,
    String? accountToxId,
  }) async {
    if (messageID.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacyPrefixKey(prefs, accountToxId);
      final scoped = _findInStore(
        store: _decodeStore(prefs.getString(_storageKey(accountToxId))),
        messageID: messageID,
        accountToxId: accountToxId,
      );
      if (scoped != null) return scoped;

      // Pre-account-scoping builds stored rows under the unscoped base key.
      // Preserve that compatibility fallback without scanning another
      // account's full-ID key.
      if (accountToxId != null && accountToxId.isNotEmpty) {
        return _findInStore(
          store: _decodeStore(prefs.getString(_persistenceKey)),
          messageID: messageID,
          accountToxId: null,
        );
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Load failed messages for a conversation.
  /// [accountToxId] optional; when set, storage is scoped to this account.
  static Future<List<Map<String, dynamic>>> loadFailedMessages({
    String? userID,
    String? groupID,
    String? accountToxId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacyPrefixKey(prefs, accountToxId);
      final key = _storageKey(accountToxId);
      final jsonString = prefs.getString(key);
      if (jsonString == null || jsonString.isEmpty) return [];

      final failedMessagesMap = json.decode(jsonString) as Map<String, dynamic>;
      final conversationKey = groupID ?? userID ?? '';
      if (conversationKey.isEmpty ||
          !failedMessagesMap.containsKey(conversationKey)) {
        return [];
      }

      // P0-12: schema v1 entries have no `schemaVersion` key and no media
      // fields; v2 entries add them. Both shapes are returned as-is here;
      // callers that need media fields must tolerate them being missing
      // (treat as null). No active migration: the next save will rewrite
      // the entry under the v2 schema.
      return List<Map<String, dynamic>>.from(
          failedMessagesMap[conversationKey] as List);
    } catch (e) {
      return [];
    }
  }

  /// Clear all failed messages (optional cleanup method).
  /// [accountToxId] optional; when set, only clears storage for this account.
  static Future<void> clearAllFailedMessages({String? accountToxId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Clear both the new (full-id) key and any lingering legacy 16-char-prefix
      // key so an account that hasn't been read-migrated yet is still cleared.
      final key = _storageKey(accountToxId);
      await prefs.remove(key);
      final legacyKey = _legacyStorageKey(accountToxId);
      if (legacyKey != null && legacyKey != key) {
        await prefs.remove(legacyKey);
      }
    } catch (e) {
      // Ignore errors
    }
  }

  /// Get timeout duration in seconds for a message
  /// For file/image/video messages, calculates timeout based on file size
  /// For text messages, returns default timeout
  static int getTimeoutSeconds(V2TimMessage? message) {
    if (message == null) {
      return _messageTimeoutSeconds;
    }

    // Check message type
    final elemType = message.elemType;

    // Text messages use short timeout
    if (elemType == MessageElemType.V2TIM_ELEM_TYPE_TEXT) {
      return _messageTimeoutSeconds;
    }

    // File messages (file, image, video, sound) need longer timeout
    int? fileSize;

    if (message.fileElem != null) {
      fileSize = message.fileElem!.fileSize;
    } else if (message.imageElem != null &&
        message.imageElem!.imageList != null &&
        message.imageElem!.imageList!.isNotEmpty) {
      // Use the original image size if available
      final originalImage = message.imageElem!.imageList!.firstWhere(
        (img) => img?.type == 0, // Original image type
        orElse: () => message.imageElem!.imageList!.first,
      );
      fileSize = originalImage?.size;
    } else if (message.videoElem != null) {
      fileSize = message.videoElem!.videoSize;
    } else if (message.soundElem != null) {
      fileSize = message.soundElem!.dataSize;
    }

    // If file size is available, calculate timeout based on size
    // Formula: base timeout + (file size / minimum upload speed)
    if (fileSize != null && fileSize > 0) {
      final sizeBasedTimeout = (fileSize / _fileSizePerSecondBytes).ceil();
      final totalTimeout = _baseFileTimeoutSeconds + sizeBasedTimeout;
      // Cap at maximum timeout
      return totalTimeout > _fileMessageTimeoutSeconds
          ? _fileMessageTimeoutSeconds
          : totalTimeout;
    }

    // For file messages without size info, use base file timeout
    return _baseFileTimeoutSeconds;
  }

  /// Get default timeout duration in seconds (for text messages)
  static int get timeoutSeconds => _messageTimeoutSeconds;
}
