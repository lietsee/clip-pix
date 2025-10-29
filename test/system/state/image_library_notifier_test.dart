import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:clip_pix/data/image_repository.dart';
import 'package:clip_pix/system/state/image_library_notifier.dart';
import 'package:clip_pix/system/state/image_library_state.dart';

class _TestImageLibraryNotifier extends ImageLibraryNotifier {
  _TestImageLibraryNotifier(ImageRepository repository) : super(repository);

  ImageLibraryState get exposedState => state;
}

void main() {
  late Directory tempDir;
  late ImageRepository repository;
  late _TestImageLibraryNotifier notifier;

  setUp(() async {
    Logger.root.level = Level.OFF;
    tempDir = await Directory.systemTemp.createTemp('clip_pix_test');
    repository = ImageRepository();
    notifier = _TestImageLibraryNotifier(repository);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ImageLibraryNotifier', () {
    test('loadForDirectory loads supported images', () async {
      await _createImageWithMetadata(tempDir, 'image_1.jpg', source: 'local');
      await _createImageWithMetadata(tempDir, 'image_2.png',
          source: 'https://example.com');
      await _createNonImage(tempDir, 'note.txt');

      await notifier.loadForDirectory(tempDir);

      expect(notifier.exposedState.images.length, 3); // Now includes .txt files
      expect(notifier.exposedState.isLoading, false);
      expect(
          notifier.exposedState.images.first.filePath.endsWith('note.txt'),
          isTrue); // Most recent file is note.txt
    });

    test('addOrUpdate inserts new file at head', () async {
      await _createImageWithMetadata(tempDir, 'image_a.jpg');
      await notifier.loadForDirectory(tempDir);

      final newFile = await _createImageWithMetadata(tempDir, 'image_b.jpg');
      await notifier.addOrUpdate(newFile);

      expect(notifier.exposedState.images.first.filePath, equals(newFile.path));
    });

    test('remove drops item by path', () async {
      final file = await _createImageWithMetadata(tempDir, 'image_remove.jpg');
      await notifier.loadForDirectory(tempDir);

      notifier.remove(file.path);

      expect(
        notifier.exposedState.images
            .where((item) => item.filePath == file.path),
        isEmpty,
      );
    });
  });
}

Future<File> _createImageWithMetadata(
  Directory base,
  String name, {
  String? source,
}) async {
  final imageFile = File('${base.path}/$name');
  await imageFile.writeAsBytes(<int>[0, 1, 2, 3]);
  final metadataFile = File('${base.path}/${name.split('.').first}.json');
  await metadataFile.writeAsString('''{
    "file": "$name",
    "saved_at": "2024-10-20T12:34:56Z",
    "source": "${source ?? 'Unknown'}",
    "source_type": "${source != null && source.startsWith('http') ? 'web' : 'local'}"
  }''');
  return imageFile;
}

Future<File> _createNonImage(Directory base, String name) async {
  final file = File('${base.path}/$name');
  await file.writeAsString('noop');
  return file;
}
