import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../interfaces/scratch_file_service.dart';
import 'scratch_fallback_file_operations.dart';

export 'scratch_fallback_file_operations.dart'
    show
        ScratchFallbackFileOperations,
        ScratchFallbackStagingFileReserver,
        ScratchFallbackStagingNameBuilder;

final class _LocalScratchFallbackFileOperations
    implements ScratchFallbackFileOperations {
  const _LocalScratchFallbackFileOperations();

  @override
  Future<void> writeBytes(File destination, Uint8List bytes) async {
    final output = await destination.open(mode: FileMode.writeOnly);
    try {
      await output.writeFrom(bytes);
      await output.flush();
    } finally {
      await output.close();
    }
  }

  @override
  Future<void> copyFile(File source, File destination) async {
    final input = await source.open();
    try {
      final output = await destination.open(mode: FileMode.writeOnly);
      try {
        while (true) {
          final chunk = await input.read(64 * 1024);
          if (chunk.isEmpty) break;
          await output.writeFrom(chunk);
        }
        await output.flush();
      } finally {
        await output.close();
      }
    } finally {
      await input.close();
    }
  }
}

/// Validates and tracks scratch files created for Tim2Tox helper operations.
///
/// Without an injected owner, files are isolated below the exact fallback
/// `Directory.systemTemp/toxee_tim2tox_scratch`. Only paths returned by this
/// manager can be deleted through it.
final class ScratchFileManager {
  ScratchFileManager({
    ScratchFileService? scratchFileService,
    Directory? fallbackRootDirectory,
    ScratchFallbackFileOperations? fallbackOperations,
    ScratchFallbackStagingFileReserver? fallbackStagingFileReserver,
  })  : _scratchFileService = scratchFileService,
        _fallbackRootDirectory = fallbackRootDirectory ??
            Directory(
              p.join(Directory.systemTemp.path, fallbackDirectoryName),
            ),
        _fallbackOperations =
            fallbackOperations ?? const _LocalScratchFallbackFileOperations(),
        _fallbackStagingFileReserver =
            fallbackStagingFileReserver ?? ScratchFallbackStagingFileReserver();

  static const String fallbackDirectoryName = 'toxee_tim2tox_scratch';

  ScratchFileService? _scratchFileService;
  final Directory _fallbackRootDirectory;
  final ScratchFallbackFileOperations _fallbackOperations;
  final ScratchFallbackStagingFileReserver _fallbackStagingFileReserver;
  final Set<String> _trackedPaths = <String>{};
  final Map<String, Future<void>> _pendingDeletes = <String, Future<void>>{};
  bool _scratchOperationStarted = false;
  bool _disposed = false;
  String? _canonicalFallbackRoot;

  /// Installs a host owner for account services created before account paths
  /// were available. Constructor injection remains preferred.
  void installScratchFileService(ScratchFileService service) {
    _ensureActive();
    if (_scratchOperationStarted) {
      throw StateError(
        'Scratch owner cannot be installed after scratch use has started.',
      );
    }
    final current = _scratchFileService;
    if (current != null) {
      if (identical(current, service)) return;
      throw StateError('A different scratch owner is already installed.');
    }
    _scratchFileService = service;
  }

  Future<String> writeBytesToScratch(
    Uint8List bytes, {
    required String category,
    required String suggestedFileName,
  }) async {
    _beginScratchOperation();
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
    _beginScratchOperation();
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
    _beginScratchOperation();
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

  void _beginScratchOperation() {
    _ensureActive();
    _scratchOperationStarted = true;
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
      final normalizedSource =
          _normalizeAbsolute(File(sourcePath).absolute.path);
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
    final rootParent = _fallbackRootDirectory.parent;
    final canonicalParent =
        p.normalize(await rootParent.resolveSymbolicLinks());
    final canonicalRoot = await _ensureOwnedDirectory(
      _fallbackRootDirectory,
      canonicalParent: canonicalParent,
    );
    _canonicalFallbackRoot = canonicalRoot;
    final categoryDirectory = Directory(p.join(canonicalRoot, category));
    final canonicalCategory = await _ensureOwnedDirectory(
      categoryDirectory,
      canonicalParent: canonicalRoot,
    );

    // Both directories were resolved and containment-proven before this call.
    final itemDirectory =
        await Directory(canonicalCategory).createTemp('item_');
    final itemType = await FileSystemEntity.type(
      itemDirectory.path,
      followLinks: false,
    );
    if (itemType != FileSystemEntityType.directory) {
      throw StateError('Fallback scratch item is not a real directory.');
    }
    final canonicalItem = p.normalize(
      await itemDirectory.resolveSymbolicLinks(),
    );
    if (!p.isWithin(canonicalCategory, canonicalItem)) {
      await _deleteDirectoryBestEffort(itemDirectory);
      throw StateError('Fallback scratch item escaped its category.');
    }
    return Directory(canonicalItem);
  }

  static Future<String> _ensureOwnedDirectory(
    Directory directory, {
    required String canonicalParent,
  }) async {
    final typeBefore = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (typeBefore == FileSystemEntityType.link) {
      throw StateError('Fallback scratch directory must not be a symlink.');
    }
    if (typeBefore == FileSystemEntityType.notFound) {
      await directory.create();
    } else if (typeBefore != FileSystemEntityType.directory) {
      throw StateError('Fallback scratch path must be a directory.');
    }

    final typeAfter = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (typeAfter != FileSystemEntityType.directory) {
      throw StateError('Fallback scratch directory changed unexpectedly.');
    }
    final canonicalDirectory = p.normalize(
      await directory.resolveSymbolicLinks(),
    );
    if (!p.isWithin(canonicalParent, canonicalDirectory) ||
        !p.equals(p.dirname(canonicalDirectory), canonicalParent)) {
      throw StateError('Fallback scratch directory escaped its parent.');
    }
    return canonicalDirectory;
  }

  Future<String> _writeBytesToFallback(
    Uint8List bytes, {
    required String category,
    required String suggestedFileName,
  }) async {
    final itemDirectory = await _createFallbackItemDirectory(category);
    return _stageAndCommitFallbackFile(
      itemDirectory,
      suggestedFileName,
      (staging) => _fallbackOperations.writeBytes(staging, bytes),
    );
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
    return _stageAndCommitFallbackFile(
      itemDirectory,
      suggestedFileName,
      (staging) => _fallbackOperations.copyFile(source, staging),
    );
  }

  Future<String> _stageAndCommitFallbackFile(
    Directory itemDirectory,
    String suggestedFileName,
    Future<void> Function(File staging) populate,
  ) async {
    File? staging;
    final target = File(p.join(itemDirectory.path, suggestedFileName));
    try {
      staging = await _fallbackStagingFileReserver.reserve(itemDirectory);
      await populate(staging);
      final stagingType = await FileSystemEntity.type(
        staging.path,
        followLinks: false,
      );
      if (stagingType != FileSystemEntityType.file) {
        throw StateError('Fallback staging path is not a regular file.');
      }
      await staging.rename(target.path);
      return target.path;
    } on Object {
      if (staging != null) {
        await _deleteEntityBestEffort(staging.path);
      }
      await _deleteEntityBestEffort(target.path);
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

    final root = _canonicalFallbackRoot;
    if (root == null) {
      throw StateError('Fallback scratch root was not initialized.');
    }
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

  static Future<void> _deleteEntityBestEffort(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        await File(path).delete();
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      }
    } on FileSystemException {
      // Failure cleanup must not mask the original write/copy error.
    }
  }
}
