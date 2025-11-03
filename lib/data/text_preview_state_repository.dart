import 'dart:ui';

import 'package:hive/hive.dart';

import 'models/text_preview_state.dart';

/// TextPreviewWindowのウィンドウサイズと位置を永続化するリポジトリ
class TextPreviewStateRepository {
  TextPreviewStateRepository() {
    _box = Hive.box<TextPreviewState>('text_preview_state');
  }

  late final Box<TextPreviewState> _box;

  /// ウィンドウ境界と状態を保存
  Future<void> save(
    String textId,
    Rect bounds, {
    bool alwaysOnTop = false,
  }) async {
    final state = TextPreviewState(
      textId: textId,
      width: bounds.width,
      height: bounds.height,
      x: bounds.left,
      y: bounds.top,
      lastOpened: DateTime.now(),
      alwaysOnTop: alwaysOnTop,
    );
    await _box.put(textId, state);
  }

  /// 保存されたウィンドウ状態を取得
  TextPreviewState? get(String textId) {
    return _box.get(textId);
  }

  /// ウィンドウ状態を削除
  Future<void> remove(String textId) async {
    await _box.delete(textId);
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
        keysToRemove.add(state.textId);
      }
    }

    for (final key in keysToRemove) {
      await _box.delete(key);
    }
  }
}
