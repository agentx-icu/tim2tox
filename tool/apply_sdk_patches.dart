// Apply tencent_cloud_chat_sdk patch series to a vendored SDK directory.
// Run from tim2tox repo root: dart run tool/apply_sdk_patches.dart --sdk-dir=<path>
// Or from any dir: dart run /path/to/tim2tox/tool/apply_sdk_patches.dart --sdk-dir=<path> (tim2tox root = dir containing tool/ and patches/)
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  String? sdkDir;
  for (final a in args) {
    if (a.startsWith('--sdk-dir=')) {
      sdkDir = a.substring('--sdk-dir='.length);
      break;
    }
  }
  if (sdkDir == null || sdkDir.isEmpty) {
    stderr.writeln('Usage: dart run tool/apply_sdk_patches.dart --sdk-dir=<path>');
    exit(1);
  }
  final sdk = Directory(sdkDir);
  if (!sdk.existsSync()) {
    stderr.writeln('apply_sdk_patches: SDK dir not found: $sdkDir');
    exit(1);
  }

  final tim2toxRoot = _findTim2toxRoot();
  final lockFile = File('$tim2toxRoot/tool/tencent_cloud_chat_sdk.lock.json');
  if (!lockFile.existsSync()) {
    stderr.writeln('apply_sdk_patches: lock file not found: $lockFile');
    exit(1);
  }
  final lock = jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
  final version = lock['version'] as String? ?? '';
  if (version.isEmpty) {
    stderr.writeln('apply_sdk_patches: lock file must have version');
    exit(1);
  }

  final patchesDir = Directory('$tim2toxRoot/patches/tencent_cloud_chat_sdk/$version');
  final seriesFile = File('${patchesDir.path}/series');
  if (!seriesFile.existsSync()) {
    stdout.writeln('No series file at ${patchesDir.path}/series; skipping patches.');
    exit(0);
  }
  final lines = seriesFile.readAsLinesSync().map((s) => s.trim()).where((s) => s.isNotEmpty && !s.startsWith('#')).toList();
  if (lines.isEmpty) {
    exit(0);
  }

  // Initialize a git repo in the SDK dir so git apply works.
  // git apply requires a git repository context.
  if (!Directory('${sdk.path}/.git').existsSync()) {
    stdout.writeln('Initializing git repo in SDK dir for patching...');
    int c = await _run(sdk.path, 'git', ['init']);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: git init failed');
      exit(1);
    }
    // Configure line endings to preserve LF
    await _run(sdk.path, 'git', ['config', 'core.autocrlf', 'false']);
    await _run(sdk.path, 'git', ['config', 'core.eol', 'lf']);
    // Normalize SDK file line endings to LF before staging (Windows CI fix)
    _normalizeSdkLineEndings(sdk);
    // Stage all files so git apply can work
    c = await _run(sdk.path, 'git', ['add', '-A']);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: git add failed');
      exit(1);
    }
    // Plant a baseline commit + tag so refresh_sdk_patch.sh can diff against
    // the pre-patch SDK state without needing HEAD ancestry math.
    c = await _run(sdk.path, 'git', ['config', 'user.name', 'tim2tox-bootstrap']);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: git config user.name failed');
      exit(1);
    }
    c = await _run(sdk.path, 'git', ['config', 'user.email', 'bootstrap@local']);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: git config user.email failed');
      exit(1);
    }
    c = await _run(sdk.path, 'git', ['commit', '-m', 'baseline $version']);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: git commit (baseline) failed');
      exit(1);
    }
    c = await _run(sdk.path, 'git', ['tag', 'baseline']);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: git tag baseline failed');
      exit(1);
    }
  }

  for (final name in lines) {
    final patchFile = File('${patchesDir.path}/$name');
    if (!patchFile.existsSync()) {
      stderr.writeln('apply_sdk_patches: patch file missing: ${patchesDir.path}/$name');
      exit(1);
    }
    stdout.writeln('Applying SDK patch: $name');
    int c = await _run(sdk.path, 'git', ['apply', '--check', '-p1', patchFile.path]);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: patch would not apply: $name');
      exit(1);
    }
    c = await _run(sdk.path, 'git', ['apply', '-p1', patchFile.path]);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: failed to apply patch: $name');
      exit(1);
    }
    // Commit the applied patch so `git format-patch baseline..HEAD` can
    // regenerate the split series later.
    c = await _run(sdk.path, 'git', ['add', '-A']);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: git add after $name failed');
      exit(1);
    }
    final commitMsg = name.endsWith('.patch') ? name.substring(0, name.length - '.patch'.length) : name;
    c = await _run(sdk.path, 'git', ['commit', '-m', commitMsg]);
    if (c != 0) {
      stderr.writeln('apply_sdk_patches: git commit for $name failed');
      exit(1);
    }
  }
  stdout.writeln('All patches applied.');
}

String _findTim2toxRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/tool/tencent_cloud_chat_sdk.lock.json').existsSync() && Directory('${dir.path}/patches').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln('apply_sdk_patches: run from tim2tox repo root or pass cwd so tool/ and patches/ are found');
      exit(1);
    }
    dir = parent;
  }
}

Future<int> _run(String cwd, String executable, List<String> args) async {
  final r = await Process.run(executable, args, workingDirectory: cwd, runInShell: false);
  if (r.stdout.toString().trim().isNotEmpty) stdout.write(r.stdout);
  if (r.stderr.toString().trim().isNotEmpty) stderr.write(r.stderr);
  return r.exitCode;
}

void _normalizeSdkLineEndings(Directory sdkDir) {
  const textExtensions = {
    '.dart',
    '.yaml',
    '.yml',
    '.json',
    '.xml',
    '.gradle',
    '.kts',
    '.java',
    '.kt',
    '.m',
    '.mm',
    '.swift',
    '.h',
    '.hpp',
    '.c',
    '.cc',
    '.cpp',
    '.txt',
    '.md',
  };

  for (final entity in sdkDir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final lowerPath = entity.path.toLowerCase();
    if (!textExtensions.any(lowerPath.endsWith)) continue;

    final contents = entity.readAsStringSync();
    final normalized = contents.replaceAll('\r\n', '\n');
    if (contents != normalized) {
      entity.writeAsStringSync(normalized);
    }
  }
}
