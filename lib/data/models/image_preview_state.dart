import 'package:hive/hive.dart';

part 'image_preview_state.g.dart';

/// ImagePreviewWindowのウィンドウサイズと位置の永続化状態
@HiveType(typeId: 10)
class ImagePreviewState extends HiveObject {
  ImagePreviewState({
    required this.imageId,
    this.width,
    this.height,
    this.x,
    this.y,
    required this.lastOpened,
    this.alwaysOnTop = false,
  });

  /// ImageItemのID
  @HiveField(0)
  final String imageId;

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
  @HiveField(6, defaultValue: false)
  final bool alwaysOnTop;

  ImagePreviewState copyWith({
    String? imageId,
    double? width,
    double? height,
    double? x,
    double? y,
    DateTime? lastOpened,
    bool? alwaysOnTop,
  }) {
    return ImagePreviewState(
      imageId: imageId ?? this.imageId,
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
    return 'ImagePreviewState(imageId: $imageId, width: $width, height: $height, x: $x, y: $y, lastOpened: $lastOpened, alwaysOnTop: $alwaysOnTop)';
  }
}
