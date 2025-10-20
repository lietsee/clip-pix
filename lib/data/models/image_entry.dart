import 'package:hive/hive.dart';

import 'image_source_type.dart';

class ImageEntry extends HiveObject {
  ImageEntry({
    required this.filePath,
    required this.metadataPath,
    required this.sourceType,
    required this.savedAt,
  });

  final String filePath;
  final String metadataPath;
  final ImageSourceType sourceType;
  final DateTime savedAt;
}

class ImageEntryAdapter extends TypeAdapter<ImageEntry> {
  @override
  final int typeId = 2;

  @override
  ImageEntry read(BinaryReader reader) {
    final filePath = reader.readString();
    final metadataPath = reader.readString();
    final sourceType = ImageSourceType.values[reader.readByte()];
    final savedAtMillis = reader.readInt();
    return ImageEntry(
      filePath: filePath,
      metadataPath: metadataPath,
      sourceType: sourceType,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMillis, isUtc: true),
    );
  }

  @override
  void write(BinaryWriter writer, ImageEntry obj) {
    writer
      ..writeString(obj.filePath)
      ..writeString(obj.metadataPath)
      ..writeByte(obj.sourceType.index)
      ..writeInt(obj.savedAt.millisecondsSinceEpoch);
  }
}
