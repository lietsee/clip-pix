import 'package:hive/hive.dart';

/// PdfPreviewWindowのウィンドウサイズと位置の永続化状態
class PdfPreviewState extends HiveObject {
  PdfPreviewState({
    required this.pdfId,
    this.width,
    this.height,
    this.x,
    this.y,
    required this.currentPage,
    required this.lastOpened,
    this.alwaysOnTop = false,
  });

  /// PDFアイテムのID
  final String pdfId;

  /// ウィンドウ幅
  final double? width;

  /// ウィンドウ高さ
  final double? height;

  /// ウィンドウX座標（画面左上からの距離）
  final double? x;

  /// ウィンドウY座標（画面左上からの距離）
  final double? y;

  /// 現在表示中のページ（1-indexed）
  final int currentPage;

  /// 最後に開いた日時（クリーンアップ用）
  final DateTime lastOpened;

  /// 最前面表示状態
  final bool alwaysOnTop;

  PdfPreviewState copyWith({
    String? pdfId,
    double? width,
    double? height,
    double? x,
    double? y,
    int? currentPage,
    DateTime? lastOpened,
    bool? alwaysOnTop,
  }) {
    return PdfPreviewState(
      pdfId: pdfId ?? this.pdfId,
      width: width ?? this.width,
      height: height ?? this.height,
      x: x ?? this.x,
      y: y ?? this.y,
      currentPage: currentPage ?? this.currentPage,
      lastOpened: lastOpened ?? this.lastOpened,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
    );
  }

  @override
  String toString() {
    return 'PdfPreviewState(pdfId: $pdfId, width: $width, height: $height, x: $x, y: $y, currentPage: $currentPage, lastOpened: $lastOpened, alwaysOnTop: $alwaysOnTop)';
  }
}

/// PdfPreviewState用Hiveアダプター (typeId: 12)
class PdfPreviewStateAdapter extends TypeAdapter<PdfPreviewState> {
  @override
  final int typeId = 12;

  @override
  PdfPreviewState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PdfPreviewState(
      pdfId: fields[0] as String,
      width: fields[1] as double?,
      height: fields[2] as double?,
      x: fields[3] as double?,
      y: fields[4] as double?,
      currentPage: fields[5] as int? ?? 1,
      lastOpened: fields[6] as DateTime,
      alwaysOnTop: fields[7] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, PdfPreviewState obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.pdfId)
      ..writeByte(1)
      ..write(obj.width)
      ..writeByte(2)
      ..write(obj.height)
      ..writeByte(3)
      ..write(obj.x)
      ..writeByte(4)
      ..write(obj.y)
      ..writeByte(5)
      ..write(obj.currentPage)
      ..writeByte(6)
      ..write(obj.lastOpened)
      ..writeByte(7)
      ..write(obj.alwaysOnTop);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfPreviewStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
