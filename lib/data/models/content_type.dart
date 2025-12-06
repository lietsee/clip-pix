import 'package:hive/hive.dart';

/// コンテンツの種類を表すEnum
enum ContentType {
  /// 画像コンテンツ
  image,

  /// テキストコンテンツ
  text,

  /// PDFコンテンツ
  pdf,
}

/// ContentTypeを文字列に変換
String contentTypeToString(ContentType type) {
  switch (type) {
    case ContentType.image:
      return 'image';
    case ContentType.text:
      return 'text';
    case ContentType.pdf:
      return 'pdf';
  }
}

/// 文字列からContentTypeに変換
ContentType contentTypeFromString(String str) {
  switch (str.toLowerCase()) {
    case 'image':
      return ContentType.image;
    case 'text':
      return ContentType.text;
    case 'pdf':
      return ContentType.pdf;
    default:
      return ContentType.image; // デフォルトは画像
  }
}

/// ContentType用のHive TypeAdapter
class ContentTypeAdapter extends TypeAdapter<ContentType> {
  @override
  final int typeId = 6;

  @override
  ContentType read(BinaryReader reader) {
    final index = reader.readByte();
    return ContentType.values[index];
  }

  @override
  void write(BinaryWriter writer, ContentType obj) {
    writer.writeByte(obj.index);
  }
}
