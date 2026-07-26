import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:tim2tox_dart/tim2tox_dart.dart';

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
      final expectedRoot = path.join(
        Directory.systemTemp.path,
        'toxee_tim2tox_scratch',
      );

      final scratchPath = await service.writeBytesToScratch(
        Uint8List.fromList(<int>[4, 5, 6]),
        category: 'sound_duration',
        suggestedFileName: 'voice__dur900.ogg',
      );

      expect(path.isWithin(expectedRoot, scratchPath), isTrue);
      expect(path.basename(scratchPath), 'voice__dur900.ogg');
      expect(await File(scratchPath).readAsBytes(), <int>[4, 5, 6]);

      await service.deleteScratchFile(scratchPath);
      expect(await File(scratchPath).exists(), isFalse);
      await service.dispose();
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
      final soundStart = source.indexOf('// Sound message');
      final soundEnd = source.indexOf('// Video message', soundStart);

      expect(soundStart, greaterThanOrEqualTo(0));
      expect(soundEnd, greaterThan(soundStart));
      final soundBranch = source.substring(soundStart, soundEnd);
      expect(soundBranch, contains('ffiService.copyFileToScratch('));
      expect(soundBranch, contains("category: 'sound_duration'"));
      expect(soundBranch, contains('_scheduleSoundScratchCleanup(tmpPath)'));
      expect(soundBranch, isNot(contains('Directory.systemTemp')));
      expect(soundBranch, isNot(contains('tmpFile.delete()')));
      expect(source, contains('ffiService.deleteScratchFile(scratchPath)'));
    });
  });
}
