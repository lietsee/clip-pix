import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_info_manager.dart';
import 'models/image_source_type.dart';

class ImageMetadataRecord {
  ImageMetadataRecord({
    required this.fileName,
    required this.savedAt,
    required this.source,
    required this.sourceType,
    this.memo = '',
    this.extra,
  });

  final String fileName;
  final DateTime savedAt;
  final String source;
  final ImageSourceType sourceType;
  final String memo;
  final Map<String, dynamic>? extra;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'file': fileName,
      'saved_at': savedAt.toUtc().toIso8601String(),
      'source': source,
      'source_type': imageSourceTypeToString(sourceType),
      'memo': memo,
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
  }) async {
    final directory = imageFile.parent;
    final metadataName = _metadataNameFor(imageFile);
    final metadataFile = File(p.join(directory.path, metadataName));
    final jsonString = _encoder.convert(record.toJson());
    await metadataFile.writeAsString(jsonString, flush: true);

    // .fileInfo.json にも追加（新仕様）
    if (_fileInfoManager != null) {
      await _fileInfoManager!.upsertMetadata(
        imageFilePath: imageFile.path,
        fileName: record.fileName,
        savedAt: record.savedAt,
        source: record.source,
        sourceType: record.sourceType,
        memo: record.memo,
      );
    }

    return metadataFile;
  }

  String _metadataNameFor(File imageFile) {
    final base = p.basenameWithoutExtension(imageFile.path);
    return '${base}.json';
  }
}
