import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_info_manager.dart';
import 'models/content_type.dart';
import 'models/image_source_type.dart';

class ImageMetadataRecord {
  ImageMetadataRecord({
    required this.fileName,
    required this.savedAt,
    required this.source,
    required this.sourceType,
    this.contentType = ContentType.image,
    this.memo = '',
    this.favorite = 0,
    this.extra,
  });

  final String fileName;
  final DateTime savedAt;
  final String source;
  final ImageSourceType sourceType;
  final ContentType contentType;
  final String memo;
  final int favorite;
  final Map<String, dynamic>? extra;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'file': fileName,
      'saved_at': savedAt.toUtc().toIso8601String(),
      'source': source,
      'source_type': imageSourceTypeToString(sourceType),
      'content_type': contentTypeToString(contentType),
      'memo': memo,
      'favorite': favorite,
    };
    if (extra != null && extra!.isNotEmpty) {
      json['extra'] = extra;
    }
    return json;
  }
}

class MetadataWriter {
  const MetadataWriter({
    JsonEncoder? encoder,
    FileInfoManager? fileInfoManager,
  })  : _encoder = encoder ?? _defaultEncoder,
        _fileInfoManager = fileInfoManager;

  final JsonEncoder _encoder;
  final FileInfoManager? _fileInfoManager;

  static const JsonEncoder _defaultEncoder = JsonEncoder();

  Future<File> writeForImage({
    required File imageFile,
    required ImageMetadataRecord record,
    bool skipIndividualJson = false,
  }) async {
    final directory = imageFile.parent;
    final metadataName = _metadataNameFor(imageFile);
    final metadataFile = File(p.join(directory.path, metadataName));

    // skipIndividualJson=trueの場合、個別JSON作成をスキップ
    if (!skipIndividualJson) {
      final jsonString = _encoder.convert(record.toJson());
      await metadataFile.writeAsString(jsonString, flush: true);
    }

    // .fileInfo.json にも追加（新仕様）
    if (_fileInfoManager case final fileInfoManager?) {
      await fileInfoManager.upsertMetadata(
        imageFilePath: imageFile.path,
        fileName: record.fileName,
        savedAt: record.savedAt,
        source: record.source,
        sourceType: record.sourceType,
        contentType: record.contentType,
        memo: record.memo,
        favorite: record.favorite,
      );
    }

    return metadataFile;
  }

  String _metadataNameFor(File imageFile) {
    final base = p.basenameWithoutExtension(imageFile.path);
    return '${base}.json';
  }
}
