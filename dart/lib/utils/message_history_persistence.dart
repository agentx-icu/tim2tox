/// Unified message history persistence service
/// 
/// This service provides a unified interface for persisting message history
/// that can be used by both Platform interface scheme and binary replacement scheme.
/// 
/// Storage location: `<appDir>/chat_history/<conversationId>.json`
/// Data format: JSON with conversationId and messages array
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../interfaces/logger_service.dart';
import '../models/chat_message.dart';
import 'conversation_id_utils.dart';

/// Message history persistence service
///
/// Provides unified message history persistence for both Platform and binary replacement schemes.
/// When [historyDirectory] is set (e.g. per-account path from app), uses that directory; otherwise
/// uses app support dir with optional instanceId for multi-instance.
///
/// NOTE (M3): Messages are persisted as plaintext JSON. At-rest encryption
/// (e.g. AES-GCM keyed off the Tox profile password or OS keychain/keystore)
/// is a known gap and tracked separately. Do not add new sensitive fields
/// here without revisiting that limitation.
class MessageHistoryPersistence {
  final int? _instanceId;
  final String? _historyDirectory;
  final LoggerService? _logger;

  MessageHistoryPersistence({
    int? instanceId,
    String? historyDirectory,
    LoggerService? logger,
  })  : _instanceId = instanceId,
        _historyDirectory = historyDirectory,
        _logger = logger {
    // X11 from `local-storage-review-2026-05-18.md`:
    // when no explicit per-account [historyDirectory] is injected we fall
    // back to a single shared `<AppSupport>/chat_history` (or
    // instance-scoped) directory. With more than one account on the device
    // that silently merges histories — conversation files key on peer
    // pubkey only, so messages from two different accounts to the same
    // peer collide. Surface the issue at construction time so integrators
    // notice early; do NOT change the default behaviour (that would
    // require coordinated changes in every caller and would regress
    // existing tests that rely on the shared default).
    if (historyDirectory == null || historyDirectory.isEmpty) {
      const warning =
          '[MessageHistoryPersistence] no historyDirectory injected — '
          'falling back to shared <AppSupport>/chat_history. '
          'For multi-account isolation, callers should inject a '
          'per-account historyDirectory (e.g. AppPaths.getAccountChatHistoryPath(toxId)).';
      final logger = _logger;
      if (logger != null) {
        logger.logWarning(warning);
      } else {
        // No logger available — last resort so the warning still surfaces
        // in dev consoles and test output without requiring the caller to
        // wire one up.
        // ignore: avoid_print
        stderr.writeln(warning);
      }
    }
  }

  // In-memory cache: conversationId -> List<ChatMessage>
  final Map<String, List<ChatMessage>> _historyById = {};

  // In-memory cache: conversationId -> lastViewTimestamp (milliseconds since epoch)
  final Map<String, int> _lastViewTimestampById = {};

  // Maximum number of messages to keep in memory per conversation
  static const int _maxMessagesInMemory = 1000;

  // Concurrency control: per-conversation serial write fence.
  // Each saveHistory chains synchronously onto the previous future before any
  // await — this guarantees strict serialization even when many callers race
  // (the old `while (_writeLocks[id] != null) await ...` pattern let multiple
  // waiters resume on the same microtask tick and bypass the gate).
  final Map<String, Future<void>> _writeFences = {};

  /// P2 debounce state (see `local-storage-review-2026-05-18.md`).
  ///
  /// `appendHistory` used to call `saveHistory` on every single message,
  /// which re-serialized the entire in-memory list to disk per send. Hot
  /// senders (paste, image batch, rapid replies) produced O(messages²) write
  /// volume.
  ///
  /// We now coalesce successive appends to the same conversation into a
  /// single disk write 200ms after the last append. The returned Future from
  /// `appendHistory` still completes when the debounced save lands, so
  /// callers that await it (e.g. `BinaryReplacementHistoryHook.saveMessage`)
  /// still see write failures.
  static const Duration _appendDebounce = Duration(milliseconds: 200);
  final Map<String, Timer> _appendDebounceTimers = {};
  final Map<String, Completer<void>> _appendDebouncePending = {};

  // M1: conversations that need a post-load normalization save. Collected by
  // [loadHistory] and drained serially by [flushDirtyAfterLoad] from the end
  // of [loadAllHistories], so cold start doesn't fan out N parallel saves.
  final Set<String> _dirtyAfterLoad = {};

  bool _disposed = false;

  /// Get the directory for storing message history.
  /// When _historyDirectory is set, uses it (per-account); otherwise uses appDir + instance suffix.
  Future<Directory> _getHistoryDirectory() async {
    if (_historyDirectory != null && _historyDirectory!.isNotEmpty) {
      final historyDir = Directory(_historyDirectory!);
      if (!await historyDir.exists()) {
        await historyDir.create(recursive: true);
      }
      return historyDir;
    }
    final appDir = await getApplicationSupportDirectory();
    final historyDir = Directory(
      _instanceId != null && _instanceId != 0
          ? '${appDir.path}/chat_history_instance_$_instanceId'
          : '${appDir.path}/chat_history',
    );
    if (!await historyDir.exists()) {
      await historyDir.create(recursive: true);
    }
    return historyDir;
  }
  
  /// Get the file path for a conversation's history
  /// 
  /// Uses ConversationIdUtils to normalize and sanitize the ID for consistent file naming.
  Future<File> _getHistoryFile(String id) async {
    final dir = await _getHistoryDirectory();
    // Normalize and sanitize id for filename
    final normalizedId = ConversationIdUtils.normalize(id);
    final safeId = ConversationIdUtils.sanitizeForFilename(normalizedId);
    final filePath = '${dir.path}/$safeId.json';
    return File(filePath);
  }
  
  /// Get backup file path for a conversation's history
  Future<File> _getBackupFile(String id) async {
    final file = await _getHistoryFile(id);
    return File('${file.path}.bak');
  }
  
  /// Cached per-process storage-root lookup so we don't hit
  /// path_provider on every load/save.
  ({String? appSupport, String? documents, String? userDownloads})?
      _storageRootsCache;

  /// P1-15 helper. Resolves and caches the storage roots we relativize
  /// against:
  ///   - AppSupport (where file_recv lives)
  ///   - Documents (where Downloads lives on some desktop platforms)
  ///   - userDownloads (R-5: the OS-level user Downloads dir, e.g. ~/Downloads
  ///     on macOS — this is *not* under Documents).
  /// Returns null parts when the platform does not expose the corresponding
  /// directory.
  Future<({String? appSupport, String? documents, String? userDownloads})>
      _resolveStorageRoots() async {
    if (_storageRootsCache != null) return _storageRootsCache!;
    String? appSupport;
    String? documents;
    String? userDownloads;
    try {
      final dir = await getApplicationSupportDirectory();
      appSupport = dir.path;
    } catch (_) {
      // Some platforms (tests) may not have AppSupport.
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      documents = dir.path;
    } catch (_) {
      // Best-effort.
    }
    try {
      // R-5: macOS' ~/Downloads (and the analogous user-level Downloads
      // dir on other platforms) is the real default landing spot for
      // received files but lives outside the Documents tree, so the old
      // {{downloads}} placeholder only matched a niche `documents/Downloads/`
      // subdir. Add a dedicated placeholder so cross-device / reinstall
      // history continues to resolve.
      final dir = await getDownloadsDirectory();
      if (dir != null) {
        userDownloads = dir.path;
      }
    } catch (_) {
      // Best-effort; getDownloadsDirectory is not implemented everywhere.
    }
    final roots = (
      appSupport: appSupport,
      documents: documents,
      userDownloads: userDownloads,
    );
    _storageRootsCache = roots;
    return roots;
  }

