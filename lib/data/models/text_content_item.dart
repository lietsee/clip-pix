import 'package:hive/hive.dart';

import 'content_item.dart';
import 'content_type.dart';
import 'image_source_type.dart';

/// テキストコンテンツアイテム
class TextContentItem extends ContentItem {
  TextContentItem({
    required super.id,
    required super.filePath,
    super.sourceType,
    super.savedAt,
    super.source,
    super.memo,
    super.favorite,
    this.fontSize = 16.0,
    this.textPreview = '',
  }) : super(contentType: ContentType.text);

  /// フォントサイズ（ズーム用）
  final double fontSize;

  /// テキストプレビュー（先頭200文字）
  final String textPreview;

  @override
  TextContentItem copyWith({
    String? id,
    String? filePath,
    ContentType? contentType,
    ImageSourceType? sourceType,
    DateTime? savedAt,
    String? source,
    String? memo,
    int? favorite,
    double? fontSize,
    String? textPreview,
  }) {
    return TextContentItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      sourceType: sourceType ?? this.sourceType,
      savedAt: savedAt ?? this.savedAt,
      source: source ?? this.source,
      memo: memo ?? this.memo,
      favorite: favorite ?? this.favorite,
      fontSize: fontSize ?? this.fontSize,
      textPreview: textPreview ?? this.textPreview,
    );
  }
}

/// TextContentItem用のHive TypeAdapter
class TextContentItemAdapter extends TypeAdapter<TextContentItem> {
  @override
  final int typeId = 7;

  @override
  TextContentItem read(BinaryReader reader) {
    final id = reader.readString();
    final filePath = reader.readString();
    final sourceType = ImageSourceType.values[reader.readByte()];
    final savedAtMillis = reader.readInt();
    final source = reader.read() as String?;
    final memo = reader.readString();
    final favorite = reader.readInt();
    final fontSize = reader.readDouble();
    final textPreview = reader.readString();

    return TextContentItem(
      id: id,
      filePath: filePath,
      sourceType: sourceType,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMillis, isUtc: true),
      source: source,
      memo: memo,
      favorite: favorite,
      fontSize: fontSize,
      textPreview: textPreview,
    );
  }

  @override
  void write(BinaryWriter writer, TextContentItem obj) {
    writer
      ..writeString(obj.id)
      ..writeString(obj.filePath)
      ..writeByte(obj.sourceType.index)
      ..writeInt(obj.savedAt.millisecondsSinceEpoch)
      ..write(obj.source)
      ..writeString(obj.memo)
      ..writeInt(obj.favorite)
      ..writeDouble(obj.fontSize)
      ..writeString(obj.textPreview);
  }
}
