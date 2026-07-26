import 'dart:typed_data';

/// Host-owned storage for short-lived files created by Tim2Tox helpers.
///
/// Implementations must return an absolute path with a safe basename. They may
/// sanitize the suggested stem, but must preserve its extension and any
/// `__dur{milliseconds}` suffix. Concurrent calls must own independent files;
/// use unique parent directories when suggested basenames collide. Tim2Tox
/// calls [deleteScratchFile] for every path that a successful write or copy
/// returns, including during service disposal.
abstract interface class ScratchFileService {
  Future<String> writeBytesToScratch(
    Uint8List bytes, {
    required String category,
    required String suggestedFileName,
  });

  Future<String> copyFileToScratch(
    String sourcePath, {
    required String category,
    required String suggestedFileName,
  });

  Future<void> deleteScratchFile(String path);
}
