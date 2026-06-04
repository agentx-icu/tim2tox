/// Unified offline message queue persistence service
///
/// This service provides a unified interface for persisting offline message queue
/// that can be used by both Platform interface scheme and binary replacement scheme.
///
/// Storage location: `<appDir>/offline_message_queue.json`
/// Data format: JSON map of peerId -> list of pending messages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Offline message queue item.
///
/// `kind` discriminates between text and file replays. Files carry both
/// `filePath` (used to re-send) and `fileName` (preserved so the UI keeps
/// the original display name when the on-disk path was sanitised).
/// `msgID` (added 2026-05-29) is the durable identity of the optimistic pending
/// history row this queue item corresponds to. The drain/fail matchers prefer
/// it over the legacy exact-millisecond-timestamp heuristic, which removes the
/// last ambiguity (two identical messages queued in the same millisecond).
/// Nullable for backward compatibility: queue files written before this field
/// existed deserialize with `msgID == null`, and the matchers fall back to the
/// timestamp heuristic for those.
typedef OfflineMessageItem = ({
  String kind,
  String text,
  String? filePath,
  String? fileName,
  DateTime timestamp,
  String? msgID,
});

/// Offline message queue persistence service
///
/// Provides unified offline message queue persistence for both Platform and binary replacement schemes.
/// When [queueFilePath] is set (e.g. per-account path from app), uses that file; otherwise uses
/// default under app support directory.
class OfflineMessageQueuePersistence {
  final String? _queueFilePath;

  OfflineMessageQueuePersistence({String? queueFilePath}) : _queueFilePath = queueFilePath;

  // In-memory cache: peerId -> List<OfflineMessageItem>
  final Map<String, List<OfflineMessageItem>> _offlineQueue = {};

  /// Get the file path for offline message queue.
  Future<File> _getQueueFile() async {
    if (_queueFilePath != null && _queueFilePath!.isNotEmpty) {
      final file = File(_queueFilePath!);
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      return file;
    }
    final appDir = await getApplicationSupportDirectory();
    return File('${appDir.path}/offline_message_queue.json');
  }

  /// Save offline message queue to disk
  Future<void> saveQueue(Map<String, List<OfflineMessageItem>> queue) async {
    try {
      final file = await _getQueueFile();
      final jsonMap = <String, dynamic>{};

      for (final entry in queue.entries) {
        jsonMap[entry.key] = entry.value.map((item) => {
          'kind': item.kind,
          'text': item.text,
          'filePath': item.filePath,
          'fileName': item.fileName,
          'timestamp': item.timestamp.toIso8601String(),
          'msgID': item.msgID,
        }).toList();
      }

      await file.writeAsString(jsonEncode(jsonMap));
      // Update in-memory cache
      _offlineQueue.clear();
      _offlineQueue.addAll(queue);
    } catch (e) {
      // Silently handle errors
    }
  }

  /// Load offline message queue from disk.
  ///
  /// Default: do NOT clear on load — queued items must survive restart so the
  /// drain on next online transition can resend them. Callers that explicitly
  /// want the legacy "drop everything on startup" semantics can still pass
  /// `clearOnLoad: true`.
  Future<Map<String, List<OfflineMessageItem>>> loadQueue({bool clearOnLoad = false}) async {
    try {
      final file = await _getQueueFile();
      if (!await file.exists()) {
        return {};
      }

      if (clearOnLoad) {
        try {
          await file.delete();
        } catch (e) {
          // Ignore deletion errors
        }
        _offlineQueue.clear();
        return {};
      }

      // Load from file
      final jsonString = await file.readAsString();
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;

      final queue = <String, List<OfflineMessageItem>>{};

      for (final entry in decoded.entries) {
        final peerId = entry.key;
        final items = (entry.value as List<dynamic>).map((item) {
          final map = item as Map<String, dynamic>;
          final filePath = map['filePath'] as String?;
          // Backward-compat: older entries lack `kind`; infer from filePath.
          final kind = (map['kind'] as String?) ??
              ((filePath != null && filePath.isNotEmpty) ? 'file' : 'text');
          return (
            kind: kind,
            text: (map['text'] as String?) ?? '',
            filePath: filePath,
            fileName: map['fileName'] as String?,
            timestamp: DateTime.parse(map['timestamp'] as String),
            // Backward-compat: pre-2026-05-29 entries lack `msgID` → null, and
            // the drain matchers fall back to exact-ms timestamp for those.
            msgID: map['msgID'] as String?,
          );
        }).toList();
        queue[peerId] = items;
      }

      _offlineQueue.clear();
      _offlineQueue.addAll(queue);
      return queue;
    } catch (e) {
      return {};
    }
  }

