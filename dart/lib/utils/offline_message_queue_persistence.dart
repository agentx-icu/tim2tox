// Unified offline message queue persistence service.
//
// Storage location: `<appDir>/offline_message_queue.json`.
// Data format: JSON map of peerId -> list of pending messages.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

part '_offline_message_queue_file_store.dart';

/// Offline message queue item.
///
/// `kind` discriminates between text and file replays. Files carry both
/// `filePath` (used to re-send) and `fileName` (preserved so the UI keeps
/// the original display name when the on-disk path was sanitised).
/// `msgID` is the durable identity of the optimistic pending history row this
/// queue item corresponds to. Nullable for backward compatibility: queue files
/// written before this field existed deserialize with `msgID == null`, and the
/// drain matchers fall back to the timestamp heuristic for those.
/// `cloudCustomData` carries sender-side reply/forward metadata. It is optional
/// so old queue files retain their JSON shape and new plain messages do not gain
/// a redundant key.
typedef OfflineMessageItem = ({
  String kind,
  String text,
  String? filePath,
  String? fileName,
  DateTime timestamp,
  String? msgID,
  String? cloudCustomData,
});

/// Raised when the primary queue file cannot be parsed and no valid backup can
/// restore it. The corrupt files are left untouched for diagnostics.
class OfflineMessageQueueCorruptionException implements Exception {
  OfflineMessageQueueCorruptionException(this.path, this.cause);

  final String path;
  final Object cause;

  @override
  String toString() => 'OfflineMessageQueueCorruptionException($path): $cause';
}

/// Offline message queue persistence service.
///
/// Provides unified offline message queue persistence for both Platform and
/// binary replacement schemes. When [queueFilePath] is set (for example a
/// per-account path from an app), uses that file; otherwise uses the default
/// file under the app support directory.
class OfflineMessageQueuePersistence {
  OfflineMessageQueuePersistence({String? queueFilePath})
      : _queueFilePath = queueFilePath;

  final String? _queueFilePath;

  // In-memory cache: peerId -> List<OfflineMessageItem>.
  final Map<String, List<OfflineMessageItem>> _offlineQueue = {};

  Future<void> _mutationFence = Future<void>.value();

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

  Future<T> _runSerialized<T>(Future<T> Function() mutation) {
    final previous = _mutationFence;
    final completer = Completer<void>();
    _mutationFence = completer.future;

    return (() async {
      try {
        try {
          await previous;
        } catch (_) {
          // A failed mutation must not poison later mutations.
        }
        return await mutation();
      } finally {
        if (!completer.isCompleted) {
          completer.complete();
        }
        if (identical(_mutationFence, completer.future)) {
          _mutationFence = Future<void>.value();
        }
      }
    })();
  }

  /// Save offline message queue to disk.
  Future<void> saveQueue(Map<String, List<OfflineMessageItem>> queue) {
    final snapshot = _snapshotQueue(queue);
    return _runSerialized(() async {
      await _writeSnapshot(snapshot);
      _replaceCache(snapshot);
    });
  }

  /// Load offline message queue from disk.
  ///
  /// Default: do NOT clear on load; queued items survive restart so the drain on
  /// the next online transition can resend them. Callers that explicitly want
  /// the legacy "drop everything on startup" semantics can still pass
  /// `clearOnLoad: true`.
  Future<Map<String, List<OfflineMessageItem>>> loadQueue({
    bool clearOnLoad = false,
  }) {
    return _runSerialized(() async {
      final file = await _getQueueFile();
      final fileStore = _OfflineMessageQueueFileStore(file);

      if (clearOnLoad) {
        await fileStore.deleteArtifacts();
        _offlineQueue.clear();
        return <String, List<OfflineMessageItem>>{};
      }

      if (await file.exists()) {
        final primary = await fileStore.tryReadSnapshot(file);
        if (primary.isSuccess) {
          await fileStore.deleteStagingArtifacts();
          final snapshot = primary.queue!;
          _replaceCache(snapshot);
          return _snapshotQueue(snapshot);
        }

        final backup = await fileStore.tryReadSnapshot(fileStore.backupFile);
        if (backup.isSuccess) {
          await fileStore.restorePrimaryFromBackup();
          await fileStore.deleteStagingArtifacts();
          final snapshot = backup.queue!;
          _replaceCache(snapshot);
          return _snapshotQueue(snapshot);
        }

        throw OfflineMessageQueueCorruptionException(
          file.path,
          primary.error ?? const FormatException('invalid queue file'),
        );
      }

      if (await fileStore.backupFile.exists()) {
        final backup = await fileStore.tryReadSnapshot(fileStore.backupFile);
        if (backup.isSuccess) {
          await fileStore.restorePrimaryFromBackup();
          await fileStore.deleteStagingArtifacts();
          final snapshot = backup.queue!;
          _replaceCache(snapshot);
          return _snapshotQueue(snapshot);
        }
        throw OfflineMessageQueueCorruptionException(
          fileStore.backupFile.path,
          backup.error ?? const FormatException('invalid backup queue file'),
        );
      }

      await fileStore.deleteStagingArtifacts();
      _offlineQueue.clear();
      return <String, List<OfflineMessageItem>>{};
    });
  }

