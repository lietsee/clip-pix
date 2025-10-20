import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models/image_source_type.dart';

class ImageMetadataRecord {
  ImageMetadataRecord({
    required this.fileName,
    required this.savedAt,
    required this.source,
    required this.sourceType,
    this.extra,
  });

  final String fileName;
  final DateTime savedAt;
  final String source;
  final ImageSourceType sourceType;
  final Map<String, dynamic>? extra;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'file': fileName,
      'saved_at': savedAt.toUtc().toIso8601String(),
      'source': source,
      'source_type': imageSourceTypeToString(sourceType),
    };
    if (extra != null && extra!.isNotEmpty) {
      json['extra'] = extra;
    }
    return json;
  }
}

class MetadataWriter {
  const MetadataWriter({JsonEncoder? encoder})
      : _encoder = encoder ?? _defaultEncoder;

  final JsonEncoder _encoder;

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
    return metadataFile;
  }

  String _metadataNameFor(File imageFile) {
    final base = p.basenameWithoutExtension(imageFile.path);
    return '${base}.json';
  }
}
