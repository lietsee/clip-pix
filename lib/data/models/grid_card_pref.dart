import 'dart:ui';

import 'package:hive/hive.dart';

class GridCardPreference {
  GridCardPreference({
    required this.id,
    required this.width,
    required this.height,
    required this.scale,
    required this.columnSpan,
    this.customHeight,
    this.offsetDx = 0.0,
    this.offsetDy = 0.0,
  });

  final String id;
  final double width;
  final double height;
  final double scale;
  final int columnSpan;
  final double? customHeight;
  final double offsetDx;
  final double offsetDy;

  Size get size => Size(width, height);
  Offset get offset => Offset(offsetDx, offsetDy);

  GridCardPreference copyWith({
    String? id,
    double? width,
    double? height,
    double? scale,
    int? columnSpan,
    double? customHeight,
    bool overrideCustomHeight = false,
    double? offsetDx,
    double? offsetDy,
  }) {
    return GridCardPreference(
      id: id ?? this.id,
      width: width ?? this.width,
      height: height ?? this.height,
      scale: scale ?? this.scale,
      columnSpan: columnSpan ?? this.columnSpan,
      customHeight: overrideCustomHeight
          ? customHeight
          : (customHeight ?? this.customHeight),
      offsetDx: offsetDx ?? this.offsetDx,
      offsetDy: offsetDy ?? this.offsetDy,
    );
  }
}

class GridCardPreferenceAdapter extends TypeAdapter<GridCardPreference> {
  @override
  final int typeId = 3;

  @override
  GridCardPreference read(BinaryReader reader) {
    final id = reader.readString();
    final width = reader.readDouble();
    final height = reader.readDouble();
    final scale = reader.readDouble();
    int columnSpan = 1;
    double? customHeight;
    double offsetDx = 0.0;
    double offsetDy = 0.0;
    if (reader.availableBytes >= 4) {
      columnSpan = reader.readInt();
      if (reader.availableBytes >= 8) {
        customHeight = reader.readDouble();
        // offsetDx, offsetDy の読み取り（後方互換性のため存在チェック）
        if (reader.availableBytes >= 16) {
          offsetDx = reader.readDouble();
          offsetDy = reader.readDouble();
        }
      }
    }
    return GridCardPreference(
      id: id,
      width: width,
      height: height,
      scale: scale,
      columnSpan: columnSpan,
      customHeight: customHeight,
      offsetDx: offsetDx,
      offsetDy: offsetDy,
    );
  }

  @override
  void write(BinaryWriter writer, GridCardPreference obj) {
    writer
      ..writeString(obj.id)
      ..writeDouble(obj.width)
      ..writeDouble(obj.height)
      ..writeDouble(obj.scale)
      ..writeInt(obj.columnSpan)
      ..writeDouble(obj.customHeight ?? obj.height)
      ..writeDouble(obj.offsetDx)
      ..writeDouble(obj.offsetDy);
  }
}
