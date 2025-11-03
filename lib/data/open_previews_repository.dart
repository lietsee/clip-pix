import 'package:hive/hive.dart';

import 'models/open_preview_item.dart';

/// 現在開いているTextPreviewWindowsを追跡するリポジトリ
/// アプリ再起動時にプレビューウィンドウを復元するために使用
class OpenPreviewsRepository {
  OpenPreviewsRepository() {
    _box = Hive.box<OpenPreviewItem>('open_previews');
  }

  late final Box<OpenPreviewItem> _box;

  /// プレビューウィンドウが開いたことを記録
  Future<void> add(String itemId, {bool alwaysOnTop = false}) async {
    final item = OpenPreviewItem(
      itemId: itemId,
      alwaysOnTop: alwaysOnTop,
      openedAt: DateTime.now(),
    );
    await _box.put(itemId, item);
  }

  /// プレビューウィンドウが閉じたことを記録
  Future<void> remove(String itemId) async {
    await _box.delete(itemId);
  }

  /// 現在開いている全プレビューウィンドウのリストを取得
  List<OpenPreviewItem> getAll() {
    return _box.values.toList();
  }

  /// 特定のアイテムのプレビューが開いているかチェック
  bool isOpen(String itemId) {
    return _box.containsKey(itemId);
  }

  /// 特定のアイテムのプレビュー情報を取得
  OpenPreviewItem? get(String itemId) {
    return _box.get(itemId);
  }

  /// すべてのプレビュー情報をクリア
  Future<void> clear() async {
    await _box.clear();
  }

  /// 指定期間以上前に開いたプレビュー情報を削除（クリーンアップ用）
  Future<void> removeOlderThan(Duration duration) async {
    final cutoff = DateTime.now().subtract(duration);
    final keysToRemove = <String>[];

    for (final item in _box.values) {
      if (item.openedAt.isBefore(cutoff)) {
        keysToRemove.add(item.itemId);
      }
    }

    for (final key in keysToRemove) {
      await _box.delete(key);
    }
  }
}
