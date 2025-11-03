import 'package:hive/hive.dart';

part 'text_preview_state.g.dart';

/// TextPreviewWindowのウィンドウサイズと位置の永続化状態
@HiveType(typeId: 8)
class TextPreviewState extends HiveObject {
  TextPreviewState({
    required this.textId,
    this.width,
    this.height,
    this.x,
    this.y,
    required this.lastOpened,
    this.alwaysOnTop = false,
  });

  /// TextContentItemのID
  @HiveField(0)
  final String textId;

  /// ウィンドウ幅
  @HiveField(1)
  final double? width;

  /// ウィンドウ高さ
  @HiveField(2)
  final double? height;

  /// ウィンドウX座標（画面左上からの距離）
  @HiveField(3)
  final double? x;

  /// ウィンドウY座標（画面左上からの距離）
  @HiveField(4)
  final double? y;

  /// 最後に開いた日時（クリーンアップ用）
  @HiveField(5)
  final DateTime lastOpened;

  /// 最前面表示状態
  @HiveField(6)
  final bool alwaysOnTop;

  TextPreviewState copyWith({
    String? textId,
    double? width,
    double? height,
    double? x,
    double? y,
    DateTime? lastOpened,
    bool? alwaysOnTop,
  }) {
    return TextPreviewState(
      textId: textId ?? this.textId,
      width: width ?? this.width,
      height: height ?? this.height,
      x: x ?? this.x,
      y: y ?? this.y,
      lastOpened: lastOpened ?? this.lastOpened,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
    );
  }

  @override
  String toString() {
    return 'TextPreviewState(textId: $textId, width: $width, height: $height, x: $x, y: $y, lastOpened: $lastOpened, alwaysOnTop: $alwaysOnTop)';
  }
}
