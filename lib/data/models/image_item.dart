import 'package:hive/hive.dart';

import 'image_source_type.dart';

class ImageItem extends HiveObject {
  ImageItem({
    required this.id,
    required this.filePath,
    this.metadataPath,
    this.sourceType = ImageSourceType.unknown,
    DateTime? savedAt,
    this.source,
  }) : savedAt = savedAt ?? DateTime.now().toUtc();

  final String id;
  final String filePath;
  final String? metadataPath;
  final ImageSourceType sourceType;
  final DateTime savedAt;
  final String? source;

  ImageItem copyWith({
    String? id,
    String? filePath,
    String? metadataPath,
    ImageSourceType? sourceType,
    DateTime? savedAt,
    String? source,
  }) {
    return ImageItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      metadataPath: metadataPath ?? this.metadataPath,
      sourceType: sourceType ?? this.sourceType,
      savedAt: savedAt ?? this.savedAt,
      source: source ?? this.source,
    );
  }
}

class ImageItemAdapter extends TypeAdapter<ImageItem> {
  @override
  final int typeId = 1;

  @override
  ImageItem read(BinaryReader reader) {
    final id = reader.readString();
    final filePath = reader.readString();
    final metadataPath = reader.read();
    final sourceType = ImageSourceType.values[reader.readByte()];
    final savedAtMillis = reader.readInt();
    final source = reader.read();
    return ImageItem(
      id: id,
      filePath: filePath,
      metadataPath: metadataPath as String?,
      sourceType: sourceType,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMillis, isUtc: true),
      source: source as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ImageItem obj) {
    writer
      ..writeString(obj.id)
      ..writeString(obj.filePath)
      ..write(obj.metadataPath)
      ..writeByte(obj.sourceType.index)
      ..writeInt(obj.savedAt.millisecondsSinceEpoch)
      ..write(obj.source);
  }
}
