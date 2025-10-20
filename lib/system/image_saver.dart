import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../data/metadata_writer.dart';
import '../data/models/image_source_type.dart';

enum SaveStatus { completed, failed }

class SaveResult {
  const SaveResult._({
    required this.status,
    this.filePath,
    this.metadataPath,
    this.error,
  });

  factory SaveResult.completed({
    required String filePath,
    required String metadataPath,
  }) {
    return SaveResult._(
      status: SaveStatus.completed,
      filePath: filePath,
      metadataPath: metadataPath,
    );
  }

  factory SaveResult.failed({Object? error}) {
    return SaveResult._(status: SaveStatus.failed, error: error);
  }

  final SaveStatus status;
  final String? filePath;
  final String? metadataPath;
  final Object? error;

  bool get isSuccess => status == SaveStatus.completed;
}

class ImageSaver {
  ImageSaver({
    required Directory? Function() getSelectedFolder,
    MetadataWriter? metadataWriter,
    Logger? logger,
    DateTime Function()? now,
  })  : _getSelectedFolder = getSelectedFolder,
        _metadataWriter = metadataWriter ?? const MetadataWriter(),
        _logger = logger ?? Logger('ImageSaver'),
        _now = now ?? DateTime.now;

  final Directory? Function() _getSelectedFolder;
  final MetadataWriter _metadataWriter;
  final Logger _logger;
  final DateTime Function() _now;

  static const _maxWriteAttempts = 3;

  Future<SaveResult> saveImageData(
    Uint8List imageData, {
    String? source,
    ImageSourceType sourceType = ImageSourceType.unknown,
  }) async {
    final targetDirectory = _getSelectedFolder();
    if (targetDirectory == null) {
      _logger.warning('Save aborted: no target directory selected');
      return SaveResult.failed(error: 'no_selected_directory');
    }

    if (!await _ensureDirectoryWritable(targetDirectory)) {
      _logger.warning(
          'Save aborted: directory not writable ${targetDirectory.path}');
      return SaveResult.failed(error: 'directory_not_writable');
    }

    final extension = _detectExtension(imageData);
    if (extension == null) {
      _logger.severe('Unsupported image format detected');
      return SaveResult.failed(error: 'unsupported_format');
    }

    final timestamp = _now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .replaceAll('.', '');
    final baseName = 'image_$timestamp';

    final imageFile = await _createUniqueFile(
      directory: targetDirectory,
      baseName: baseName,
      extension: extension,
    );

    final writeResult = await _writeBytesWithRetry(imageFile, imageData);
    if (!writeResult) {
      return SaveResult.failed(error: 'write_failed');
    }

    final metadataRecord = ImageMetadataRecord(
      fileName: p.basename(imageFile.path),
      savedAt: _now().toUtc(),
      source: source ?? 'Unknown',
      sourceType: sourceType,
    );

    final metadataFile = await _metadataWriter.writeForImage(
      imageFile: imageFile,
      record: metadataRecord,
    );

    _logger.info(
      'image_saved path=${imageFile.path} metadata=${metadataFile.path} source=${metadataRecord.sourceType.name}',
    );

    return SaveResult.completed(
      filePath: imageFile.path,
      metadataPath: metadataFile.path,
    );
  }

  Future<bool> _ensureDirectoryWritable(Directory directory) async {
    try {
      if (!await directory.exists()) {
        return false;
      }
      final probe = File(p.join(directory.path, '.clip_pix_write_test'));
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (error, stackTrace) {
      _logger.warning(
        'Directory write validation failed for ${directory.path}',
        error,
        stackTrace,
      );
      return false;
    }
  }

  Future<bool> _writeBytesWithRetry(File file, Uint8List bytes) async {
    for (var attempt = 0; attempt < _maxWriteAttempts; attempt++) {
      try {
        await file.writeAsBytes(bytes, flush: true);
        return true;
      } catch (error, stackTrace) {
        _logger.warning(
          'Failed to write image file attempt=${attempt + 1}',
          error,
          stackTrace,
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return false;
  }

  Future<File> _createUniqueFile({
    required Directory directory,
    required String baseName,
    required String extension,
  }) async {
    var attempt = 0;
    while (true) {
      final suffix = attempt == 0 ? '' : '_$attempt';
      final candidateName = '$baseName$suffix.$extension';
      final candidatePath = p.join(directory.path, candidateName);
      final candidateFile = File(candidatePath);
      if (!await candidateFile.exists()) {
        return candidateFile;
      }
      attempt++;
    }
  }

  String? _detectExtension(Uint8List bytes) {
    if (bytes.lengthInBytes < 4) {
      return null;
    }
    if (_isPng(bytes)) {
      return 'png';
    }
    if (_isJpeg(bytes)) {
      return 'jpg';
    }
    return null;
  }

  bool _isPng(Uint8List bytes) {
    const pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.lengthInBytes < pngSignature.length) {
      return false;
    }
    for (var i = 0; i < pngSignature.length; i++) {
      if (bytes[i] != pngSignature[i]) {
        return false;
      }
    }
    return true;
  }

  bool _isJpeg(Uint8List bytes) {
    return bytes.lengthInBytes >= 4 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[bytes.lengthInBytes - 2] == 0xFF &&
        bytes[bytes.lengthInBytes - 1] == 0xD9;
  }
}
