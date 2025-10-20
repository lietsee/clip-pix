import 'dart:ui';

import 'package:hive/hive.dart';

class GridCardPreference {
  GridCardPreference({
    required this.id,
    required this.width,
    required this.height,
    required this.scale,
  });

  final String id;
  final double width;
  final double height;
  final double scale;

  Size get size => Size(width, height);

  GridCardPreference copyWith({
    String? id,
    double? width,
    double? height,
    double? scale,
  }) {
    return GridCardPreference(
      id: id ?? this.id,
      width: width ?? this.width,
      height: height ?? this.height,
      scale: scale ?? this.scale,
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
    return GridCardPreference(
      id: id,
      width: width,
      height: height,
      scale: scale,
    );
  }

  @override
  void write(BinaryWriter writer, GridCardPreference obj) {
    writer
      ..writeString(obj.id)
      ..writeDouble(obj.width)
      ..writeDouble(obj.height)
      ..writeDouble(obj.scale);
  }
}
