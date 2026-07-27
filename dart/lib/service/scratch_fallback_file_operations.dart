import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

abstract interface class ScratchFallbackFileOperations {
  Future<void> writeBytes(File destination, Uint8List bytes);

  Future<void> copyFile(File source, File destination);
}

typedef ScratchFallbackStagingNameBuilder = String Function(
  Directory itemDirectory,
  int attempt,
);

final class ScratchFallbackStagingFileReserver {
  ScratchFallbackStagingFileReserver({
    ScratchFallbackStagingNameBuilder? nameBuilder,
  }) : _nameBuilder = nameBuilder ?? _defaultNameBuilder;

  static int _nextSequence = 0;
  static const int _maxAttempts = 32;

  final ScratchFallbackStagingNameBuilder _nameBuilder;

  Future<File> reserve(Directory itemDirectory) async {
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final name = _nameBuilder(itemDirectory, attempt);
      if (name.isEmpty ||
          name == '.' ||
          name == '..' ||
          p.basename(name) != name ||
          RegExp(r'[/\\:\x00-\x1F\x7F]').hasMatch(name)) {
        throw StateError('Fallback staging name must be a safe basename.');
      }
      final candidate = File(p.join(itemDirectory.path, name));
      try {
        await candidate.create(exclusive: true);
      } on FileSystemException {
        final collisionType = await FileSystemEntity.type(
          candidate.path,
          followLinks: false,
        );
        if (collisionType != FileSystemEntityType.notFound) continue;
        rethrow;
      }
      final type = await FileSystemEntity.type(
        candidate.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.file) {
        await _deleteReservedEntityBestEffort(candidate.path);
        throw StateError('Reserved fallback staging path is not a file.');
      }
      return candidate;
    }
    throw StateError('Could not reserve a unique fallback staging file.');
  }

  static String _defaultNameBuilder(Directory _, int attempt) {
    final sequence = _nextSequence++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return '.tim2tox_staging_${timestamp}_${sequence}_$attempt';
  }

  static Future<void> _deleteReservedEntityBestEffort(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        await File(path).delete();
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      }
    } on FileSystemException {
      // Reservation failure remains the primary error.
    }
  }
}
