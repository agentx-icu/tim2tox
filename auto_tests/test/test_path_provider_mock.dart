/// Mock path_provider for testing
///
/// Provides mock implementations of path_provider functions
/// to avoid plugin dependency in test environment.
///
/// PID-namespacing: every returned directory lives under
/// `${TMPDIR}/tim2tox_tests/pid-$pid/...`. Without this, multiple parallel
/// `flutter test` processes (PARALLEL_WORKERS>1 in run_tests_ordered.sh)
/// all map `getApplicationSupportDirectory()` to the same on-disk path
/// and corrupt each other's persisted state — Tim2Tox writes
/// `chat_history_instance_<id>/` keyed by instance_id which each process
/// re-assigns from 1, so two parallel processes collide at
/// `chat_history_instance_1/`. Keep this in sync with
/// `setupTestEnvironment` in `test_fixtures.dart`, which carries the same
/// namespace fix.

import 'dart:io';
import 'package:path/path.dart' as path;

String _testDataRoot() =>
    path.join(Directory.systemTemp.path, 'tim2tox_tests', 'pid-$pid');

Future<Directory> _ensure(String subdir) async {
  final dir = Directory(path.join(_testDataRoot(), subdir));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Mock getApplicationDocumentsDirectory
Future<Directory> getApplicationDocumentsDirectory() => _ensure('app_documents');

/// Mock getApplicationSupportDirectory
Future<Directory> getApplicationSupportDirectory() => _ensure('app_support');

/// Mock getApplicationCacheDirectory
Future<Directory> getApplicationCacheDirectory() => _ensure('app_cache');

/// Mock getTemporaryDirectory
Future<Directory> getTemporaryDirectory() => _ensure('temp');
