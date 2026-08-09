import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:tim2tox_dart/sdk/sound_file_name.dart';
import 'package:tim2tox_dart/service/scratch_file_manager.dart';
import 'package:tim2tox_dart/tim2tox_dart.dart';

final class _InterruptingFallbackOperations
    implements ScratchFallbackFileOperations {
  const _InterruptingFallbackOperations();

  @override
  Future<void> writeBytes(File destination, Uint8List bytes) async {
    await destination.writeAsBytes(<int>[1], flush: true);
    throw StateError('interrupted write');
  }

  @override
  Future<void> copyFile(File source, File destination) async {
    final sourceBytes = await source.readAsBytes();
    await destination.writeAsBytes(
      sourceBytes.isEmpty ? <int>[] : <int>[sourceBytes.first],
      flush: true,
    );
    throw StateError('interrupted copy');
  }
}

Future<List<FileSystemEntity>> _materializedEntities(Directory root) async {
  if (!await root.exists()) return <FileSystemEntity>[];
  final entities =
      await root.list(recursive: true, followLinks: false).toList();
  return entities
      .where((entity) => entity is File || entity is Link)
      .toList(growable: false);
}

final class _RecordingScratchFileService implements ScratchFileService {
  _RecordingScratchFileService(this.root, {this.basenameTransform});

  final Directory root;
  final String Function(String)? basenameTransform;
  final List<String> categories = <String>[];
  final List<String> deletedPaths = <String>[];
  int _sequence = 0;
  Object? copyError;

  Future<String> _target(String category, String suggestedFileName) async {
    categories.add(category);
    final directory = Directory(
      path.join(root.path, category, 'item_${_sequence++}'),
    );
    await directory.create(recursive: true);
    return path.join(
      directory.path,
      basenameTransform?.call(suggestedFileName) ?? suggestedFileName,
    );
  }

  @override
  Future<String> writeBytesToScratch(
    Uint8List bytes, {
    required String category,
    required String suggestedFileName,
  }) async {
    final target = await _target(category, suggestedFileName);
    await File(target).writeAsBytes(bytes, flush: true);
    return target;
  }

  @override
  Future<String> copyFileToScratch(
    String sourcePath, {
    required String category,
    required String suggestedFileName,
  }) async {
    final error = copyError;
    if (error != null) throw error;
    final target = await _target(category, suggestedFileName);
    await File(sourcePath).copy(target);
    return target;
  }

  @override
  Future<void> deleteScratchFile(String scratchPath) async {
    deletedPaths.add(scratchPath);
    final file = File(scratchPath);
    if (await file.exists()) await file.delete();
  }
}

FfiChatService _createService(
  Directory root, {
  ScratchFileService? scratchFileService,
}) {
  return FfiChatService(
    historyDirectory: path.join(root.path, 'history'),
    queueFilePath: path.join(root.path, 'offline_queue.json'),
    fileRecvPath: path.join(root.path, 'file_recv'),
    avatarsPath: path.join(root.path, 'avatars'),
    scratchFileService: scratchFileService,
  );
}

