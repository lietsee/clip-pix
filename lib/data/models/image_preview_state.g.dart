// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'image_preview_state.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ImagePreviewStateAdapter extends TypeAdapter<ImagePreviewState> {
  @override
  final int typeId = 10;

  @override
  ImagePreviewState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ImagePreviewState(
      imageId: fields[0] as String,
      width: fields[1] as double?,
      height: fields[2] as double?,
      x: fields[3] as double?,
      y: fields[4] as double?,
      lastOpened: fields[5] as DateTime,
      alwaysOnTop: fields[6] == null ? false : fields[6] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, ImagePreviewState obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.imageId)
      ..writeByte(1)
      ..write(obj.width)
      ..writeByte(2)
      ..write(obj.height)
      ..writeByte(3)
      ..write(obj.x)
      ..writeByte(4)
      ..write(obj.y)
      ..writeByte(5)
      ..write(obj.lastOpened)
      ..writeByte(6)
      ..write(obj.alwaysOnTop);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImagePreviewStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
