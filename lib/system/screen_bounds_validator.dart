import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:win32/win32.dart';

/// マルチモニタ環境でのウィンドウ位置検証サービス
class ScreenBoundsValidator {
  ScreenBoundsValidator() {
    if (!Platform.isWindows) {
      _logger.warning('ScreenBoundsValidator is only supported on Windows');
    }
  }

  final Logger _logger = Logger('ScreenBoundsValidator');

  /// すべてのモニタの境界を取得
  /// 簡略化：プライマリモニタの作業領域のみを返す
  List<Rect> getAllMonitorBounds() {
    if (!Platform.isWindows) {
      return [Rect.fromLTWH(0, 0, 1920, 1080)]; // デフォルト
    }

    try {
      // プライマリモニタの作業領域を取得
      final rect = calloc<RECT>();
      final success = SystemParametersInfo(
        SPI_GETWORKAREA,
        0,
        rect,
        0,
      );

      if (success != 0) {
        final workArea = Rect.fromLTRB(
          rect.ref.left.toDouble(),
          rect.ref.top.toDouble(),
          rect.ref.right.toDouble(),
          rect.ref.bottom.toDouble(),
        );
        calloc.free(rect);
        return [workArea];
      }

      calloc.free(rect);
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to get monitor bounds, using fallback',
        e,
        stackTrace,
      );
    }

    // フォールバック
    return [Rect.fromLTWH(0, 0, 1920, 1080)];
  }

  /// ウィンドウが画面内の有効な位置にあるかチェック
  /// 最低50%が表示されていればtrueを返す
  bool isValidPosition(Rect windowBounds) {
    final monitors = getAllMonitorBounds();

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
        'Monitor: ${monitor}, Window: ${windowBounds}, Visible: ${(visibleRatio * 100).toStringAsFixed(1)}%',
      );

      if (visibleRatio >= 0.5) {
        return true;
      }
    }

    _logger.info('Window ${windowBounds} is off-screen or <50% visible');
    return false;
  }

  /// ウィンドウが画面外の場合、プライマリモニタ中央に補正
  /// 有効な位置ならそのまま返す、無効ならnullを返す（center: trueにフォールバック）
  Rect? adjustIfOffScreen(Rect windowBounds) {
    if (isValidPosition(windowBounds)) {
      return windowBounds;
    }

    _logger.info('Window ${windowBounds} adjusted to null (will use center)');
    return null; // centerフラグを使用してもらう
  }
}