void main() {
  group('FfiChatService scratch files', () {
    late Directory testRoot;

    setUp(() async {
      testRoot = await Directory.systemTemp.createTemp('tim2tox_scratch_test_');
    });

    tearDown(() async {
      if (await testRoot.exists()) {
        await testRoot.delete(recursive: true);
      }
    });

    test('uses the injected owner for copy and delete', () async {
      final owner = _RecordingScratchFileService(
        Directory(path.join(testRoot.path, 'owner')),
      );
      final service = _createService(testRoot, scratchFileService: owner);
      final source = File(path.join(testRoot.path, 'recording.m4a'));
      await source.writeAsBytes(<int>[1, 2, 3]);

      final scratchPath = await service.copyFileToScratch(
        source.path,
        category: 'sound_duration',
        suggestedFileName: 'recording__dur1200.m4a',
      );

      expect(scratchPath, startsWith(owner.root.path));
      expect(path.basename(scratchPath), 'recording__dur1200.m4a');
      expect(owner.categories, <String>['sound_duration']);
      expect(await File(scratchPath).readAsBytes(), <int>[1, 2, 3]);

      await service.deleteScratchFile(scratchPath);

      expect(owner.deletedPaths, <String>[scratchPath]);
      expect(await File(scratchPath).exists(), isFalse);
      expect(await source.exists(), isTrue);
      await service.dispose();
    });

    test('supports one late owner install before scratch use', () async {
      final owner = _RecordingScratchFileService(
        Directory(path.join(testRoot.path, 'late_owner')),
      );
      final service = _createService(testRoot);

      service.installScratchFileService(owner);
      final scratchPath = await service.writeBytesToScratch(
        Uint8List.fromList(<int>[3, 4]),
        category: 'sound_duration',
        suggestedFileName: 'late__dur500.wav',
      );

      expect(scratchPath, startsWith(owner.root.path));
      expect(owner.categories, <String>['sound_duration']);
      await service.dispose();
      expect(owner.deletedPaths, <String>[scratchPath]);
    });

    test('rejects replacement and install after scratch start or dispose',
        () async {
      final firstOwner = _RecordingScratchFileService(
        Directory(path.join(testRoot.path, 'first_owner')),
      );
      final differentOwner = _RecordingScratchFileService(
        Directory(path.join(testRoot.path, 'different_owner')),
      );
      final lateInstalled = _createService(testRoot);
      lateInstalled.installScratchFileService(firstOwner);

      expect(
        () => lateInstalled.installScratchFileService(differentOwner),
        throwsStateError,
      );
      final scratchPath = await lateInstalled.writeBytesToScratch(
        Uint8List.fromList(<int>[5]),
        category: 'sound_duration',
        suggestedFileName: 'started.wav',
      );
      expect(
        () => lateInstalled.installScratchFileService(firstOwner),
        throwsStateError,
      );
      await lateInstalled.deleteScratchFile(scratchPath);
      await lateInstalled.dispose();

      final injected = _createService(
        testRoot,
        scratchFileService: firstOwner,
      );
      expect(
        () => injected.installScratchFileService(differentOwner),
        throwsStateError,
      );
      await injected.dispose();

      final fallbackStarted = _createService(testRoot);
      final fallbackPath = await fallbackStarted.writeBytesToScratch(
        Uint8List.fromList(<int>[6]),
        category: 'sound_duration',
        suggestedFileName: 'fallback-started.wav',
      );
      expect(
        () => fallbackStarted.installScratchFileService(firstOwner),
        throwsStateError,
      );
      await fallbackStarted.deleteScratchFile(fallbackPath);
      await fallbackStarted.dispose();

      final disposed = _createService(testRoot);
      await disposed.dispose();
      expect(
        () => disposed.installScratchFileService(firstOwner),
        throwsStateError,
      );
    });

    test('allows a sanitized stem while preserving encoded wire metadata',
        () async {
      final owner = _RecordingScratchFileService(
        Directory(path.join(testRoot.path, 'owner')),
        basenameTransform: (basename) => basename.replaceFirst('语音', 'audio'),
      );
      final service = _createService(testRoot, scratchFileService: owner);
      final source = File(path.join(testRoot.path, 'recording.m4a'));
      await source.writeAsBytes(<int>[1]);

      final scratchPath = await service.copyFileToScratch(
        source.path,
        category: 'sound_duration',
        suggestedFileName: '语音__dur1200.m4a',
      );

      expect(path.basename(scratchPath), 'audio__dur1200.m4a');
      await service.deleteScratchFile(scratchPath);
      await service.dispose();
    });

    test('writes fallback files below the dedicated app-owned temp root',
        () async {
      final service = _createService(testRoot);
      final expectedRoot = Directory(
        path.join(
          Directory.systemTemp.path,
          'toxee_tim2tox_scratch',
        ),
      );

      final scratchPath = await service.writeBytesToScratch(
        Uint8List.fromList(<int>[4, 5, 6]),
        category: 'sound_duration',
        suggestedFileName: 'voice__dur900.ogg',
      );
      final canonicalExpectedRoot = await expectedRoot.resolveSymbolicLinks();

      expect(path.isWithin(canonicalExpectedRoot, scratchPath), isTrue);
      expect(path.basename(scratchPath), 'voice__dur900.ogg');
      expect(await File(scratchPath).readAsBytes(), <int>[4, 5, 6]);

      await service.deleteScratchFile(scratchPath);
      expect(await File(scratchPath).exists(), isFalse);
      await service.dispose();
    });

    test(
      'rejects a symlinked fallback root before creating scratch files',
      () async {
        final realRoot = Directory(path.join(testRoot.path, 'real_root'));
        await realRoot.create();
        final linkedRootPath = path.join(testRoot.path, 'linked_root');
        await Link(linkedRootPath).create(realRoot.path);
        final manager = ScratchFileManager(
          fallbackRootDirectory: Directory(linkedRootPath),
        );

        await expectLater(
          manager.writeBytesToScratch(
            Uint8List.fromList(<int>[1]),
            category: 'sound_duration',
            suggestedFileName: 'blocked.wav',
          ),
          throwsStateError,
        );

        expect(await _materializedEntities(realRoot), isEmpty);
        await manager.dispose();
      },
      skip: Platform.isWindows
          ? 'Creating symlinks requires elevated privileges on Windows.'
          : false,
    );

    test(
      'rejects a symlinked category before creating scratch files',
      () async {
        final root = Directory(path.join(testRoot.path, 'category_root'));
        final outside = Directory(path.join(testRoot.path, 'outside_category'));
        await root.create();
        await outside.create();
        await Link(path.join(root.path, 'sound_duration')).create(outside.path);
        final manager = ScratchFileManager(fallbackRootDirectory: root);

        await expectLater(
          manager.writeBytesToScratch(
            Uint8List.fromList(<int>[1]),
            category: 'sound_duration',
            suggestedFileName: 'blocked.wav',
          ),
          throwsStateError,
        );

        expect(await _materializedEntities(outside), isEmpty);
        await manager.dispose();
      },
      skip: Platform.isWindows
          ? 'Creating symlinks requires elevated privileges on Windows.'
          : false,
    );

    test('interrupted fallback write leaves no final or staging file',
        () async {
      final root = Directory(path.join(testRoot.path, 'failed_write'));
      final manager = ScratchFileManager(
        fallbackRootDirectory: root,
        fallbackOperations: const _InterruptingFallbackOperations(),
      );

      await expectLater(
        manager.writeBytesToScratch(
          Uint8List.fromList(<int>[1, 2, 3]),
          category: 'sound_duration',
          suggestedFileName: 'partial.wav',
        ),
        throwsStateError,
      );

      expect(await _materializedEntities(root), isEmpty);
      await manager.dispose();
    });

    test('interrupted fallback copy leaves no final or staging file', () async {
      final root = Directory(path.join(testRoot.path, 'failed_copy'));
      final source = File(path.join(testRoot.path, 'copy_source.wav'));
      await source.writeAsBytes(<int>[4, 5, 6], flush: true);
      final manager = ScratchFileManager(
        fallbackRootDirectory: root,
        fallbackOperations: const _InterruptingFallbackOperations(),
      );

      await expectLater(
        manager.copyFileToScratch(
          source.path,
          category: 'sound_duration',
          suggestedFileName: 'partial-copy.wav',
        ),
        throwsStateError,
      );

      expect(await _materializedEntities(root), isEmpty);
      expect(await source.readAsBytes(), <int>[4, 5, 6]);
      await manager.dispose();
    });

    test('successful fallback write and copy expose only atomic content',
        () async {
      final root = Directory(path.join(testRoot.path, 'atomic_success'));
      final manager = ScratchFileManager(fallbackRootDirectory: root);
      final source = File(path.join(testRoot.path, 'atomic_source.wav'));
      await source.writeAsBytes(<int>[7, 8, 9], flush: true);

      final written = await manager.writeBytesToScratch(
        Uint8List.fromList(<int>[1, 2, 3]),
        category: 'sound_duration',
        suggestedFileName: 'written.wav',
      );
      final copied = await manager.copyFileToScratch(
        source.path,
        category: 'sound_duration',
        suggestedFileName: 'copied.wav',
      );

      expect(await File(written).readAsBytes(), <int>[1, 2, 3]);
      expect(await File(copied).readAsBytes(), <int>[7, 8, 9]);
      final entities = await _materializedEntities(root);
      expect(
        entities.map((entity) => path.basename(entity.path)),
        containsAll(<String>['written.wav', 'copied.wav']),
      );
      expect(
        entities.any((entity) => entity.path.contains('tim2tox_staging')),
        isFalse,
      );

      await manager.deleteScratchFile(written);
      await manager.deleteScratchFile(copied);
      await manager.dispose();
    });

    test('pre-created staging collision is not shared or overwritten',
        () async {
      final root = Directory(path.join(testRoot.path, 'staging_collision'));
      late File collision;
      final reserver = ScratchFallbackStagingFileReserver(
        nameBuilder: (itemDirectory, attempt) {
          if (attempt == 0) {
            collision = File(
              path.join(itemDirectory.path, '.tim2tox_staging_collision'),
            );
            collision.writeAsBytesSync(<int>[91, 92], flush: true);
            return path.basename(collision.path);
          }
          return '.tim2tox_staging_unique';
        },
      );
      final manager = ScratchFileManager(
        fallbackRootDirectory: root,
        fallbackStagingFileReserver: reserver,
      );

      final result = await manager.writeBytesToScratch(
        Uint8List.fromList(<int>[1, 2, 3]),
        category: 'sound_duration',
        suggestedFileName: 'collision-safe.wav',
      );

      expect(result, isNot(collision.path));
      expect(await collision.readAsBytes(), <int>[91, 92]);
      expect(await File(result).readAsBytes(), <int>[1, 2, 3]);
      await collision.delete();
      await manager.deleteScratchFile(result);
      await manager.dispose();
    });

    test('concurrent fallback operations never share or overwrite staging',
        () async {
      final root = Directory(path.join(testRoot.path, 'concurrent_fallback'));
      final source = File(path.join(testRoot.path, 'concurrent_source.wav'));
      await source.writeAsBytes(<int>[7, 8, 9], flush: true);
      final manager = ScratchFileManager(fallbackRootDirectory: root);

      final results = await Future.wait<String>(<Future<String>>[
        manager.writeBytesToScratch(
          Uint8List.fromList(<int>[1, 2, 3]),
          category: 'sound_duration',
          suggestedFileName: 'shared-name.wav',
        ),
        manager.copyFileToScratch(
          source.path,
          category: 'sound_duration',
          suggestedFileName: 'shared-name.wav',
        ),
      ]);

      expect(results[0], isNot(results[1]));
      expect(path.dirname(results[0]), isNot(path.dirname(results[1])));
      expect(await File(results[0]).readAsBytes(), <int>[1, 2, 3]);
      expect(await File(results[1]).readAsBytes(), <int>[7, 8, 9]);
      expect(
        (await _materializedEntities(root))
            .any((entity) => entity.path.contains('tim2tox_staging')),
        isFalse,
      );

      await Future.wait<void>(
        results.map(manager.deleteScratchFile),
      );
      await manager.dispose();
    });

    test('surfaces missing-source and injected copy failures', () async {
      final fallback = _createService(testRoot);
      await expectLater(
        fallback.copyFileToScratch(
          path.join(testRoot.path, 'missing.wav'),
          category: 'sound_duration',
          suggestedFileName: 'missing__dur1.wav',
        ),
        throwsA(isA<FileSystemException>()),
      );
      await fallback.dispose();

      final owner = _RecordingScratchFileService(
        Directory(path.join(testRoot.path, 'owner')),
      )..copyError = StateError('copy failed');
      final injected = _createService(testRoot, scratchFileService: owner);
      final source = File(path.join(testRoot.path, 'source.wav'));
      await source.writeAsBytes(<int>[7]);

      await expectLater(
        injected.copyFileToScratch(
          source.path,
          category: 'sound_duration',
          suggestedFileName: 'source__dur1.wav',
        ),
        throwsA(isA<StateError>()),
      );
      expect(owner.deletedPaths, isEmpty);
      await injected.dispose();
    });

    test('rejects traversal before invoking the owner', () async {
      final owner = _RecordingScratchFileService(
        Directory(path.join(testRoot.path, 'owner')),
      );
      final service = _createService(testRoot, scratchFileService: owner);

      for (final category in <String>[
        '../sound',
        'sound/duration',
        r'sound\duration',
        '.',
      ]) {
        await expectLater(
          service.writeBytesToScratch(
            Uint8List(0),
            category: category,
            suggestedFileName: 'voice.wav',
          ),
          throwsArgumentError,
        );
      }
      for (final fileName in <String>[
        '../voice.wav',
        'nested/voice.wav',
        r'nested\voice.wav',
        '.',
        '..',
      ]) {
        await expectLater(
          service.writeBytesToScratch(
            Uint8List(0),
            category: 'sound_duration',
            suggestedFileName: fileName,
          ),
          throwsArgumentError,
        );
      }

      expect(owner.categories, isEmpty);
      await service.dispose();
    });

    test('does not delete unowned files', () async {
      final service = _createService(testRoot);
      final userFile = File(path.join(testRoot.path, 'user-recording.wav'));
      await userFile.writeAsBytes(<int>[8, 9]);

      await expectLater(
        service.deleteScratchFile(userFile.path),
        throwsArgumentError,
      );

      expect(await userFile.readAsBytes(), <int>[8, 9]);
      await service.dispose();
    });

    test('dispose deletes all outstanding files through the owner', () async {
      final owner = _RecordingScratchFileService(
        Directory(path.join(testRoot.path, 'owner')),
      );
      final service = _createService(testRoot, scratchFileService: owner);
      final first = await service.writeBytesToScratch(
        Uint8List.fromList(<int>[1]),
        category: 'sound_duration',
        suggestedFileName: 'first.wav',
      );
      final second = await service.writeBytesToScratch(
        Uint8List.fromList(<int>[2]),
        category: 'sound_duration',
        suggestedFileName: 'second.wav',
      );

      await service.dispose();

      expect(owner.deletedPaths, containsAll(<String>[first, second]));
      expect(await File(first).exists(), isFalse);
      expect(await File(second).exists(), isFalse);
      await expectLater(
        service.writeBytesToScratch(
          Uint8List(0),
          category: 'sound_duration',
          suggestedFileName: 'late.wav',
        ),
        throwsStateError,
      );
    });

    test('platform routes sound-duration copies and cleanup through service',
        () {
      final source =
          File('../dart/lib/sdk/tim2tox_sdk_platform.dart').readAsStringSync();
      final soundStart = source.indexOf('// Sound message — send');
      final soundEnd = source.indexOf('// Video message', soundStart);

      // NOTE: this is NOT a tautology — String.indexOf returns -1 when the
      // marker is absent, so `>= 0` really asserts that the sound-send branch
      // still exists in tim2tox_sdk_platform.dart (the whole test is a source
      // grep and would otherwise blow up in substring() below). Reasons added
      // so a renamed marker fails with a diagnosis instead of "-1 >= 0".
      expect(soundStart, greaterThanOrEqualTo(0),
          reason: "marker '// Sound message — send' not found in "
              'dart/lib/sdk/tim2tox_sdk_platform.dart');
      expect(soundEnd, greaterThan(soundStart),
          reason: "marker '// Video message' not found after the sound-send "
              'branch in dart/lib/sdk/tim2tox_sdk_platform.dart');
      final soundBranch = source.substring(soundStart, soundEnd);
      expect(soundBranch, contains('ffiService.copyFileToScratch('));
      expect(soundBranch, contains("category: 'sound_duration'"));
      expect(soundBranch, contains('_scheduleSoundScratchCleanup(tmpPath)'));
      expect(soundBranch, contains('soundFileNameForPath('));
      expect(soundBranch, isNot(contains("split('/').last")));
      expect(soundBranch, isNot(contains('Directory.systemTemp')));
      expect(soundBranch, isNot(contains('tmpFile.delete()')));
      expect(source, contains('ffiService.deleteScratchFile(scratchPath)'));
    });

    test('Windows sound path with duration exposes only encoded basename', () {
      final fileName = soundFileNameForPath(
        r'C:\Users\me\clip.wav',
        durationMs: 1450,
      );

      expect(fileName, 'clip__dur1450.wav');
      expect(fileName, isNot(contains(r'\')));
      expect(fileName, isNot(contains('Users')));
    });

    test('Windows zero-duration sound path exposes only basename', () {
      final fileName = soundFileNameForPath(
        r'C:\Users\me\clip.wav',
        durationMs: 0,
      );

      expect(fileName, 'clip.wav');
      expect(fileName, isNot(contains(r'\')));
      expect(fileName, isNot(contains('Users')));
    });

    test('POSIX sound path remains basename-safe', () {
      expect(
        soundFileNameForPath('/Users/me/clip.wav', durationMs: 900),
        'clip__dur900.wav',
      );
      expect(
        soundFileNameForPath('/Users/me/clip.wav', durationMs: 0),
        'clip.wav',
      );
    });
  });
}