  /// P1-15: rewrite an absolute path under a well-known root to a
  /// placeholder token. Unknown paths are returned unchanged so legacy
  /// rows continue to round-trip.
  String _relativizePath(
      String absolutePath,
      ({String? appSupport, String? documents, String? userDownloads}) roots) {
    final appSupport = roots.appSupport;
    final documents = roots.documents;
    final userDownloads = roots.userDownloads;
    if (appSupport != null && absolutePath.startsWith('$appSupport/file_recv/')) {
      final tail = absolutePath.substring('$appSupport/file_recv/'.length);
      return '{{fileRecv}}/$tail';
    }
    if (appSupport != null && absolutePath.startsWith('$appSupport/avatars/')) {
      final tail = absolutePath.substring('$appSupport/avatars/'.length);
      return '{{avatars}}/$tail';
    }
    // R-5: keep the precise `documents/Downloads/` match BEFORE the
    // broader userDownloads check. On platforms where the user-level
    // Downloads dir happens to coincide with documents/Downloads/, we'd
    // otherwise emit the same path under two different placeholders.
    if (documents != null && absolutePath.startsWith('$documents/Downloads/')) {
      final tail = absolutePath.substring('$documents/Downloads/'.length);
      return '{{downloads}}/$tail';
    }
    if (userDownloads != null && absolutePath.startsWith('$userDownloads/')) {
      final tail = absolutePath.substring('$userDownloads/'.length);
      return '{{userDownloads}}/$tail';
    }
    return absolutePath;
  }

  /// P1-15: inverse of [_relativizePath]. Placeholder tokens are
  /// substituted with the current device's storage roots; absolute paths
  /// (legacy v1 entries) are returned unchanged.
  String _resolvePath(
      String storedPath,
      ({String? appSupport, String? documents, String? userDownloads}) roots) {
    final appSupport = roots.appSupport;
    final documents = roots.documents;
    final userDownloads = roots.userDownloads;
    if (storedPath.startsWith('{{fileRecv}}/') && appSupport != null) {
      return '$appSupport/file_recv/${storedPath.substring('{{fileRecv}}/'.length)}';
    }
    if (storedPath.startsWith('{{avatars}}/') && appSupport != null) {
      return '$appSupport/avatars/${storedPath.substring('{{avatars}}/'.length)}';
    }
    if (storedPath.startsWith('{{downloads}}/') && documents != null) {
      return '$documents/Downloads/${storedPath.substring('{{downloads}}/'.length)}';
    }
    // R-5: rehydrate the new userDownloads placeholder. Schema version
    // stays at 2 — older v2 files simply don't contain the token, and
    // unknown placeholders fall through to the unchanged-string return.
    if (storedPath.startsWith('{{userDownloads}}/') && userDownloads != null) {
      return '$userDownloads/${storedPath.substring('{{userDownloads}}/'.length)}';
    }
    return storedPath;
  }

  /// Get temporary file path for atomic writes
  Future<File> _getTempFile(String id) async {
    final file = await _getHistoryFile(id);
    return File('${file.path}.tmp');
  }
  
