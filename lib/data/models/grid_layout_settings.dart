import 'package:hive/hive.dart';

class GridLayoutSettings {
  GridLayoutSettings({
    required this.preferredColumns,
    required this.maxColumns,
    required this.background,
    required this.bulkSpan,
  });

  final int preferredColumns;
  final int maxColumns;
  final GridBackgroundTone background;
  final int bulkSpan;

  GridLayoutSettings copyWith({
    int? preferredColumns,
    int? maxColumns,
    GridBackgroundTone? background,
    int? bulkSpan,
  }) {
    return GridLayoutSettings(
      preferredColumns: preferredColumns ?? this.preferredColumns,
      maxColumns: maxColumns ?? this.maxColumns,
      background: background ?? this.background,
      bulkSpan: bulkSpan ?? this.bulkSpan,
    );
  }

  static GridLayoutSettings defaults() => GridLayoutSettings(
        preferredColumns: 6,
        maxColumns: 6,
        background: GridBackgroundTone.white,
        bulkSpan: 1,
      );
}

enum GridBackgroundTone {
  white,
  lightGray,
  darkGray,
  black,
}

class GridLayoutSettingsAdapter extends TypeAdapter<GridLayoutSettings> {
  @override
  final int typeId = 4;

  @override
  GridLayoutSettings read(BinaryReader reader) {
    final preferredColumns = reader.readInt();
    final maxColumns = reader.readInt();
    final backgroundIndex = reader.readInt();
    final bulkSpan = reader.readInt();
    return GridLayoutSettings(
      preferredColumns: preferredColumns,
      maxColumns: maxColumns,
      background: GridBackgroundTone.values[backgroundIndex],
      bulkSpan: bulkSpan,
    );
  }

  @override
  void write(BinaryWriter writer, GridLayoutSettings obj) {
    writer
      ..writeInt(obj.preferredColumns)
      ..writeInt(obj.maxColumns)
      ..writeInt(obj.background.index)
      ..writeInt(obj.bulkSpan);
  }
}

class GridBackgroundToneAdapter extends TypeAdapter<GridBackgroundTone> {
  @override
  final int typeId = 5;

  @override
  GridBackgroundTone read(BinaryReader reader) {
    final index = reader.readInt();
    return GridBackgroundTone.values[index];
  }

  @override
  void write(BinaryWriter writer, GridBackgroundTone obj) {
    writer.writeInt(obj.index);
  }
}
