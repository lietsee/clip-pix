import 'dart:io';
import 'dart:ui';

import 'package:logging/logging.dart';
import 'package:screen_retriever/screen_retriever.dart';

/// マルチモニタ環境でのウィンドウ位置検証サービス
///
/// Uses the `screen_retriever` package for cross-platform support (Windows/macOS).
class ScreenBoundsValidator {
  ScreenBoundsValidator() {
    if (!_isSupported) {
      _logger.warning('ScreenBoundsValidator: platform not supported');
    }
  }

  final Logger _logger = Logger('ScreenBoundsValidator');

  /// Returns true if screen bounds validation is supported on this platform.
  bool get _isSupported => Platform.isWindows || Platform.isMacOS;

  /// すべてのモニタの境界を取得
  /// マルチモニタサポート：仮想画面全体の境界を返す
  Future<List<Rect>> getAllMonitorBounds() async {
    if (!_isSupported) {
      return [Rect.fromLTWH(0, 0, 1920, 1080)]; // デフォルト
    }

    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) {
        _logger.warning('No displays detected, using fallback');
        return [Rect.fromLTWH(0, 0, 1920, 1080)];
      }

      final bounds = <Rect>[];
      for (final display in displays) {
        final x = display.visiblePosition?.dx ?? 0;
        final y = display.visiblePosition?.dy ?? 0;
        final width = display.visibleSize?.width ?? 1920;
        final height = display.visibleSize?.height ?? 1080;

        _logger.fine(
          'Display: x=$x, y=$y, width=$width, height=$height',
        );

        bounds.add(Rect.fromLTWH(x, y, width, height));
      }

      return bounds;
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to get display bounds, using fallback',
        e,
        stackTrace,
      );
    }

    // フォールバック
    return [Rect.fromLTWH(0, 0, 1920, 1080)];
  }

  /// ウィンドウが画面内の有効な位置にあるかチェック
  /// 最低50%が表示されていればtrueを返す
  Future<bool> isValidPosition(Rect windowBounds) async {
    final monitors = await getAllMonitorBounds();

    if (monitors.isEmpty) {
      _logger.warning('No monitors detected, assuming valid');
      return true;
    }

    final windowArea = windowBounds.width * windowBounds.height;
    if (windowArea == 0) {
      return false;
    }

    for (final monitor in monitors) {
      final intersection = monitor.intersect(windowBounds);
      if (intersection.isEmpty) {
        continue;
      }

      final visibleArea = intersection.width * intersection.height;
      final visibleRatio = visibleArea / windowArea;

      _logger.fine(
        'Monitor: $monitor, Window: $windowBounds, Visible: ${(visibleRatio * 100).toStringAsFixed(1)}%',
      );

      if (visibleRatio >= 0.5) {
        return true;
      }
    }

    _logger.info('Window $windowBounds is off-screen or <50% visible');
    return false;
  }

  /// ウィンドウが画面外の場合、プライマリモニタ中央に補正
  /// 有効な位置ならそのまま返す、無効ならnullを返す（center: trueにフォールバック）
  Future<Rect?> adjustIfOffScreen(Rect windowBounds) async {
    if (await isValidPosition(windowBounds)) {
      return windowBounds;
    }

    _logger.info('Window $windowBounds adjusted to null (will use center)');
    return null; // centerフラグを使用してもらう
  }
}
