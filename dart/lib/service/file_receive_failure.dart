import 'dart:io';

import 'package:path/path.dart' as p;

/// Why an incoming file could not be received (checklist M5).
enum FileReceiveFailureReason {
  /// The device (or the user's quota) is out of storage.
  noSpace,

  /// Any other local I/O failure while writing or finalizing the file.
  io,
}

/// A receive that failed locally, for the app to tell the user about.
///
/// Published on `FfiChatService.fileReceiveFailures` for: a native write
/// failure mid-transfer (`file_recv_failed:` event), a refused accept because
/// the file cannot fit (`file_control` code -7), and a failed finalization
/// (moving the completed file to its destination).
class FileReceiveFailure {
  const FileReceiveFailure({
    required this.peerId,
    required this.reason,
    this.fileName,
    this.fileSize,
    this.msgID,
  });

  final String peerId;
  final FileReceiveFailureReason reason;
  final String? fileName;
  final int? fileSize;
  final String? msgID;

  @override
  String toString() =>
      'FileReceiveFailure(reason: ${reason.name}, hasName: ${fileName != null})';
}

/// `file_control` failed with a native result code (see
/// `Tim2ToxFfi.fileControlErrorMessage`). Keeps the code so callers can
/// branch on it (e.g. -7 = not enough storage) instead of matching text;
/// [toString] is unchanged from the plain `Exception(message)` it replaces.
class FileControlException implements Exception {
  const FileControlException(this.code, this.message);

  /// Native `tim2tox_ffi_file_control` result (<= 0).
  final int code;
  final String message;

  /// Not enough storage for the incoming file (native code -7).
  static const int insufficientStorage = -7;

  /// Local receive file could not be created (native code -5).
  static const int localOpenFailed = -5;

  bool get isInsufficientStorage => code == insufficientStorage;

  /// The user-facing reason when this accept failure is a LOCAL storage
  /// problem (-7 full, -5 could not create the file); null for protocol /
  /// peer errors (unknown transfer, friend gone, ...), which are not the
  /// user's storage to fix.
  FileReceiveFailureReason? get receiveFailureReason => switch (code) {
        insufficientStorage => FileReceiveFailureReason.noSpace,
        localOpenFailed => FileReceiveFailureReason.io,
        _ => null,
      };

  @override
  String toString() => 'Exception: $message';
}

/// A parsed `file_recv_failed:<instance_id>:<sender_hex>:<file_number>:<reason>`
/// native event, or null when [line] is not a well-formed one.
({int instanceId, String uid, int fileNumber, FileReceiveFailureReason reason})?
    parseFileRecvFailedEvent(String line) {
  const prefix = 'file_recv_failed:';
  if (!line.startsWith(prefix)) return null;
  final parts = line.substring(prefix.length).split(':');
  if (parts.length != 4) return null;
  final instanceId = int.tryParse(parts[0]);
  final fileNumber = int.tryParse(parts[2]);
  if (instanceId == null || fileNumber == null || parts[1].isEmpty) {
    return null;
  }
  return (
    instanceId: instanceId,
    uid: parts[1],
    fileNumber: fileNumber,
    reason: parts[3] == 'no_space'
        ? FileReceiveFailureReason.noSpace
        : FileReceiveFailureReason.io,
  );
}

/// errno values meaning "storage full": ENOSPC (28 on Linux, Android, macOS,
/// iOS), EDQUOT (122 Linux/Android, 69 Apple), and Windows ERROR_DISK_FULL
/// (112) / ERROR_HANDLE_DISK_FULL (39).
bool isNoSpaceError(Object error) {
  if (error is! FileSystemException) return false;
  final code = error.osError?.errorCode;
  if (code == null) return false;
  if (Platform.isWindows) return code == 112 || code == 39;
  if (code == 28) return true;
  return Platform.isMacOS || Platform.isIOS ? code == 69 : code == 122;
}

/// The native "not finalized yet" sidecar of a received file
/// (`<dir>/.<basename>.t2t-receiving`, created by `tim2tox_ffi_file_control`
/// on accept; must match `file_io::ReceiveMarkerPath`). Dart removes it once
/// the completed file is finalized; a leftover one is swept natively at the
/// next session start.
String receiveMarkerPathFor(String nativePath) =>
    p.join(p.dirname(nativePath), '.${p.basename(nativePath)}.t2t-receiving');

/// Moves a completed receive [source] into [destDir] as [fileName] — or
/// `name_1.ext`, `name_2.ext`, … when taken — and returns the final path
/// (checklist M5).
///
/// * The destination name is reserved atomically (`create(exclusive: true)`),
///   so two same-name completions never pick the same file.
/// * With [moveSource], a same-volume `rename` is tried first: atomic and it
///   needs no second copy of a large file on a nearly full disk.
/// * Otherwise (other volume, or the source must stay), the bytes are copied
///   into a unique `<dest>.<uniqueTag>.toxee-part` stage and renamed into
///   place, so a failed copy never leaves a truncated file under the real name.
/// * On failure every stage/reservation this call created is deleted, the
///   source is left untouched, and the error is rethrown.
Future<String> finalizeReceivedFile({
  required String source,
  required String destDir,
  required String fileName,
  required String uniqueTag,
  required bool moveSource,
  Future<void> Function(String from, String to)? copy,
}) async {
  final doCopy = copy ?? (from, to) async => File(from).copy(to);
  await Directory(destDir).create(recursive: true);
  final base = p.basenameWithoutExtension(fileName);
  final ext = p.extension(fileName);
  String? reserved;
  for (var i = 0; i < 10000 && reserved == null; i++) {
    final candidate = p.join(destDir, i == 0 ? fileName : '${base}_$i$ext');
    try {
      await File(candidate).create(exclusive: true);
      reserved = candidate;
    } on FileSystemException {
      if (await File(candidate).exists()) continue;
      rethrow; // not "already exists": e.g. the disk is full
    }
  }
  if (reserved == null) {
    throw FileSystemException('no free destination name', p.join(destDir, fileName));
  }
  final dest = reserved;

  Future<void> placeOnto(String from) async {
    // POSIX rename replaces the empty reservation atomically; Windows refuses
    // to rename onto an existing file, so drop the reservation first there.
    if (Platform.isWindows) await File(dest).delete();
    await File(from).rename(dest);
  }

  if (moveSource) {
    try {
      await placeOnto(source);
      return dest;
    } on FileSystemException {
      // Different volume (EXDEV) or similar: fall back to a staged copy.
      if (Platform.isWindows && !await File(dest).exists()) {
        await File(dest).create(exclusive: true);
      }
    }
  }
  final stage = '$dest.$uniqueTag.toxee-part';
  try {
    await doCopy(source, stage);
    await placeOnto(stage);
  } catch (_) {
    for (final leftover in [stage, dest]) {
      try {
        final f = File(leftover);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    rethrow;
  }
  if (moveSource) {
    try {
      await File(source).delete();
    } catch (_) {}
  }
  return dest;
}
