import 'package:hive/hive.dart';

enum ImageSourceType { web, local, unknown }

class ImageSourceTypeAdapter extends TypeAdapter<ImageSourceType> {
  @override
  final int typeId = 0;

  @override
  ImageSourceType read(BinaryReader reader) {
    final index = reader.readByte();
    switch (index) {
      case 0:
        return ImageSourceType.web;
      case 1:
        return ImageSourceType.local;
      default:
        return ImageSourceType.unknown;
    }
  }

  @override
  void write(BinaryWriter writer, ImageSourceType obj) {
    switch (obj) {
      case ImageSourceType.web:
        writer.writeByte(0);
        break;
      case ImageSourceType.local:
        writer.writeByte(1);
        break;
      case ImageSourceType.unknown:
        writer.writeByte(2);
        break;
    }
  }
}

ImageSourceType imageSourceTypeFromString(String value) {
  switch (value.toLowerCase()) {
    case 'web':
      return ImageSourceType.web;
    case 'local':
      return ImageSourceType.local;
    default:
      return ImageSourceType.unknown;
  }
}

String imageSourceTypeToString(ImageSourceType type) {
  switch (type) {
    case ImageSourceType.web:
      return 'web';
    case ImageSourceType.local:
      return 'local';
    case ImageSourceType.unknown:
      return 'unknown';
  }
}
