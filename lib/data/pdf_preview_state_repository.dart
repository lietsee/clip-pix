import 'dart:ui';

import 'package:hive/hive.dart';

import 'models/pdf_preview_state.dart';

/// PdfPreviewWindowのウィンドウサイズと位置を永続化するリポジトリ
class PdfPreviewStateRepository {
  PdfPreviewStateRepository() {
    _box = Hive.box<PdfPreviewState>('pdf_preview_state');
  }

  late final Box<PdfPreviewState> _box;

  /// ウィンドウ境界と状態を保存
  Future<void> save(
    String pdfId,
    Rect bounds, {
    int currentPage = 1,
    bool alwaysOnTop = false,
  }) async {
    final state = PdfPreviewState(
      pdfId: pdfId,
      width: bounds.width,
      height: bounds.height,
      x: bounds.left,
      y: bounds.top,
      currentPage: currentPage,
      lastOpened: DateTime.now(),
      alwaysOnTop: alwaysOnTop,
    );
    await _box.put(pdfId, state);
  }

  /// 保存されたウィンドウ状態を取得
  PdfPreviewState? get(String pdfId) {
    return _box.get(pdfId);
  }

  /// ウィンドウ状態を削除
  Future<void> remove(String pdfId) async {
    await _box.delete(pdfId);
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
        keysToRemove.add(state.pdfId);
      }
    }

    for (final key in keysToRemove) {
      await _box.delete(key);
    }
  }
}
