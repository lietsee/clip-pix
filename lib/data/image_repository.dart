import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'file_info_manager.dart';
import 'models/content_item.dart';
import 'models/content_type.dart';
import 'models/image_item.dart';
import 'models/image_source_type.dart';
import 'models/text_content_item.dart';

class ImageRepository {
  ImageRepository({
    Logger? logger,
    FileInfoManager? fileInfoManager,
  })  : _logger = logger ?? Logger('ImageRepository'),
        _fileInfoManager = fileInfoManager;

  final Logger _logger;
  final FileInfoManager? _fileInfoManager;

  static const _supportedExtensions = <String>{'.jpg', '.jpeg', '.png', '.txt'};

  Future<List<ContentItem>> loadForDirectory(Directory directory) async {
    try {
      if (!await directory.exists()) {
        return const <ContentItem>[];
      }
      final files = await directory
          .list()
          .where((entity) => entity is File && _isSupportedFile(entity.path))
          .cast<File>()
          .toList();
      final items = <ContentItem>[];
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
      return const <ContentItem>[];
    }
  }

  Future<ContentItem?> addOrUpdate(File file) async {
    if (!_isSupportedFile(file.path)) {
      return null;
    }
    if (!await file.exists()) {
      return null;
    }
    return _buildImageItem(file);
  }

  Future<ContentItem?> _buildImageItem(File file) async {
    try {
      final metadata = await _readMetadata(file);
      final stat = await file.stat();
      final contentType = metadata?.contentType ?? ContentType.image;

      _logger.fine(
          'build_image_item path=${file.path} savedAt=${metadata?.savedAt ?? stat.modified.toUtc()} metadata=${metadata?.metadataPath} contentType=$contentType');

      if (contentType == ContentType.text) {
        return TextContentItem(
          id: file.path,
          filePath: file.path,
          sourceType: metadata?.sourceType ?? ImageSourceType.unknown,
          savedAt: metadata?.savedAt ?? stat.modified.toUtc(),
          source: metadata?.source,
          memo: metadata?.memo ?? '',
          favorite: metadata?.favorite ?? 0,
        );
      } else {
        return ImageItem(
          id: file.path,
          filePath: file.path,
          metadataPath: metadata?.metadataPath,
          sourceType: metadata?.sourceType ?? ImageSourceType.unknown,
          savedAt: metadata?.savedAt ?? stat.modified.toUtc(),
          source: metadata?.source,
          memo: metadata?.memo ?? '',
          favorite: metadata?.favorite ?? 0,
        );
      }
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
    // 優先1: .fileInfo.json から読み込み（新仕様）
    if (_fileInfoManager != null) {
      try {
        final entry = await _fileInfoManager!.getMetadata(imageFile.path);
        if (entry != null) {
          _logger
              .fine('Metadata loaded from .fileInfo.json: ${imageFile.path}');
          return _Metadata(
            metadataPath: null, // .fileInfo.jsonからの読み込みなので個別パスはnull
            sourceType: entry.sourceType,
            source: entry.source,
            savedAt: entry.savedAt,
            contentType: entry.contentType,
            memo: entry.memo,
            favorite: entry.favorite,
          );
        }
      } catch (error, stackTrace) {
        _logger.warning(
          'Failed to read from .fileInfo.json for ${imageFile.path}',
          error,
          stackTrace,
        );
      }
    }

    // フォールバック: 個別JSONファイルから読み込み（旧仕様）
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
        memo: json['memo'] as String? ?? '', // 旧JSONにmemoがあれば読み込み
        favorite: json['favorite'] as int? ?? 0, // favoriteがあれば読み込み
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
        memo: '',
        favorite: 0,
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
    this.contentType = ContentType.image,
    this.memo = '',
    this.favorite = 0,
  });

  final String? metadataPath;
  final ImageSourceType sourceType;
  final String? source;
  final DateTime? savedAt;
  final ContentType contentType;
  final String memo;
  final int favorite;
}
