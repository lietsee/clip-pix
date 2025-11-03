// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'open_preview_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class OpenPreviewItemAdapter extends TypeAdapter<OpenPreviewItem> {
  @override
  final int typeId = 9;

  @override
  OpenPreviewItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return OpenPreviewItem(
      itemId: fields[0] as String,
      alwaysOnTop: fields[1] as bool,
      openedAt: fields[2] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, OpenPreviewItem obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.itemId)
      ..writeByte(1)
      ..write(obj.alwaysOnTop)
      ..writeByte(2)
      ..write(obj.openedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenPreviewItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
