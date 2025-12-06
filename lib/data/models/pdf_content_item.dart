import 'package:hive/hive.dart';

import 'content_item.dart';
import 'content_type.dart';
import 'image_source_type.dart';

/// PDFコンテンツアイテム
class PdfContentItem extends ContentItem {
  PdfContentItem({
    required super.id,
    required super.filePath,
    super.sourceType,
    super.savedAt,
    super.source,
    super.memo,
    super.favorite,
    this.pageCount = 1,
  }) : super(contentType: ContentType.pdf);

  /// PDFのページ数
  final int pageCount;

  @override
  PdfContentItem copyWith({
    String? id,
    String? filePath,
    ContentType? contentType,
    ImageSourceType? sourceType,
    DateTime? savedAt,
    String? source,
    String? memo,
    int? favorite,
    int? pageCount,
  }) {
    return PdfContentItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      sourceType: sourceType ?? this.sourceType,
      savedAt: savedAt ?? this.savedAt,
      source: source ?? this.source,
      memo: memo ?? this.memo,
      favorite: favorite ?? this.favorite,
      pageCount: pageCount ?? this.pageCount,
    );
  }
}

/// PdfContentItem用のHive TypeAdapter
class PdfContentItemAdapter extends TypeAdapter<PdfContentItem> {
  @override
  final int typeId = 11;

  @override
  PdfContentItem read(BinaryReader reader) {
    final id = reader.readString();
    final filePath = reader.readString();
    final sourceType = ImageSourceType.values[reader.readByte()];
    final savedAtMillis = reader.readInt();
    final source = reader.read() as String?;
    final memo = reader.readString();
    final favorite = reader.readInt();
    final pageCount = reader.readInt();

    return PdfContentItem(
      id: id,
      filePath: filePath,
      sourceType: sourceType,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMillis, isUtc: true),
      source: source,
      memo: memo,
      favorite: favorite,
      pageCount: pageCount,
    );
  }

  @override
  void write(BinaryWriter writer, PdfContentItem obj) {
    writer
      ..writeString(obj.id)
      ..writeString(obj.filePath)
      ..writeByte(obj.sourceType.index)
      ..writeInt(obj.savedAt.millisecondsSinceEpoch)
      ..write(obj.source)
      ..writeString(obj.memo)
      ..writeInt(obj.favorite)
      ..writeInt(obj.pageCount);
  }
}
