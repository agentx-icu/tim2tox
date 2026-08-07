part of 'offline_message_queue_persistence.dart';

class _ReadQueueResult {
  const _ReadQueueResult.success(this.queue)
      : error = null,
        isSuccess = true;

  const _ReadQueueResult.failure(this.error)
      : queue = null,
        isSuccess = false;

  final Map<String, List<OfflineMessageItem>>? queue;
  final Object? error;
  final bool isSuccess;
}

/// Owns queue-file paths, JSON encoding, and atomic file replacement.
///
/// This is a private part of the persistence library so none of these mechanics
/// become package API. The public service remains responsible for mutation
/// ordering and cache updates.
class _OfflineMessageQueueFileStore {
  _OfflineMessageQueueFileStore(this.file)
      : backupFile = File('${file.path}.bak'),
        tempFile = File('${file.path}.tmp'),
        backupTempFile = File('${file.path}.bak.tmp');

  final File file;
  final File backupFile;
  final File tempFile;
  final File backupTempFile;

  Future<_ReadQueueResult> tryReadSnapshot(File source) async {
    if (!await source.exists()) {
      return const _ReadQueueResult.failure(
        FileSystemException('queue file does not exist'),
      );
    }
    try {
      return _ReadQueueResult.success(await _readSnapshot(source));
    } catch (error) {
      return _ReadQueueResult.failure(error);
    }
  }

  Future<void> writeSnapshot(
    Map<String, List<OfflineMessageItem>> snapshot,
  ) async {
    if (await file.exists()) {
      await _copyPrimaryToBackup();
    }

    await _writeStringAtomically(file, tempFile, jsonEncode(_toJson(snapshot)));

    try {
      await _copyPrimaryToBackup();
    } catch (_) {
      // The primary is already durable. A stale valid backup remains usable,
      // and loadQueue removes a leftover backupTempFile before returning.
    }
  }

  /// Atomically replaces the primary queue with the empty queue snapshot.
  ///
  /// Callers treat this durable rename as the logical clear commit point. The
  /// backup must then be refreshed with [publishPrimaryToBackup] before either
  /// file is physically removed.
  Future<void> publishEmptyPrimary() async {
    final emptySnapshot = <String, List<OfflineMessageItem>>{};
    await _writeStringAtomically(
      file,
      tempFile,
      jsonEncode(_toJson(emptySnapshot)),
    );
  }

  /// Atomically mirrors the current primary through the single `.bak.tmp`
  /// staging path.
  Future<void> publishPrimaryToBackup() => _copyPrimaryToBackup();

  Future<void> restorePrimaryFromBackup() async {
    final content = await backupFile.readAsString();
    await _writeStringAtomically(file, tempFile, content);
  }

  Future<void> deleteStagingArtifacts() async {
    await _deleteIfExists(tempFile);
    await _deleteIfExists(backupTempFile);
  }

  Future<void> deleteArtifacts() async {
    await _deleteIfExists(file);
    await _deleteIfExists(backupFile);
    await deleteStagingArtifacts();
  }

  Future<Map<String, List<OfflineMessageItem>>> _readSnapshot(
    File source,
  ) async {
    final content = await source.readAsString();
    if (content.isEmpty) {
      throw const FormatException('empty queue file');
    }

    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('queue root must be a JSON object');
    }

    final queue = <String, List<OfflineMessageItem>>{};
    for (final entry in decoded.entries) {
      final rawList = entry.value;
      if (rawList is! List<dynamic>) {
        throw FormatException('queue for ${entry.key} must be a list');
      }
      queue[entry.key] = rawList.map(_itemFromJson).toList(growable: true);
    }
    return queue;
  }

  Map<String, Object?> _toJson(
    Map<String, List<OfflineMessageItem>> snapshot,
  ) {
    return {
      for (final entry in snapshot.entries)
        entry.key: entry.value.map(_itemToJson).toList(),
    };
  }

  OfflineMessageItem _itemFromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('queue item must be a JSON object');
    }
    final filePath = _optionalString(raw, 'filePath');
    final rawKind = raw['kind'];
    if (rawKind != null && rawKind is! String) {
      throw const FormatException('queue item kind must be a string');
    }
    final kind = rawKind as String? ??
        ((filePath != null && filePath.isNotEmpty) ? 'file' : 'text');
    return (
      kind: kind,
      text: _optionalString(raw, 'text') ?? '',
      filePath: filePath,
      fileName: _optionalString(raw, 'fileName'),
      timestamp: DateTime.parse(_requiredString(raw, 'timestamp')),
      msgID: _optionalString(raw, 'msgID'),
      cloudCustomData: _optionalString(raw, 'cloudCustomData'),
      contentKind: chatMessageContentKindFromJson(raw['contentKind']),
    );
  }

  Map<String, Object?> _itemToJson(OfflineMessageItem item) {
    return {
      'kind': item.kind,
      'text': item.text,
      'filePath': item.filePath,
      'fileName': item.fileName,
      'timestamp': item.timestamp.toIso8601String(),
      'msgID': item.msgID,
      if (item.cloudCustomData != null) 'cloudCustomData': item.cloudCustomData,
      'contentKind': item.contentKind.name,
    };
  }

  String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String) {
      return value;
    }
    throw FormatException('queue item $key must be a string');
  }

  String? _optionalString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    throw FormatException('queue item $key must be a string when present');
  }

  Future<void> _copyPrimaryToBackup() async {
    await _copyFileAtomically(file, backupFile, backupTempFile);
  }

  Future<void> _writeStringAtomically(
    File target,
    File staging,
    String content,
  ) async {
    await _ensureParent(target);
    final raf = await staging.open(mode: FileMode.write);
    try {
      await raf.writeString(content);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await staging.rename(target.path);
  }

  Future<void> _copyFileAtomically(
    File source,
    File target,
    File staging,
  ) async {
    await _ensureParent(target);
    final bytes = await source.readAsBytes();
    final raf = await staging.open(mode: FileMode.write);
    try {
      await raf.writeFrom(bytes);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await staging.rename(target.path);
  }

  Future<void> _ensureParent(File target) async {
    final parent = target.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
  }

  Future<void> _deleteIfExists(File target) async {
    if (await target.exists()) {
      await target.delete();
    }
  }
}
