import 'dart:convert';
import 'dart:io';

/// A downgrade must never turn unsupported data into an empty conversation.
class HistorySchemaNewerThanAppException implements Exception {
  const HistorySchemaNewerThanAppException(this.version, this.supportedVersion);
  final int version;
  final int supportedVersion;
  @override
  String toString() => 'Message history requires a newer app '
      '(stored: $version, supported: $supportedVersion). Update to continue.';
}

Future<void> requireSupportedHistorySchema(File file, int supported) async {
  if (!await file.exists()) return;
  dynamic decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } on FormatException {
    // Ordinary corrupt-file recovery still belongs to the history store.
    return;
  }
  if (decoded is Map) {
    final version = decoded['version'];
    if (version is int && version > supported) {
      throw HistorySchemaNewerThanAppException(version, supported);
    }
  }
}
