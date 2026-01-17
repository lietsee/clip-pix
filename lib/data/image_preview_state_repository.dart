import 'dart:ui';

import 'package:hive/hive.dart';

import 'models/image_preview_state.dart';

/// ImagePreviewWindowのウィンドウサイズと位置を永続化するリポジトリ
class ImagePreviewStateRepository {
  ImagePreviewStateRepository() {
    _box = Hive.box<ImagePreviewState>('image_preview_state');
  }

  late final Box<ImagePreviewState> _box;

  /// ウィンドウ境界と状態を保存
  Future<void> save(
    String imageId,
    Rect bounds, {
    bool alwaysOnTop = false,
    double? zoomScale,
    double? panOffsetX,
    double? panOffsetY,
  }) async {
    final state = ImagePreviewState(
      imageId: imageId,
      width: bounds.width,
      height: bounds.height,
      x: bounds.left,
      y: bounds.top,
      lastOpened: DateTime.now(),
      alwaysOnTop: alwaysOnTop,
      zoomScale: zoomScale,
      panOffsetX: panOffsetX,
      panOffsetY: panOffsetY,
    );
    await _box.put(imageId, state);
  }

  /// 保存されたウィンドウ状態を取得
  ImagePreviewState? get(String imageId) {
    return _box.get(imageId);
  }

  /// ウィンドウ状態を削除
  Future<void> remove(String imageId) async {
    await _box.delete(imageId);
  }

  /// すべてのウィンドウ状態をクリア
  Future<void> clear() async {
    await _box.clear();
  }

  /// 指定期間以上前のウィンドウ状態を削除（クリーンアップ用）
  Future<void> removeOlderThan(Duration duration) async {
    final cutoff = DateTime.now().subtract(duration);
    final keysToRemove = <String>[];

    for (final state in _box.values) {
      if (state.lastOpened.isBefore(cutoff)) {
        keysToRemove.add(state.imageId);
      }
    }

    for (final key in keysToRemove) {
      await _box.delete(key);
    }
  }
}