  /// Add a message to the offline queue for a peer
  void addMessage(String peerId, OfflineMessageItem item) {
    final list = _offlineQueue.putIfAbsent(peerId, () => <OfflineMessageItem>[]);
    list.add(item);
    // Save asynchronously
    unawaited(saveQueue(_offlineQueue));
  }

  /// Get messages for a peer from the queue
  List<OfflineMessageItem> getMessages(String peerId) {
    return List.from(_offlineQueue[peerId] ?? []);
  }

  /// Remove messages for a peer from the queue
  Future<void> removeMessages(String peerId) async {
    _offlineQueue.remove(peerId);
    await saveQueue(_offlineQueue);
  }

  /// Remove a single [item] from [peerId]'s queue and persist immediately.
  ///
  /// Used by the drain loop so disk state always reflects pending work: even
  /// if the process is killed mid-drain, only items that were successfully
  /// dispatched (or explicitly given up on) are gone from disk; everything
  /// still pending stays queued for the next online transition.
  ///
  /// `OfflineMessageItem` is a Dart record, so equality is structural over
  /// `(kind, text, filePath, fileName, timestamp)` — that's sufficient to
  /// identify the entry. If the same logical message appears more than once
  /// in the list (duplicate enqueue), only the first occurrence is removed.
  ///
  /// If the peer's list becomes empty after removal, the key is dropped so
  /// the persisted JSON doesn't accumulate empty arrays.
  Future<void> removeItem(String peerId, OfflineMessageItem item) async {
    final list = _offlineQueue[peerId];
    if (list == null || list.isEmpty) {
      return;
    }
    final index = list.indexOf(item);
    if (index < 0) {
      return;
    }
    list.removeAt(index);
    if (list.isEmpty) {
      _offlineQueue.remove(peerId);
    }
    await _persistCache();
  }

  /// Write the current in-memory cache to disk without mutating the cache.
  ///
  /// [saveQueue] takes an external map and replaces the cache with it, which
  /// is unsafe when the caller passes the cache itself (clear() then addAll()
  /// on the same map wipes the cache). This helper is the safe path used by
  /// per-item mutations.
  Future<void> _persistCache() async {
    try {
      final file = await _getQueueFile();
      final jsonMap = <String, dynamic>{};
      for (final entry in _offlineQueue.entries) {
        jsonMap[entry.key] = entry.value.map((item) => {
              'kind': item.kind,
              'text': item.text,
              'filePath': item.filePath,
              'fileName': item.fileName,
              'timestamp': item.timestamp.toIso8601String(),
              'msgID': item.msgID,
            }).toList();
      }
      await file.writeAsString(jsonEncode(jsonMap));
    } catch (e) {
      // Silently handle errors; cache stays the source of truth in-memory.
    }
  }

  /// Clear all messages from the queue
  Future<void> clearQueue() async {
    _offlineQueue.clear();
    await saveQueue(_offlineQueue);
  }

  /// Get all peer IDs that have messages in the queue
  Set<String> getPeerIds() {
    return _offlineQueue.keys.toSet();
  }

  /// Get the in-memory cache (for direct access if needed)
  Map<String, List<OfflineMessageItem>> get cache => Map.unmodifiable(_offlineQueue);

  /// Set the in-memory cache (for initialization)
  void setCache(Map<String, List<OfflineMessageItem>> cache) {
    _offlineQueue.clear();
    _offlineQueue.addAll(cache);
  }

  /// Clear the queue file from disk
  Future<void> clearQueueFile() async {
    try {
      final file = await _getQueueFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // Ignore errors
    }
    _offlineQueue.clear();
  }
}