  /// Add a message to the offline queue for a peer and wait until it is durable.
  Future<void> addMessage(String peerId, OfflineMessageItem item) {
    return _runSerialized(() async {
      final snapshot = _snapshotQueue(_offlineQueue);
      final list = snapshot.putIfAbsent(peerId, () => <OfflineMessageItem>[]);
      list.add(item);
      await _writeSnapshot(snapshot);
      _replaceCache(snapshot);
    });
  }

  /// Get messages for a peer from the queue.
  List<OfflineMessageItem> getMessages(String peerId) {
    return List<OfflineMessageItem>.from(_offlineQueue[peerId] ?? const []);
  }

  /// Remove messages for a peer from the queue.
  Future<void> removeMessages(String peerId) {
    return _runSerialized(() async {
      if (!_offlineQueue.containsKey(peerId)) {
        return;
      }
      final snapshot = _snapshotQueue(_offlineQueue);
      snapshot.remove(peerId);
      await _writeSnapshot(snapshot);
      _replaceCache(snapshot);
    });
  }

  /// Remove a single [item] from [peerId]'s queue and persist immediately.
  ///
  /// Used by the drain loop so disk state always reflects pending work: even if
  /// the process is killed mid-drain, only items that were successfully
  /// dispatched (or explicitly given up on) are gone from disk; everything still
  /// pending stays queued for the next online transition.
  Future<void> removeItem(String peerId, OfflineMessageItem item) {
    return _runSerialized(() async {
      final current = _offlineQueue[peerId];
      if (current == null || current.isEmpty) {
        return;
      }

      final snapshot = _snapshotQueue(_offlineQueue);
      final list = snapshot[peerId];
      if (list == null || list.isEmpty) {
        return;
      }
      final index = list.indexOf(item);
      if (index < 0) {
        return;
      }
      list.removeAt(index);
      if (list.isEmpty) {
        snapshot.remove(peerId);
      }
      await _writeSnapshot(snapshot);
      _replaceCache(snapshot);
    });
  }

  /// Clear all messages from the queue while keeping the queue file as `{}`.
  Future<void> clearQueue() {
    return _runSerialized(() async {
      final snapshot = <String, List<OfflineMessageItem>>{};
      await _writeSnapshot(snapshot);
      _offlineQueue.clear();
    });
  }

  /// Get all peer IDs that have messages in the queue.
  Set<String> getPeerIds() {
    return _offlineQueue.keys.toSet();
  }

  /// Get a defensive snapshot of the in-memory cache.
  Map<String, List<OfflineMessageItem>> get cache => Map.unmodifiable(
        _offlineQueue.map(
          (key, value) => MapEntry(
            key,
            List<OfflineMessageItem>.unmodifiable(value),
          ),
        ),
      );

  /// Set the in-memory cache (for initialization) without touching disk.
  void setCache(Map<String, List<OfflineMessageItem>> cache) {
    _replaceCache(_snapshotQueue(cache));
  }

  /// Wait for mutations that were already submitted to finish.
  Future<void> flushPendingMutations() async {
    try {
      await _mutationFence;
    } catch (_) {
      // The fence itself is intentionally non-poisoning; this is defensive for
      // any future change that completes a mutation future with an error.
    }
  }

  /// Clear the queue file from disk without allowing an old backup to revive.
  ///
  /// The atomic empty-primary rename is the logical commit point, so the cache
  /// is cleared immediately after it succeeds. The empty primary is then
  /// atomically mirrored to `.bak` before physical deletion starts. Cleanup
  /// failures still propagate so callers can retry, but the cache remains empty
  /// and every surviving durable queue file represents the committed clear.
  Future<void> clearQueueFile() {
    return _runSerialized(() async {
      final file = await _getQueueFile();
      final fileStore = _OfflineMessageQueueFileStore(file);
      await fileStore.publishEmptyPrimary();
      _offlineQueue.clear();
      await fileStore.publishPrimaryToBackup();
      await fileStore.deleteArtifacts();
    });
  }

  Map<String, List<OfflineMessageItem>> _snapshotQueue(
    Map<String, List<OfflineMessageItem>> queue,
  ) {
    return {
      for (final entry in queue.entries)
        entry.key: List<OfflineMessageItem>.from(entry.value),
    };
  }

  void _replaceCache(Map<String, List<OfflineMessageItem>> snapshot) {
    _offlineQueue
      ..clear()
      ..addAll(_snapshotQueue(snapshot));
  }

  Future<void> _writeSnapshot(
    Map<String, List<OfflineMessageItem>> snapshot,
  ) async {
    final file = await _getQueueFile();
    await _OfflineMessageQueueFileStore(file).writeSnapshot(snapshot);
  }
}
