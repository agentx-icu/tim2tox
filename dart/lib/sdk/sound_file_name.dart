import 'package:path/path.dart' as p;

String soundFileNameForPath(
  String filePath, {
  required int durationMs,
}) {
  if (filePath.isEmpty || filePath.endsWith('/') || filePath.endsWith(r'\')) {
    throw ArgumentError('Sound path must end with a filename.');
  }
  final basename = filePath.contains(r'\')
      ? p.windows.basename(filePath)
      : p.basename(filePath);
  if (basename.isEmpty ||
      basename == '.' ||
      basename == '..' ||
      basename.contains('/') ||
      basename.contains(r'\')) {
    throw ArgumentError('Sound path must resolve to a safe basename.');
  }
  if (durationMs <= 0) return basename;

  final dotIndex = basename.lastIndexOf('.');
  final stem = dotIndex > 0 ? basename.substring(0, dotIndex) : basename;
  final extension = dotIndex > 0 ? basename.substring(dotIndex) : '';
  return '${stem}__dur$durationMs$extension';
}
