import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'models/image_item.dart';
import 'models/image_source_type.dart';

class ImageRepository {
  ImageRepository({Logger? logger})
      : _logger = logger ?? Logger('ImageRepository');

  final Logger _logger;

  static const _supportedExtensions = <String>{'.jpg', '.jpeg', '.png'};

  Future<List<ImageItem>> loadForDirectory(Directory directory) async {
    try {
      if (!await directory.exists()) {
        return const <ImageItem>[];
      }
      final files = await directory
          .list()
          .where((entity) => entity is File && _isSupportedFile(entity.path))
          .cast<File>()
          .toList();
      final items = <ImageItem>[];
      for (final file in files) {
        final item = await _buildImageItem(file);
        if (item != null) {
          items.add(item);
        }
      }
      items.sort((a, b) {
        final savedAtCompare = b.savedAt.compareTo(a.savedAt);
        if (savedAtCompare != 0) {
          return savedAtCompare;
        }
        return b.filePath.compareTo(a.filePath);
      });
      return items;
    } catch (error, stackTrace) {
      _logger.severe('Failed to load directory images', error, stackTrace);
      return const <ImageItem>[];
    }
  }

  Future<ImageItem?> addOrUpdate(File file) async {
    if (!_isSupportedFile(file.path)) {
      return null;
    }
    if (!await file.exists()) {
      return null;
    }
    return _buildImageItem(file);
  }

  Future<ImageItem?> _buildImageItem(File file) async {
    try {
      final metadata = await _readMetadata(file);
      final stat = await file.stat();
      _logger.fine(
          'build_image_item path=${file.path} savedAt=${metadata?.savedAt ?? stat.modified.toUtc()} metadata=${metadata?.metadataPath}');
      return ImageItem(
        id: file.path,
        filePath: file.path,
        metadataPath: metadata?.metadataPath,
        sourceType: metadata?.sourceType ?? ImageSourceType.unknown,
        savedAt: metadata?.savedAt ?? stat.modified.toUtc(),
        source: metadata?.source,
      );
    } catch (error, stackTrace) {
      _logger.warning(
        'Failed to build image item for ${file.path}',
        error,
        stackTrace,
      );
      return null;
    }
  }

  Future<_Metadata?> _readMetadata(File imageFile) async {
    final metadataFile = File(_metadataPathFor(imageFile));
    if (!await metadataFile.exists()) {
      return null;
    }
    try {
      final jsonString = await metadataFile.readAsString();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final sourceType = imageSourceTypeFromString(
        (json['source_type'] as String?) ?? 'unknown',
      );
      final savedAtString = json['saved_at'] as String?;
      final savedAt = savedAtString != null
          ? DateTime.tryParse(savedAtString)?.toUtc()
          : null;
      return _Metadata(
        metadataPath: metadataFile.path,
        sourceType: sourceType,
        source: json['source'] as String?,
        savedAt: savedAt,
      );
    } catch (error, stackTrace) {
      _logger.warning(
        'Failed to read metadata for ${imageFile.path}',
        error,
        stackTrace,
      );
      return _Metadata(
        metadataPath: metadataFile.path,
        sourceType: ImageSourceType.unknown,
        source: null,
        savedAt: null,
      );
    }
  }

  String _metadataPathFor(File imageFile) {
    final base = p.basenameWithoutExtension(imageFile.path);
    return p.join(imageFile.parent.path, '$base.json');
  }

  bool _isSupportedFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return _supportedExtensions.contains(ext);
  }
}

class _Metadata {
  const _Metadata({
    required this.metadataPath,
    required this.sourceType,
    required this.source,
    required this.savedAt,
  });

  final String metadataPath;
  final ImageSourceType sourceType;
  final String? source;
  final DateTime? savedAt;
}