  /// Save message history for a conversation
  /// 
  /// Thread-safe implementation with:
  /// - Write locks to prevent race conditions
  /// - Temporary file + atomic rename for data integrity
  /// - Backup mechanism for crash recovery
  /// 
  /// [conversationId] - Normalized conversation ID
  /// [messages] - List of messages to save
  Future<void> saveHistory(String conversationId, List<ChatMessage> messages) async {
    if (messages.isEmpty) return;

    // Normalize conversation ID for consistent storage
    final normalizedId = ConversationIdUtils.normalize(conversationId);

    // C1: chain onto the previous write for this conversation BEFORE any
    // await, so concurrent callers serialize deterministically. The old
    // `while (_writeLocks[id] != null) await ...future` pattern let multiple
    // waiters resume on the same microtask tick and all pass the gate.
    final prev = _writeFences[normalizedId] ?? Future<void>.value();
    final completer = Completer<void>();
    _writeFences[normalizedId] = completer.future;
    try {
      try {
        await prev;
      } catch (_) {
        // A previous write's error must not poison this writer.
      }

      final file = await _getHistoryFile(normalizedId);
      final backupFile = await _getBackupFile(normalizedId);
      final tempFile = await _getTempFile(normalizedId);

      // Create backup of existing file if it exists
      if (await file.exists()) {
        try {
          await file.copy(backupFile.path);
        } catch (e) {
          // Backup failed, but continue with save
        }
      }

      // Prepare data.
      //
      // P1-15: rewrite absolute filePaths under the well-known media-storage
      // roots into placeholders so a profile that moves between devices (or
      // re-installs that change the AppSupport path) doesn't end up with
      // dangling paths in its history. Unknown / outside-root paths are
      // left as-is to keep the change strictly additive.
      final storageRoots = await _resolveStorageRoots();
      final jsonList = messages.map((msg) {
        final m = msg.toJson();
        final fp = m['filePath'];
        if (fp is String && fp.isNotEmpty) {
          m['filePath'] = _relativizePath(fp, storageRoots);
        }
        return m;
      }).toList();
      final data = {
        'conversationId': normalizedId,
        // P1-15: bump format to 2 to signal that filePath may contain
        // placeholder tokens. v1 readers will treat them as opaque strings;
        // v2 readers rehydrate via [_resolvePath].
        'version': 2,
        'lastViewTimestamp': _lastViewTimestampById[normalizedId] ?? 0,
        'messages': jsonList,
      };
      final jsonString = jsonEncode(data);

      // C2: write→fsync→close→rename for crash durability. Tox is P2P, no
      // server can backfill, so a half-flushed page-cache buffer at the
      // moment of a kernel/process crash means permanent data loss.
      final raf = await tempFile.open(mode: FileMode.write);
      try {
        await raf.writeString(jsonString);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await tempFile.rename(file.path);

      // X10: delete the backup we just used as a safety net.
      try {
        if (await backupFile.exists()) {
          await backupFile.delete();
        }
      } catch (_) {
        // Best-effort cleanup; leave the stale .bak for the 7-day sweep.
      }

      completer.complete();
    } catch (e) {
      completer.completeError(e);
    } finally {
      // Slot cleanup gated on identity so a newer writer's slot is never evicted.
      if (identical(_writeFences[normalizedId], completer.future)) {
        // Discarded — the removed future is `completer.future`, which has
        // already been settled above; `remove` returns it just for chaining.
        _writeFences.remove(normalizedId); // ignore: unawaited_futures
      }
    }
  }
  
  /// Load message history for a conversation
  /// 
  /// Returns the loaded messages and updates the in-memory cache.
  /// Marks all pending messages as not pending (failed) to prevent resending on startup.
  /// 
  /// Includes file integrity checks and backup recovery.
  /// 
  /// [id] - Conversation ID (will be normalized)
  /// [quitGroups] - Set of quit group IDs to filter out
  Future<List<ChatMessage>> loadHistory(String id, {Set<String>? quitGroups}) async {
    // Normalize conversation ID
    final normalizedId = ConversationIdUtils.normalize(id);
    
    try {
      final file = await _getHistoryFile(normalizedId);
      if (!await file.exists()) {
        // Try to load from backup
        return await _loadFromBackup(normalizedId, quitGroups: quitGroups);
      }
      
      // Check file size (empty or corrupted file)
      final fileSize = await file.length();
      if (fileSize == 0) {
        return await _loadFromBackup(normalizedId, quitGroups: quitGroups);
      }
      
      String jsonString;
      try {
        jsonString = await file.readAsString();
      } catch (e) {
        // File read failed, try backup
        return await _loadFromBackup(normalizedId, quitGroups: quitGroups);
      }
      
      dynamic decoded;
      try {
        decoded = jsonDecode(jsonString);
      } catch (e) {
        // JSON parse failed, try to recover from backup
        return await _recoverCorruptedFile(file, normalizedId, quitGroups: quitGroups);
      }
      
      List<ChatMessage> messages;
      String? actualId;
      
      // P1-15: resolve storage roots once per load so we can rehydrate
      // placeholder filePaths into absolute device paths.
      final storageRoots = await _resolveStorageRoots();

      if (decoded is Map<String, dynamic>) {
        // New format with metadata
        actualId = decoded['conversationId'] as String?;
        // Load lastViewTimestamp if available (default to 0 if not present)
        final lastViewTimestamp = decoded['lastViewTimestamp'] as int? ?? 0;
        final jsonList = decoded['messages'] as List<dynamic>;
        messages = jsonList.map((json) {
          final m = json as Map<String, dynamic>;
          final fp = m['filePath'];
          if (fp is String && fp.isNotEmpty) {
            m['filePath'] = _resolvePath(fp, storageRoots);
          }
          return ChatMessage.fromJson(m);
        }).toList();
        // Store lastViewTimestamp in memory cache
        final targetIdForTimestamp = actualId ?? id;
        _lastViewTimestampById[targetIdForTimestamp] = lastViewTimestamp;
      } else if (decoded is List<dynamic>) {
        // Old format (backward compatibility)
        messages = decoded.map((json) {
          final m = json as Map<String, dynamic>;
          final fp = m['filePath'];
          if (fp is String && fp.isNotEmpty) {
            m['filePath'] = _resolvePath(fp, storageRoots);
          }
          return ChatMessage.fromJson(m);
        }).toList();
        // Try to infer ID from messages
        if (messages.isNotEmpty) {
          final firstMsg = messages.first;
          actualId = firstMsg.groupId ?? id; // Use groupId if available, otherwise use provided id
        } else {
          actualId = id;
        }
      } else {
        return [];
      }
      
      // Normalize the actual ID from file
      final targetId = actualId != null ? ConversationIdUtils.normalize(actualId) : normalizedId;
      
      // Check if this is a quit group (if quitGroups is provided)
      if (quitGroups != null && messages.isNotEmpty) {
        final firstMsg = messages.first;
        final isGroupConversation = firstMsg.groupId != null && firstMsg.groupId!.isNotEmpty;
        if (isGroupConversation) {
          final groupId = firstMsg.groupId!;
          if (quitGroups.contains(groupId)) {
            // This group was quit, don't load its history
            // Also clean up the history file
            try {
              await file.delete();
            } catch (e) {
              // Ignore deletion errors
            }
            return [];
          }
        }
      }
      
      // Mark all historical messages as not pending (they're from previous sessions)
      // This prevents old pending messages from being resent on startup
      final updatedMessages = messages.map((msg) {
        if (msg.isPending) {
          // Mark as not pending (failed to send in a previous session) while
          // preserving EVERY other field. copyWith (not a hand-listed
          // ChatMessage(...)) keeps cloudCustomData (S17/S18 reply/forward
          // quote) and altMsgIds (cross-path aliases) — a manual reconstruction
          // silently dropped both, so a quoted reply lost its messageReply
          // metadata across an app restart.
          return msg.copyWith(isPending: false);
        }
        return msg;
      }).toList();
      
      // CRITICAL: Remove duplicate messages by msgID
      // If multiple messages have the same msgID, keep the one with:
      // 1. Non-temp filePath (final path) if available
      // 2. Most recent timestamp
      // This prevents duplicate messages when the same message is saved multiple times (e.g., file_request and file_done)
      final Map<String, ChatMessage> deduplicatedMessages = {};
      for (final msg in updatedMessages) {
        if (msg.msgID != null) {
          final existing = deduplicatedMessages[msg.msgID];
          if (existing == null) {
            // First occurrence, add it
            deduplicatedMessages[msg.msgID!] = msg;
          } else {
            // Duplicate found, keep the better version
            // Prefer message with non-temp filePath (final path) over temp path
            // Use the new isTempPath property for better detection
            final existingIsTemp = existing.isTempPath;
            final msgIsTemp = msg.isTempPath;
            
            if (msgIsTemp && !existingIsTemp) {
              // Existing has final path, keep it
              continue;
            } else if (!msgIsTemp && existingIsTemp) {
              // New message has final path, replace existing
              deduplicatedMessages[msg.msgID!] = msg;
            } else {
              // Both have same type of path, keep the one with more recent timestamp
              if (msg.timestamp.isAfter(existing.timestamp)) {
                deduplicatedMessages[msg.msgID!] = msg;
              }
            }
          }
        } else {
          // Message without msgID, add it (shouldn't happen, but handle gracefully)
          deduplicatedMessages['${msg.timestamp.millisecondsSinceEpoch}_${msg.fromUserId}'] = msg;
        }
      }
      
      // Convert back to list and sort by timestamp
      final deduplicatedList = deduplicatedMessages.values.toList();
      deduplicatedList.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      
      // Update in-memory cache
      _historyById[targetId] = deduplicatedList;

      // If lastViewTimestamp was not loaded from file, initialize it to 0
      if (!_lastViewTimestampById.containsKey(targetId)) {
        _lastViewTimestampById[targetId] = 0;
      }

      // Reconcile the persisted read state with the view barrier: a non-self
      // message at or before the last-viewed timestamp was seen, so mark it
      // read even if its stored isRead flag predates read-state tracking. This
      // makes isRead the authoritative unread signal in [getUnreadCount], so a
      // later message that arrives with a timestamp <= the barrier (clock skew
      // or same-millisecond) is still counted instead of being silently
      // suppressed by a strict `ts > lastView` comparison. In-memory only —
      // not persisted here, so it re-applies cheaply on each load.
      final barrierForReconcile = _lastViewTimestampById[targetId] ?? 0;
      if (barrierForReconcile > 0) {
        for (int i = 0; i < deduplicatedList.length; i++) {
          final m = deduplicatedList[i];
          if (!m.isSelf &&
              !m.isRead &&
              m.timestamp.millisecondsSinceEpoch <= barrierForReconcile) {
            deduplicatedList[i] = m.copyWith(isRead: true);
          }
        }
      }
      
      // Save the updated history (with isPending=false and deduplicated) to disk if any changes were made.
      // The save is fire-and-forget so a slow disk write doesn't block load,
      // but we wrap with catchError so a serialization or I/O failure surfaces
      // through the injected logger instead of bubbling out as an uncaught
      // async error on cold start. The cold-start parallel batch can launch
      // many of these concurrently — without this, any one disk-write failure
      // would crash the zone.
      // M1: instead of fire-and-forget `unawaited(saveHistory(...))` on every
      // load-time normalization, mark this conversation dirty and let
      // `loadAllHistories` flush them serially after the batch completes.
      // The old behaviour spawned 16+ concurrent saveHistory futures from
      // each cold-start batch, all racing on the per-conversation fence.
      if (deduplicatedList.length != messages.length || updatedMessages != messages) {
        _dirtyAfterLoad.add(targetId);
      }
      
      return deduplicatedList;
    } catch (e) {
      // Try to load from backup on any error
      return await _loadFromBackup(normalizedId, quitGroups: quitGroups);
    }
  }
  
  /// Load history from backup file
  Future<List<ChatMessage>> _loadFromBackup(String normalizedId, {Set<String>? quitGroups}) async {
    try {
      final backupFile = await _getBackupFile(normalizedId);
      if (!await backupFile.exists()) {
        return [];
      }
      
      final jsonString = await backupFile.readAsString();
      final decoded = jsonDecode(jsonString);
      
      // Use the same loading logic as loadHistory
      // This is a simplified version - in production, consider refactoring
      if (decoded is Map<String, dynamic>) {
        final jsonList = decoded['messages'] as List<dynamic>?;
        if (jsonList == null) return [];

        // P1-15: rehydrate placeholder filePaths in the backup too.
        final storageRoots = await _resolveStorageRoots();
        final messages = jsonList.map((json) {
          final m = json as Map<String, dynamic>;
          final fp = m['filePath'];
          if (fp is String && fp.isNotEmpty) {
            m['filePath'] = _resolvePath(fp, storageRoots);
          }
          return ChatMessage.fromJson(m);
        }).toList();
        
        // Check quit groups
        if (quitGroups != null && messages.isNotEmpty) {
          final firstMsg = messages.first;
          if (firstMsg.groupId != null && quitGroups.contains(firstMsg.groupId)) {
            return [];
          }
        }
        
        return messages;
      }
      
      return [];
    } catch (e) {
      return [];
    }
  }
  
  /// Recover from corrupted file
  Future<List<ChatMessage>> _recoverCorruptedFile(File corruptedFile, String normalizedId, {Set<String>? quitGroups}) async {
    // Try backup first
    final backupMessages = await _loadFromBackup(normalizedId, quitGroups: quitGroups);
    if (backupMessages.isNotEmpty) {
      // M2: restore via read→tmp+fsync→rename, not `backup.copy(primary)`.
      // A direct copy is not crash-safe — if killed mid-copy the primary is
      // now partially written *and* the backup is untouched (but soon
      // overwritten by the next save), leaving both files unusable.
      try {
        final backupFile = await _getBackupFile(normalizedId);
        if (await backupFile.exists()) {
          final backupContent = await backupFile.readAsString();
          final tempFile = await _getTempFile(normalizedId);
          final raf = await tempFile.open(mode: FileMode.write);
          try {
            await raf.writeString(backupContent);
            await raf.flush();
          } finally {
            await raf.close();
          }
          await tempFile.rename(corruptedFile.path);
        }
      } catch (e) {
        // Restore failed, but we have messages in memory
      }
      return backupMessages;
    }

    // Try partial recovery (read valid JSON parts)
    // For now, return empty list - can be enhanced later
    return [];
  }
  
  /// Load all message histories from disk.
  ///
  /// Scans the chat_history directory and loads all conversation histories.
  /// Returns a map of conversationId -> messages.
  ///
  /// Performance (P4 in `local-storage-review-2026-05-18.md`): files are loaded
  /// in parallel batches via `Future.wait` to overlap disk I/O. The batch size
  /// is bounded so we don't open hundreds of file handles on cold start (e.g.
  /// 500-conversation install). Per-file errors are swallowed so a single bad
  /// file can't block the rest of the boot — same semantics as the previous
  /// sequential loop, just concurrent within each batch.
  Future<Map<String, List<ChatMessage>>> loadAllHistories({Set<String>? quitGroups}) async {
    final result = <String, List<ChatMessage>>{};

    try {
      final dir = await _getHistoryDirectory();
      if (!await dir.exists()) {
        return result;
      }

      final entries = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList(growable: false);

      // Bounded parallelism: open at most `batchSize` files concurrently to
      // avoid file-descriptor exhaustion on installs with many conversations.
      const int batchSize = 16;
      for (var start = 0; start < entries.length; start += batchSize) {
        final end = (start + batchSize) > entries.length
            ? entries.length
            : (start + batchSize);
        final batch = entries.sublist(start, end);

        final loaded = await Future.wait(
          batch.map((file) => _loadOneForLoadAll(file, quitGroups: quitGroups)),
        );

        for (final entry in loaded) {
          if (entry == null) continue;
          result[entry.key] = entry.value;
        }
      }
    } catch (e) {
      // Return whatever we've loaded so far
    }

    // M1: drain post-load normalization writes serially so we don't fan out
    // hundreds of concurrent fence-contending saves on cold start.
    await flushDirtyAfterLoad();

    return result;
  }

  /// Flush the post-load dirty set (see [_dirtyAfterLoad]) — serial writes so
  /// the per-conversation write fence doesn't end up with a tall waiter chain
  /// on first boot. Errors are routed through the injected logger and do not
  /// abort the remaining flushes.
  Future<void> flushDirtyAfterLoad() async {
    if (_dirtyAfterLoad.isEmpty) return;
    final ids = List<String>.from(_dirtyAfterLoad);
    _dirtyAfterLoad.clear();
    for (final id in ids) {
      final list = _historyById[id];
      if (list == null) continue;
      try {
        await saveHistory(id, List<ChatMessage>.from(list));
      } catch (e, st) {
        _logger?.logError(
          '[MessageHistoryPersistence] post-load save failed for $id',
          e,
          st,
        );
      }
    }
  }

  /// Helper for [loadAllHistories]: load a single conversation file and return
  /// its (conversationKey, messages) entry, or null if it produced no messages
  /// or failed. Errors are swallowed to preserve the previous "skip bad files"
  /// behaviour of the sequential implementation.
  Future<MapEntry<String, List<ChatMessage>>?> _loadOneForLoadAll(
    File file, {
    Set<String>? quitGroups,
  }) async {
    try {
      final filename = file.path.split(Platform.pathSeparator).last;
      // On POSIX the previous code split on '/'; preserve that fallback for
      // paths that may use forward slashes regardless of platform separator.
      final canonicalFilename = filename.contains('/')
          ? filename.split('/').last
          : filename;
      final sanitizedId = canonicalFilename.replaceAll('.json', '');

      final messages = await loadHistory(sanitizedId, quitGroups: quitGroups);
      if (messages.isEmpty) return null;

      // Key on the (normalized) filename: see the long-form comment in the
      // previous implementation about why firstMsg.fromUserId is the wrong
      // key for C2C conversations the user has sent into.
      final conversationKey = ConversationIdUtils.normalize(sanitizedId);
      return MapEntry(conversationKey, messages);
    } catch (_) {
      return null;
    }
  }
  
  /// Append a message to the history for a conversation.
  ///
  /// Updates the in-memory cache synchronously and returns a Future that
  /// completes when the on-disk save has finished (or errored). Callers that
  /// want to detect disk failures should `await` the result; callers that are
  /// happy with fire-and-forget should wrap with `unawaited(...)`.
  ///
  /// Limits memory usage by keeping only the most recent _maxMessagesInMemory
  /// messages in memory; the full history is always persisted to disk before
  /// truncating, so no messages are lost.
  ///
  /// Deduplication, in priority order:
  ///   1. msgID match → merge via [_mergeMessages] (handles file_request /
  ///      file_done multi-event sequences for the same message).
  ///   2. Content fallback, INCOMING messages only (`!isSelf`), when the msgID
  ///      matched nothing → match on (fromUserId, text, timestamp within 2s).
  ///      This collapses the inbound hybrid double-delivery (same received
  ///      message via both paths with different ids). It is deliberately NOT
  ///      applied to self-sends: those never double-deliver, so collapsing
  ///      them would silently drop a legitimate repeated message ("Bug F").
  ///      See the inline comment at the fallback for the full rationale.
  ///
  /// [conversationId] - Will be normalized before use.
  Future<void> appendHistory(String conversationId, ChatMessage message) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById.putIfAbsent(normalizedId, () => <ChatMessage>[]);

    if (message.msgID != null) {
      // Match on the primary id OR an absorbed cross-path alias, so a
      // re-delivery carrying a previously-dropped id merges into the row that
      // absorbed it instead of appending a third copy.
      final existingIndex =
          list.indexWhere((msg) => _idMatches(msg, message.msgID!));
      if (existingIndex >= 0) {
        final existing = list[existingIndex];
        list[existingIndex] = _mergeMessages(existing, message);
        // Merge of an existing message: in-memory state is already consistent.
        // Schedule a debounced save instead of writing immediately so a burst
        // of file_request / file_done updates for the same msgID coalesces.
        return _scheduleDebouncedSave(normalizedId);
      }
      // Fall through to the content-based dedup below — do NOT return here.
      // A non-null msgID that matched nothing is NOT proof the message is new:
      // toxee's hybrid runtime delivers the SAME inbound message through BOTH
      // paths with DIFFERENT ids (binary-replacement V2TimAdvancedMsgListener
      // `msg_<n>_<nanos>_<seq>` vs FfiChatService poll `<millis>_<n>_<toxId>`).
      // The two ids never match, so an early `list.add` here persists the echo
      // twice. _mergeMessages preserves the dropped id in altMsgIds so it stays
      // resolvable. Mirrors BinaryReplacementHistoryHook's "msgID OR content".
    }

    // Content-based dedup fallback. Runs when the message has no msgID OR has
    // an msgID that matched nothing above (the cross-path duplicate case).
    // Same heuristic as the binary-replacement hook: (text, fromUserId) within
    // a 2s window.
    //
    // INCOMING ONLY (`!message.isSelf`). The reason this fallback exists is the
    // INBOUND hybrid double-delivery: the same received message arrives via
    // both the binary-replacement path (`msg_<n>_<nanos>_<seq>`) and the poll
    // path (`<millis>_<n>_<toxId>`) with different ids ms apart, and only
    // content can collapse them. Outbound (self) messages do NOT double-deliver
    // — Tox does not loop a sender's own message back, so the hook never writes
    // self-sends; `FfiChatService.sendText` appends each self row exactly once
    // with a unique sequenced msgID, and the offline pending→delivered drain
    // reconciles in place by reusing the pending row's msgID (it does not
    // re-append). Running content-dedup on self-sends was therefore over-reach:
    // it silently DROPPED a legitimate second identical self message sent
    // inside 2s (e.g. double-tap send, or "ok" then "ok") — "Bug F". Gating on
    // `!message.isSelf` fixes that while leaving the inbound merge (the only
    // case that needs it) untouched. The drain crash-recovery fallback that
    // *does* re-append a self row does its own content existence check
    // (`_drainTextItem`), so it no longer relies on this branch.
    if (message.text.isNotEmpty && !message.isSelf) {
      const dedupWindow = Duration(seconds: 2);
      final contentMatch = list.indexWhere((msg) =>
          msg.text == message.text &&
          msg.fromUserId == message.fromUserId &&
          !msg.isSelf &&
          msg.timestamp.difference(message.timestamp).abs() <= dedupWindow);
      if (contentMatch >= 0) {
        list[contentMatch] = _mergeMessages(list[contentMatch], message);
        return _scheduleDebouncedSave(normalizedId);
      }
    }

    list.add(message);

    // P2: keep memory trim immediate but debounce the disk write. The "save
    // FULL list before truncating" invariant from the previous implementation
    // is preserved because the snapshot the debounced save reads is taken
    // AFTER truncation — which means we need to write the pre-truncation
    // list synchronously enough to not lose data. We retain the original
    // synchronous-save behaviour on truncation specifically: the truncation
    // boundary is rare (every 1000 messages per conversation) and getting
    // it wrong silently drops history.
    if (list.length > _maxMessagesInMemory) {
      final fullList = List<ChatMessage>.from(list);
      final saveFuture = saveHistory(normalizedId, fullList);
      list.removeRange(0, list.length - _maxMessagesInMemory);
      // Make sure any pending debounced save is cancelled — we just wrote
      // the up-to-date state synchronously.
      _appendDebounceTimers.remove(normalizedId)?.cancel();
      final pending = _appendDebouncePending.remove(normalizedId);
      if (pending != null && !pending.isCompleted) {
        // Forward result with an explicit (error, stack) signature so the
        // 2-arg `onError` form is picked. Using `pending.completeError` as a
        // tear-off would silently drop the stack trace (Dart resolves the
        // 1-arg variant), making disk-write failures unhelpful to debug.
        saveFuture.then(
          (_) {
            if (!pending.isCompleted) pending.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!pending.isCompleted) pending.completeError(error, stack);
          },
        );
      }
      return saveFuture;
    }
    return _scheduleDebouncedSave(normalizedId);
  }

  /// Schedule a coalesced disk write for [normalizedId]. Successive calls
  /// inside [_appendDebounce] reset the timer and share the same returned
  /// Future, which completes when the eventual `saveHistory` finishes.
  ///
  /// Callers should pass an already-normalized id.
  Future<void> _scheduleDebouncedSave(String normalizedId) {
    if (_disposed) {
      // Fall back to synchronous save during shutdown so we don't drop the
      // very last message under a not-yet-fired timer.
      final list = _historyById[normalizedId];
      if (list == null || list.isEmpty) return Future.value();
      return saveHistory(normalizedId, List<ChatMessage>.from(list));
    }
    final completer = _appendDebouncePending.putIfAbsent(
      normalizedId,
      () => Completer<void>(),
    );
    _appendDebounceTimers.remove(normalizedId)?.cancel();
    _appendDebounceTimers[normalizedId] = Timer(_appendDebounce, () {
      _appendDebounceTimers.remove(normalizedId);
      final pending = _appendDebouncePending.remove(normalizedId);
      final list = _historyById[normalizedId];
      if (list == null || list.isEmpty) {
        pending?.complete();
        return;
      }
      final snapshot = List<ChatMessage>.from(list);
      saveHistory(normalizedId, snapshot).then(
        (_) => pending?.complete(),
        onError: (Object error, StackTrace? stack) {
          if (pending != null && !pending.isCompleted) {
            pending.completeError(error, stack);
          }
        },
      );
    });
    return completer.future;
  }

  /// Force any pending debounced saves to disk immediately. Intended for
  /// shutdown / logout paths so the very last burst of messages doesn't get
  /// stranded in a not-yet-fired timer.
  Future<void> flushPendingSaves() async {
    final ids = _appendDebounceTimers.keys.toList(growable: false);
    for (final id in ids) {
      _appendDebounceTimers.remove(id)?.cancel();
      final pending = _appendDebouncePending.remove(id);
      final list = _historyById[id];
      if (list == null || list.isEmpty) {
        pending?.complete();
        continue;
      }
      try {
        await saveHistory(id, List<ChatMessage>.from(list));
        pending?.complete();
      } catch (e, stack) {
        if (pending != null && !pending.isCompleted) {
          pending.completeError(e, stack);
        }
      }
    }
  }

  /// Tear down the persistence service.
  ///
  /// Awaits [flushPendingSaves] first so any in-flight debounced batch lands
  /// on disk before the timers are cancelled — otherwise teardown paths that
  /// forget to call `flushPendingSaves()` themselves would silently drop the
  /// last burst of messages. Idempotent: a caller that has already awaited
  /// `flushPendingSaves()` will see an empty debounce map and skip straight
  /// to the cancel/clear pass.
  Future<void> dispose() async {
    await flushPendingSaves();
    _disposed = true;
    for (final timer in _appendDebounceTimers.values) {
      timer.cancel();
    }
    _appendDebounceTimers.clear();
    for (final completer in _appendDebouncePending.values) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _appendDebouncePending.clear();
  }
  
  /// Whether [msg] is identified by [id] — either its current primary
  /// [ChatMessage.msgID] or a cross-path duplicate id it absorbed during
  /// content dedup ([ChatMessage.altMsgIds]). Every exact-id lookup in this
  /// class routes through here so a dropped hybrid-path id stays resolvable.
  bool _idMatches(ChatMessage msg, String id) =>
      msg.msgID == id || msg.altMsgIds.contains(id);

  /// Intelligently merge two messages that resolve to the same logical message
  /// (matched by msgID, an absorbed alias, or the content-dedup heuristic).
  ///
  /// Prefers final file paths over temporary paths, and preserves the best
  /// state. CRITICAL: the result keeps `updated.msgID ?? existing.msgID` as its
  /// primary id, and records EVERY other id the two copies carried (the other
  /// primary + both altMsgIds sets) in [ChatMessage.altMsgIds]. This is what
  /// keeps a cross-path duplicate's dropped id resolvable: whichever id loses
  /// the primary slot is retained as an alias, even across a later merge that
  /// flips the primary. The alias set lives on the row, so it persists and
  /// reloads with the message (no external map to desync after a restart).
  ChatMessage _mergeMessages(ChatMessage existing, ChatMessage updated) {
    // Prefer final path over temp path
    final filePath = updated.isTempPath && !existing.isTempPath
      ? existing.filePath
      : (!updated.isTempPath ? updated.filePath : existing.filePath);

    // Merge file metadata
    final fileSize = updated.fileSize ?? existing.fileSize;
    final mimeType = updated.mimeType ?? existing.mimeType;
    final fileHash = updated.fileHash ?? existing.fileHash;

    // Merge states: both must be pending for result to be pending
    final isPending = updated.isPending && existing.isPending;
    // Either received means received
    final isReceived = updated.isReceived || existing.isReceived;
    // Either read means read
    final isRead = updated.isRead || existing.isRead;

    final mergedMsgID = updated.msgID ?? existing.msgID;
    // Union every id either copy carried, minus the one that becomes primary,
    // minus nulls. Sorted for deterministic on-disk output. When both copies
    // share the same id (the common file_request/file_done merge) this stays
    // empty — only genuine cross-path duplicates accumulate aliases.
    final aliasIds = <String>{
      ...existing.altMsgIds,
      ...updated.altMsgIds,
      if (existing.msgID != null) existing.msgID!,
      if (updated.msgID != null) updated.msgID!,
    }..removeWhere((id) => id == mergedMsgID);
    final altMsgIds = aliasIds.toList()..sort();

    return ChatMessage(
      text: updated.text.isNotEmpty ? updated.text : existing.text,
      fromUserId: updated.fromUserId,
      isSelf: updated.isSelf,
      timestamp: updated.timestamp.isAfter(existing.timestamp) ? updated.timestamp : existing.timestamp,
      groupId: updated.groupId ?? existing.groupId,
      filePath: filePath,
      fileName: updated.fileName ?? existing.fileName,
      mediaKind: updated.mediaKind ?? existing.mediaKind,
      isPending: isPending,
      isReceived: isReceived,
      isRead: isRead,
      msgID: mergedMsgID,
      version: updated.version,
      fileSize: fileSize,
      mimeType: mimeType,
      fileHash: fileHash,
      altMsgIds: altMsgIds,
      // S17/S18 reply/forward quote. toxee's hybrid runtime double-writes an
      // outbound send through both paths with different msgIDs, which merge
      // here — and only ONE copy carries the sender-side cloudCustomData
      // (FfiChatService.sendText sets it; the binary-replacement copy does
      // not). Preferring whichever copy has it keeps the quote from being
      // erased by the merge. Without this, the persisted reply loses its
      // messageReply metadata even though sendText set it (L3-reply-text).
      cloudCustomData: updated.cloudCustomData ?? existing.cloudCustomData,
    );
  }
  
  /// Get message history for a conversation (from memory cache)
  /// 
  /// Returns the cached messages. If not in cache, returns empty list.
  /// Use loadHistory() to load from disk if needed.
  /// 
  /// [conversationId] - Will be normalized before lookup
  List<ChatMessage> getHistory(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    return List<ChatMessage>.from(_historyById[normalizedId] ?? []);
  }
  
  /// Check if history file exists for a conversation
  /// Returns true if the file exists, false otherwise
  /// 
  /// [conversationId] - Will be normalized before check
  Future<bool> historyFileExists(String conversationId) async {
    try {
      final normalizedId = ConversationIdUtils.normalize(conversationId);
      final file = await _getHistoryFile(normalizedId);
      return await file.exists();
    } catch (e) {
      return false;
    }
  }
  
  /// Get all conversation IDs that have history
  Set<String> getConversationIds() {
    return _historyById.keys.toSet();
  }
  
  /// Clear history for a specific conversation
  /// This deletes the JSON history file but does NOT delete actual media files
  /// (images, videos, audio, documents) referenced in the messages
  /// 
  /// Also clears all cache entries that might match this conversation ID
  /// (e.g., original ID and normalized ID variants)
  /// 
  /// CRITICAL: This method scans all history files to find and delete any file
  /// that contains messages for this conversation, even if the filename doesn't match
  /// (e.g., due to ID normalization or sanitization differences)
  /// 
  /// [conversationId] - Will be normalized before clearing
  Future<void> clearHistory(String conversationId) async {
    // Normalize conversationId for comparison
    final normalizedConversationId = ConversationIdUtils.normalize(conversationId);

    // Cancel any in-flight debounced saves for this conversation — otherwise
    // a queued save could resurrect the in-memory list we are about to clear.
    _appendDebounceTimers.remove(conversationId)?.cancel();
    _appendDebounceTimers.remove(normalizedConversationId)?.cancel();
    final pendingDirect = _appendDebouncePending.remove(conversationId);
    if (pendingDirect != null && !pendingDirect.isCompleted) {
      pendingDirect.complete();
    }
    final pendingNormalized = _appendDebouncePending.remove(normalizedConversationId);
    if (pendingNormalized != null && !pendingNormalized.isCompleted) {
      pendingNormalized.complete();
    }

    // Clear in-memory cache for this ID and all variants
    _historyById.remove(conversationId);
    
    // Also clear any cache entries that might match this conversation
    // (e.g., if there are multiple ID variants stored)
    final keysToRemove = <String>[];
    for (final key in _historyById.keys) {
      // Normalize key for comparison
      final normalizedKey = ConversationIdUtils.normalize(key);
      
      // Check if key matches conversationId using normalized comparison
      if (ConversationIdUtils.equals(key, conversationId) ||
          ConversationIdUtils.equals(normalizedKey, normalizedConversationId)) {
        keysToRemove.add(key);
      }
    }
    for (final key in keysToRemove) {
      _historyById.remove(key);
    }
    
    // Await any in-flight write for this conversation before deleting. A
    // debounced `saveHistory` whose timer already FIRED (so the cancel above
    // was a no-op) may be mid `tempFile.rename(file.path)` holding a
    // pre-clear snapshot; if we delete first, its rename lands afterwards and
    // resurrects the file (re-introducing the message the caller just
    // deleted). Awaiting the per-conversation write fence lets that rename
    // complete first, so our delete below removes the final state. The cache
    // is already cleared above, so no NEW debounced save can be scheduled for
    // this id (a later incoming message is a legitimate new conversation).
    for (final fenceId in <String>{normalizedConversationId, conversationId}) {
      final fence = _writeFences[fenceId];
      if (fence != null) {
        try {
          await fence;
        } catch (_) {
          // A failed write must not block the delete.
        }
      }
    }

    // H7: filenames are deterministic — `_getHistoryFile` derives them from
    // `ConversationIdUtils.normalize` + `sanitizeForFilename`. Compute both
    // candidates (normalized + legacy un-normalized) and delete only those,
    // instead of scanning + JSON-parsing every `.json` in the directory
    // (which was O(n-conversations) and would race with concurrent debounced
    // saves mid-rename, occasionally swallowing a parse error and leaving a
    // file undeleted).
    try {
      final filesToTry = <File>{
        await _getHistoryFile(normalizedConversationId),
        if (conversationId != normalizedConversationId)
          await _getHistoryFile(conversationId),
      };
      for (final f in filesToTry) {
        try {
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {
          // Best-effort; memory cache is already cleared above.
        }
      }
      // Also drop any backup file we may have left around.
      try {
        final backup = await _getBackupFile(normalizedConversationId);
        if (await backup.exists()) {
          await backup.delete();
        }
      } catch (_) {}
    } catch (e) {
      // Log error but don't throw - clearing should continue
      // The file may not exist or may be locked, but we've cleared memory cache
    }
  }
  
  /// Clear all message histories
  Future<void> clearAllHistories() async {
    // Cancel any in-flight debounced saves so they don't recreate files we
    // are about to delete.
    for (final timer in _appendDebounceTimers.values) {
      timer.cancel();
    }
    _appendDebounceTimers.clear();
    for (final completer in _appendDebouncePending.values) {
      if (!completer.isCompleted) completer.complete();
    }
    _appendDebouncePending.clear();

    _historyById.clear();

    try {
      final historyDir = await _getHistoryDirectory();
      if (await historyDir.exists()) {
        await historyDir.delete(recursive: true);
      }
    } catch (e) {
      // Ignore errors
    }
  }
  
  /// Update a message in the history
  /// 
  /// Finds the message by msgID and updates it, then saves to disk.
  /// 
  /// [conversationId] - Will be normalized before update
  Future<bool> updateMessage(String conversationId, String msgID, ChatMessage updatedMessage) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list == null) return false;
    
    final index = list.indexWhere((msg) => _idMatches(msg, msgID));
    if (index == -1) return false;

    // Merge intelligently instead of direct replacement
    final existing = list[index];
    final merged = _mergeMessages(existing, updatedMessage);
    list[index] = merged;
    await saveHistory(normalizedId, list);
    return true;
  }
  
  /// Safely update file path for a message
  /// 
  /// This method ensures atomic file path updates with integrity checks:
  /// 1. Verifies the new file exists (refuses the update otherwise unless
  ///    [allowMissing] is set)
  /// 2. Gets file metadata (size, etc.)
  /// 3. Updates the message atomically
  /// 4. Optionally deletes the old temporary file after successful update
  /// 
  /// [conversationId] - Will be normalized before update
  /// [msgID] - Message ID to update
  /// [newFilePath] - New file path (must exist unless [allowMissing] is true)
  /// [deleteOldTempFile] - Whether to delete old temp file after successful update
  /// [allowMissing] - Opt into the legacy behavior of repointing history at a
  ///   path that does not exist yet (the old temp file is never deleted in
  ///   that case). Defaults to false, which refuses the update.
  ///
  /// Returns true if update was successful, false otherwise.
  Future<bool> updateFilePathSafely(
    String conversationId,
    String msgID,
    String newFilePath, {
    bool deleteOldTempFile = true,
    bool allowMissing = false,
  }) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list == null) return false;
    
    final index = list.indexWhere((msg) => _idMatches(msg, msgID));
    if (index == -1) return false;

    final existing = list[index];
    final oldFilePath = existing.filePath;
    
    // 1. Verify the new file exists. CR-06: the documented contract is that
    // the new path must exist; refuse to repoint history at a dangling path
    // (and do NOT delete the old temp below) unless the caller explicitly
    // opts into the compatibility behavior via [allowMissing].
    final newFile = File(newFilePath);
    final newFileExists = await newFile.exists();
    if (!newFileExists && !allowMissing) {
      return false;
    }

    // 2. Get file metadata if the file exists.
    int? fileSize;
    if (newFileExists) {
      try {
        fileSize = await newFile.length();
      } catch (e) {
        // Ignore errors getting file size.
      }
    }
    
    // 3. Create updated message
    final updated = existing.copyWith(
      filePath: newFilePath,
      fileSize: fileSize,
    );
    
    // 4. Update message atomically. M4: the previous "verify by re-reading
    // the same in-memory list we just wrote into" was dead code (the check
    // could never trip) and swallowed real disk-write failures. Wrap the
    // save in try/catch instead so an actual `saveHistory` exception is
    // surfaced to the caller and the in-memory mutation gets reverted.
    list[index] = updated;
    try {
      await saveHistory(normalizedId, list);
    } catch (_) {
      list[index] = existing;
      return false;
    }

    // 5. Delete old temp file if requested and update was successful. CR-06:
    // never delete the old temp when the new file is missing, or we'd lose
    // both files (the legacy [allowMissing] path can repoint to a dangling
    // path that may never materialize).
    if (deleteOldTempFile &&
        newFileExists &&
        oldFilePath != null &&
        existing.isTempPath) {
      // Delay deletion to ensure update is persisted
      Future.delayed(Duration(seconds: 5), () async {
        try {
          final oldFile = File(oldFilePath);
          if (await oldFile.exists()) {
            await oldFile.delete();
          }
        } catch (e) {
          // Ignore deletion errors - file might be in use or already deleted
        }
      });
    }
    
    return true;
  }
  
  /// Remove a message from the history
  /// 
  /// Finds the message by msgID and removes it, then saves to disk.
  /// 
  /// [conversationId] - Will be normalized before removal
  Future<bool> removeMessage(String conversationId, String msgID) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list == null) return false;
    
    final initialLength = list.length;
    list.removeWhere((msg) => _idMatches(msg, msgID));

    if (list.length < initialLength) {
      await saveHistory(normalizedId, list);
      return true;
    }
    
    return false;
  }
  
  /// Get the in-memory cache (for direct access if needed)
  Map<String, List<ChatMessage>> get cache => Map.unmodifiable(_historyById);

  /// Set the in-memory cache (for initialization)
  void setCache(Map<String, List<ChatMessage>> cache) {
    _historyById.clear();
    _historyById.addAll(cache);
  }

  /// Replace the in-memory cached history for a single conversation.
  ///
  /// Used by mutating operations (e.g. message deletion) whose owner keeps a
  /// parallel list and wants the persistence cache to stay in sync so that
  /// subsequent `getHistory(id)` reads do not return stale data. Does not
  /// touch disk; pair with `saveHistory` when persistence is also required.
  ///
  /// [conversationId] - Will be normalized before use.
  void setCachedHistory(String conversationId, List<ChatMessage> messages) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    if (messages.isEmpty) {
      _historyById.remove(normalizedId);
    } else {
      _historyById[normalizedId] = List<ChatMessage>.from(messages);
    }
  }

  // ---- Single-source-of-truth cache accessors (X4 consolidation) ----
  //
  // The previous design kept a parallel `_historyByIdInternal` map inside
  // `FfiChatService` and lazily merged from `_historyById` here, which let the
  // two drift (e.g. `_handleFileDone` mutated the FfiChatService list by index
  // and only `_saveHistory`'d that one — the persistence cache never saw the
  // update). These accessors expose the persistence map as the only writable
  // in-memory store so FfiChatService can act as a thin client over it.

  /// Lookup the cached list for [conversationId] WITHOUT defensive copy.
  ///
  /// Returns the mutable internal list (or null if absent). Callers may mutate
  /// elements in place (e.g. `list[i] = updated`) and the mutations are
  /// observable through subsequent [getHistory] / [cache] reads. After a
  /// mutation, the caller is responsible for arranging persistence via
  /// [saveHistory] (or [appendHistory] for new tail entries).
  ///
  /// Pure reads that want a defensive copy should keep using [getHistory].
  ///
  /// [conversationId] - Will be normalized before lookup.
  List<ChatMessage>? getCachedList(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    return _historyById[normalizedId];
  }

  /// Lookup the cached list for [conversationId], creating an empty list if
  /// it does not yet exist. Returns the mutable internal list.
  ///
  /// Like [getCachedList], element mutations are observable downstream and the
  /// caller is responsible for persistence.
  ///
  /// [conversationId] - Will be normalized before use.
  List<ChatMessage> ensureCachedList(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    return _historyById.putIfAbsent(normalizedId, () => <ChatMessage>[]);
  }

  /// Replace a single message in the cached list at [index]. No-op if the
  /// conversation is not cached or the index is out of range.
  ///
  /// Does not touch disk — callers needing persistence should follow up with
  /// [saveHistory] (or use [updateMessage] for the merge-aware path).
  ///
  /// [conversationId] - Will be normalized before lookup.
  void replaceInCache(
      String conversationId, int index, ChatMessage message) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list == null || index < 0 || index >= list.length) return;
    list[index] = message;
  }

  /// Remove the cached list for [conversationId]. Does not delete the on-disk
  /// file — use [clearHistory] for the full clear semantics.
  ///
  /// [conversationId] - Will be normalized before removal.
  void removeCachedHistory(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    _historyById.remove(normalizedId);
    // Also strip exact-match (un-normalized) variant to mirror legacy
    // FfiChatService behaviour for ids that fail the equals check.
    _historyById.remove(conversationId);
  }

  /// Clear ALL in-memory cached histories. Does not touch disk.
  ///
  /// Used by FfiChatService.dispose() to release per-account state without
  /// disturbing the persisted JSON files (which are wiped via
  /// [clearAllHistories] only on explicit account deletion).
  void clearAllCached() {
    _historyById.clear();
  }
  
  /// Update the last view timestamp for a conversation
  /// 
  /// Updates the timestamp when the user last viewed the conversation.
  /// This is used to calculate unread message count.
  /// 
  /// [conversationId] - Will be normalized before update
  Future<void> updateLastViewTimestamp(String conversationId, int timestamp) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    _lastViewTimestampById[normalizedId] = timestamp;
    // Save the updated history to persist the new timestamp
    final messages = _historyById[normalizedId];
    if (messages != null && messages.isNotEmpty) {
      await saveHistory(normalizedId, messages);
    }
  }
  
  /// Get the last view timestamp for a conversation
  /// 
  /// Returns the timestamp when the user last viewed the conversation.
  /// Returns 0 if the conversation has never been viewed.
  /// 
  /// [conversationId] - Will be normalized before lookup
  int getLastViewTimestamp(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    return _lastViewTimestampById[normalizedId] ?? 0;
  }
  
  /// Get the unread message count for a conversation
  ///
  /// Calculates the number of unread messages based on:
  /// - Messages with timestamp > lastViewTimestamp
  /// - Messages that are not self-sent (!isSelf)
  /// - Messages that are not marked as read (!isRead)
  ///
  /// TODO(time-drift): `lastViewTimestamp` is written using `DateTime.now()`
  /// on the local device but compared against `msg.timestamp`, which often
  /// originates from the remote peer's clock. System-clock rollback or large
  /// cross-device skew can either inflate the unread count (already-seen
  /// messages re-counted) or zero it out (new messages stamped earlier than
  /// the local clock). The right fix is to anchor `lastViewTimestamp` to the
  /// highest message timestamp in the conversation at view-time, or to also
  /// persist a read-msgID set. `setActivePeer` now calls
  /// [markConversationViewed], which anchors the barrier to the max message
  /// timestamp (the wall-clock path remains on the legacy
  /// `updateLastViewTimestamp` for any external callers).
  ///
  /// [conversationId] - Will be normalized before lookup
  int getUnreadCount(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final messages = _historyById[normalizedId];
    if (messages == null || messages.isEmpty) {
      return 0;
    }
    
    int count = 0;

    for (final msg in messages) {
      // isRead is authoritative: markConversationViewed flags every message
      // present at view-time, loadHistory reconciles persisted history against
      // the view barrier, and new arrivals come in unread. Counting `!isRead`
      // (rather than the old strict `ts > lastView`) means a same-millisecond
      // or clock-skewed arrival — timestamp <= the barrier yet genuinely new —
      // is still counted instead of being silently dropped.
      if (!msg.isSelf && !msg.isRead) {
        count++;
      }
    }

    return count;
  }
  
  /// Mark all unread messages as read for a conversation
  /// 
  /// Marks all messages with timestamp > lastViewTimestamp and !isSelf as read.
  /// This is called when the user opens a conversation.
  /// 
  /// [conversationId] - Will be normalized before update
  Future<void> markUnreadMessagesAsRead(String conversationId) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final messages = _historyById[normalizedId];
    if (messages == null || messages.isEmpty) {
      return;
    }
    
    final lastViewTimestamp = _lastViewTimestampById[normalizedId] ?? 0;
    bool updated = false;
    
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final msgTimestamp = msg.timestamp.millisecondsSinceEpoch;
      // Mark messages as read that are:
      // 1. After the last view timestamp
      // 2. Not self-sent
      // 3. Not already marked as read
      if (msgTimestamp > lastViewTimestamp && !msg.isSelf && !msg.isRead) {
        messages[i] = msg.copyWith(isRead: true);
        updated = true;
      }
    }
    
    if (updated) {
      await saveHistory(normalizedId, messages);
    }
  }

  /// Mark a conversation as viewed with a clock-drift-immune read barrier.
  ///
  /// Instead of stamping `lastViewTimestamp` with the local wall clock (which
  /// drifts relative to the remote `msg.timestamp` values it is compared
  /// against in [getUnreadCount]), anchor the barrier to the highest message
  /// timestamp currently in the conversation and flag every current non-self
  /// message `isRead`. Messages that arrive afterwards carry a strictly
  /// greater timestamp and are still counted as unread.
  ///
  /// [conversationId] - Will be normalized before use.
  Future<void> markConversationViewed(String conversationId) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    var messages = _historyById[normalizedId];
    // If history exists on disk but isn't loaded into memory yet, load it so
    // the barrier anchors to — and is persisted alongside — the real messages.
    // Without this, viewing an unloaded conversation only stamped an in-memory
    // barrier that was lost on restart (loadHistory would then restore the
    // older on-disk barrier, re-counting already-seen messages as unread).
    if (messages == null) {
      final file = await _getHistoryFile(normalizedId);
      if (await file.exists()) {
        await loadHistory(normalizedId);
        messages = _historyById[normalizedId];
      }
    }
    if (messages == null || messages.isEmpty) {
      // Genuinely empty/new conversation: no messages to anchor to. Stamp an
      // in-memory wall-clock barrier; it is persisted by the next saveHistory
      // once a message arrives, and until then there is nothing to be unread.
      final now = DateTime.now().millisecondsSinceEpoch;
      final prevBarrier = _lastViewTimestampById[normalizedId] ?? 0;
      if (now > prevBarrier) {
        _lastViewTimestampById[normalizedId] = now;
      }
      return;
    }

    int maxTimestamp = _lastViewTimestampById[normalizedId] ?? 0;
    bool updated = false;
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final ts = msg.timestamp.millisecondsSinceEpoch;
      if (ts > maxTimestamp) maxTimestamp = ts;
      if (!msg.isSelf && !msg.isRead) {
        messages[i] = msg.copyWith(isRead: true);
        updated = true;
      }
    }
    final prevBarrier = _lastViewTimestampById[normalizedId] ?? 0;
    if (maxTimestamp > prevBarrier) {
      _lastViewTimestampById[normalizedId] = maxTimestamp;
      updated = true;
    }
    if (updated) {
      await saveHistory(normalizedId, messages);
    }
  }

  /// Clean up temporary files on startup
  /// 
  /// Removes temporary files and old backups that are no longer needed.
  Future<void> cleanupTempFiles() async {
    try {
      final dir = await _getHistoryDirectory();
      if (!await dir.exists()) return;
      
      final files = dir.listSync();
      final now = DateTime.now();
      
      for (final fileEntry in files) {
        if (fileEntry is File) {
          try {
            // Clean up temporary files (.tmp)
            if (fileEntry.path.endsWith('.tmp')) {
              final stat = await fileEntry.stat();
              final age = now.difference(stat.modified);
              // Delete temp files older than 1 hour
              if (age.inHours > 1) {
                await fileEntry.delete();
              }
            }
            
            // Clean up old backup files (.bak) - keep only recent ones
            if (fileEntry.path.endsWith('.bak')) {
              final stat = await fileEntry.stat();
              final age = now.difference(stat.modified);
              // Delete backups older than 7 days
              if (age.inDays > 7) {
                await fileEntry.delete();
              }
            }
          } catch (e) {
            // Continue cleanup even if one file fails
          }
        }
      }
    } catch (e) {
      // Ignore cleanup errors
    }
  }
}
