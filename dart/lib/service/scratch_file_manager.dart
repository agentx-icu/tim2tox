import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../interfaces/scratch_file_service.dart';

/// Validates and tracks scratch files created for Tim2Tox helper operations.
///
/// When the host does not inject a [ScratchFileService], files are isolated
/// below `Directory.systemTemp/toxee_tim2tox_scratch`. Only paths returned by
/// this manager can be deleted through it.
final class ScratchFileManager {
  ScratchFileManager({ScratchFileService? scratchFileService})
      : _scratchFileService = scratchFileService;

  static const String fallbackDirectoryName = 'toxee_tim2tox_scratch';

  final ScratchFileService? _scratchFileService;
  final Set<String> _trackedPaths = <String>{};
  final Map<String, Future<void>> _pendingDeletes = <String, Future<void>>{};
  bool _disposed = false;

  String get _fallbackRoot =>
      p.join(Directory.systemTemp.path, fallbackDirectoryName);

  Future<String> writeBytesToScratch(
    Uint8List bytes, {
    required String category,
    required String suggestedFileName,
  }) async {
    _ensureActive();
    _validateSegments(category, suggestedFileName);
    final owner = _scratchFileService;
    final result = owner != null
        ? await owner.writeBytesToScratch(
            bytes,
            category: category,
            suggestedFileName: suggestedFileName,
          )
        : await _writeBytesToFallback(
            bytes,
            category: category,
            suggestedFileName: suggestedFileName,
          );
    return _trackResult(result, suggestedFileName: suggestedFileName);
  }

  Future<String> copyFileToScratch(
    String sourcePath, {
    required String category,
    required String suggestedFileName,
  }) async {
    _ensureActive();
    _validateSegments(category, suggestedFileName);
    final owner = _scratchFileService;
    final result = owner != null
        ? await owner.copyFileToScratch(
            sourcePath,
            category: category,
            suggestedFileName: suggestedFileName,
          )
        : await _copyFileToFallback(
            sourcePath,
            category: category,
            suggestedFileName: suggestedFileName,
          );
    return _trackResult(
      result,
      suggestedFileName: suggestedFileName,
      sourcePath: sourcePath,
    );
  }

  Future<void> deleteScratchFile(String path) async {
    _ensureActive();
    final normalized = _normalizeAbsolute(path);
    if (!_trackedPaths.contains(normalized)) {
      throw ArgumentError('Only tracked scratch files may be deleted.');
    }
    await _deleteTracked(normalized);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final paths = List<String>.from(_trackedPaths);
    await Future.wait<void>(paths.map((path) async {
      try {
        await _deleteTracked(path);
      } on Object {
        // Scratch cleanup is best-effort during owner disposal.
      }
    }));
    _trackedPaths.clear();
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('Scratch file manager has been disposed.');
    }
  }

  static void _validateSegments(String category, String suggestedFileName) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$').hasMatch(category)) {
      throw ArgumentError('Scratch category must be a safe path segment.');
    }
    _validateBasename(suggestedFileName);
  }

  static void _validateBasename(String basename) {
    if (basename.isEmpty ||
        basename == '.' ||
        basename == '..' ||
        RegExp(r'[/\\:\x00-\x1F\x7F]').hasMatch(basename) ||
        p.basename(basename) != basename) {
      throw ArgumentError(
        'Scratch filename must be a safe basename without path separators.',
      );
    }
  }

  String _trackResult(
    String result, {
    required String suggestedFileName,
    String? sourcePath,
  }) {
    final normalized = _normalizeAbsolute(result);
    final resultBasename = p.basename(normalized);
    _validateBasename(resultBasename);
    if (p.extension(resultBasename) != p.extension(suggestedFileName)) {
      throw StateError('Scratch owner changed the suggested extension.');
    }
    final durationMarker = RegExp(r'__dur\d+').firstMatch(suggestedFileName);
    if (durationMarker != null) {
      final encodedSuffix = suggestedFileName.substring(durationMarker.start);
      if (!resultBasename.endsWith(encodedSuffix)) {
        throw StateError('Scratch owner changed encoded filename metadata.');
      }
    }
    if (sourcePath != null) {
      final normalizedSource = _normalizeAbsolute(
        File(sourcePath).absolute.path,
      );
      if (p.equals(normalized, normalizedSource)) {
        throw StateError('Scratch owner returned the source file.');
      }
    }
    if (!File(normalized).existsSync()) {
      throw StateError('Scratch owner did not create the requested file.');
    }
    _trackedPaths.add(normalized);
    return normalized;
  }

  static String _normalizeAbsolute(String path) {
    if (path.isEmpty || !p.isAbsolute(path)) {
      throw ArgumentError('Scratch paths must be non-empty and absolute.');
    }
    return p.normalize(path);
  }

  Future<Directory> _createFallbackItemDirectory(String category) async {
    final categoryDirectory = Directory(p.join(_fallbackRoot, category));
    await categoryDirectory.create(recursive: true);
    return categoryDirectory.createTemp('item_');
  }

  Future<String> _writeBytesToFallback(
    Uint8List bytes, {
    required String category,
    required String suggestedFileName,
  }) async {
    final itemDirectory = await _createFallbackItemDirectory(category);
    final target = p.join(itemDirectory.path, suggestedFileName);
    try {
      await File(target).writeAsBytes(bytes, flush: true);
      return target;
    } on Object {
      await _deleteDirectoryBestEffort(itemDirectory);
      rethrow;
    }
  }

  Future<String> _copyFileToFallback(
    String sourcePath, {
    required String category,
    required String suggestedFileName,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const FileSystemException('Scratch source file does not exist.');
    }
    final itemDirectory = await _createFallbackItemDirectory(category);
    final target = p.join(itemDirectory.path, suggestedFileName);
    try {
      await source.copy(target);
      return target;
    } on Object {
      await _deleteDirectoryBestEffort(itemDirectory);
      rethrow;
    }
  }

  Future<void> _deleteTracked(String normalizedPath) {
    final pending = _pendingDeletes[normalizedPath];
    if (pending != null) return pending;

    late final Future<void> operation;
    operation = _performDelete(normalizedPath).then((_) {
      _trackedPaths.remove(normalizedPath);
    }).whenComplete(() {
      if (identical(_pendingDeletes[normalizedPath], operation)) {
        _pendingDeletes.remove(normalizedPath);
      }
    });
    _pendingDeletes[normalizedPath] = operation;
    return operation;
  }

  Future<void> _performDelete(String normalizedPath) async {
    final owner = _scratchFileService;
    if (owner != null) {
      await owner.deleteScratchFile(normalizedPath);
      if (await File(normalizedPath).exists()) {
        throw StateError('Scratch owner did not delete the requested file.');
      }
      return;
    }

    final root = p.normalize(_fallbackRoot);
    if (!p.isWithin(root, normalizedPath)) {
      throw StateError('Fallback scratch path escaped its owned directory.');
    }
    final file = File(normalizedPath);
    if (await file.exists()) await file.delete();
    final itemDirectory = Directory(p.dirname(normalizedPath));
    if (p.isWithin(root, itemDirectory.path)) {
      await _deleteDirectoryBestEffort(itemDirectory);
    }
  }

  static Future<void> _deleteDirectoryBestEffort(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete();
    } on FileSystemException {
      // Leave non-empty or concurrently used directories intact.
    }
  }
}
