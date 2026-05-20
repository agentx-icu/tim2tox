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
typedef OfflineMessageItem = ({
  String kind,
  String text,
  String? filePath,
  String? fileName,
  DateTime timestamp,
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
