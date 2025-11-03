// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'text_preview_state.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class TextPreviewStateAdapter extends TypeAdapter<TextPreviewState> {
  @override
  final int typeId = 8;

  @override
  TextPreviewState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TextPreviewState(
      textId: fields[0] as String,
      width: fields[1] as double?,
      height: fields[2] as double?,
      x: fields[3] as double?,
      y: fields[4] as double?,
      lastOpened: fields[5] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, TextPreviewState obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.textId)
      ..writeByte(1)
      ..write(obj.width)
      ..writeByte(2)
      ..write(obj.height)
      ..writeByte(3)
      ..write(obj.x)
      ..writeByte(4)
      ..write(obj.y)
      ..writeByte(5)
      ..write(obj.lastOpened);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextPreviewStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
