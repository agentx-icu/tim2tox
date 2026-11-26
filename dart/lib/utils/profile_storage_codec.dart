import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A protected file was opened without its profile key, or failed authentication.
/// Callers must preserve it rather than treating it as empty or ordinary JSON.
final class ProfileStorageException implements Exception {
  const ProfileStorageException(this.message);
  final String message;

  @override
  String toString() => 'ProfileStorageException: $message';
}

/// File framing for an authenticated cipher bound to one native profile session.
/// The key stays in native memory. The record kind is authenticated separately
/// so an archive record cannot be moved into a history or queue snapshot.
final class ProfileStorageCodec {
  const ProfileStorageCodec(this._crypt);
  final Uint8List Function(int kind, bool seal, Uint8List bytes) _crypt;

  static const int history = 1;
  static const int archive = 2;
  static const int queue = 3;

  // The version guard in older Tim2Tox refuses to load or replace this
  // snapshot. Older queue readers reject the non-list envelope fields.
  static const _snapshotPrefix = '{"version":2147483647,"_tim2toxEncrypted":';
  static const archiveHeader = '!tim2tox-archive-v1';
  static const _recordPrefix = '!tim2tox-record-v1:';

  static bool isProtectedSnapshot(String raw) =>
      raw.startsWith(_snapshotPrefix);

  String sealSnapshot(int kind, String payload) =>
      '$_snapshotPrefix"${_seal(kind, payload)}"}';

  String sealArchiveLine(String payload) =>
      '$_recordPrefix${_seal(archive, payload)}';

  String _seal(int kind, String payload) =>
      base64Encode(_crypt(kind, true, utf8.encode(payload)));

  static String openSnapshot(int kind, String raw, ProfileStorageCodec? codec) {
    if (!isProtectedSnapshot(raw)) return raw;
    if (codec == null) {
      throw const ProfileStorageException('this file requires its profile key');
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return codec._open(kind, decoded['_tim2toxEncrypted'] as String);
    } on FormatException {
      throw const ProfileStorageException('invalid encrypted snapshot');
    } on TypeError {
      throw const ProfileStorageException('invalid encrypted snapshot');
    }
  }

  static String openArchiveLine(String raw, ProfileStorageCodec? codec) {
    if (!raw.startsWith(_recordPrefix)) return raw;
    if (codec == null) {
      throw const ProfileStorageException(
          'this archive requires its profile key');
    }
    return codec._open(archive, raw.substring(_recordPrefix.length));
  }

  String _open(int kind, String encoded) {
    try {
      return utf8.decode(_crypt(kind, false, base64Decode(encoded)));
    } on FormatException {
      throw const ProfileStorageException('invalid encrypted data');
    }
  }

  /// Encrypt an existing snapshot without interpreting its inner schema. A
  /// malformed or newer legacy snapshot stays recoverable under the same name.
  Future<void> migrateSnapshot(File file, int kind) async {
    if (!await file.exists()) return;
    final raw = await file.readAsString();
    if (isProtectedSnapshot(raw)) {
      openSnapshot(kind, raw, this); // verify before allowing further writes
      return;
    }
    await _replace(file, (out) => out.writeString(sealSnapshot(kind, raw)));
  }

  /// Protect a primary and its backup as independent atomic writes. An
  /// authenticated alternate can recover a damaged snapshot. A plaintext
  /// alternate alone cannot establish that the supplied key is correct.
  Future<void> migrateSnapshotPair(File primary, File backup, int kind) async {
    final snapshots = [primary, backup];
    final locked = <File, ProfileStorageException>{};
    String? authenticated;
    for (final snapshot in snapshots) {
      if (!await snapshot.exists()) continue;
      final raw = await snapshot.readAsString();
      if (!isProtectedSnapshot(raw)) continue;
      try {
        openSnapshot(kind, raw, this);
        authenticated = raw;
      } on ProfileStorageException catch (error) {
        locked[snapshot] = error;
      }
    }
    if (locked.isNotEmpty && authenticated == null) throw locked.values.first;
    for (final snapshot in snapshots) {
      if (locked.containsKey(snapshot)) {
        await _replace(snapshot, (out) => out.writeString(authenticated!));
      } else {
        await migrateSnapshot(snapshot, kind);
      }
    }
  }

  static Stream<String> archiveLines(File file, ProfileStorageCodec? codec,
      {bool tolerateDamagedRecords = false}) async* {
    await for (final raw in file.openRead().transform(utf8.decoder).transform(
          const LineSplitter(),
        )) {
      if (raw == archiveHeader) {
        if (codec == null) {
          throw const ProfileStorageException(
              'this archive requires its profile key');
        }
        continue;
      }
      try {
        yield openArchiveLine(raw, codec);
      } on ProfileStorageException {
        if (!tolerateDamagedRecords || codec == null) rethrow;
        // An interrupted append can tear this record; the next complete line
        // still decrypts independently. Rewrites use the strict default.
      }
    }
  }

  static Future<bool> isProtectedArchive(File file) async {
    if (!await file.exists()) return false;
    final reader = await file.open();
    try {
      final prefix = utf8.encode('$archiveHeader\n');
      final contents = await reader.read(prefix.length);
      if (contents.length != prefix.length) return false;
      for (var i = 0; i < prefix.length; i++) {
        if (contents[i] != prefix[i]) return false;
      }
      return true;
    } finally {
      await reader.close();
    }
  }

  Future<void> migrateArchive(File file) async {
    if (!await file.exists() || await isProtectedArchive(file)) return;
    await _replace(file, (out) async {
      await out.writeString('$archiveHeader\n');
      await for (final line in archiveLines(file, this)) {
        if (line.isNotEmpty)
          await out.writeString('${sealArchiveLine(line)}\n');
      }
    });
  }

  static Future<void> _replace(
    File file,
    Future<void> Function(RandomAccessFile) write,
  ) async {
    final staging = File('${file.path}.encrypting');
    try {
      final raf = await staging.open(mode: FileMode.write);
      try {
        await write(raf);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await staging.rename(file.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }
}
