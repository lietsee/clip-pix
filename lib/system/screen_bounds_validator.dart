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
  /// マルチモニタサポート：仮想画面の境界を返す
  ///
  /// Note: 個別のモニター列挙は EnumDisplayMonitors で可能だが、
  /// ここではシンプルに仮想スクリーン全体を返す。
  /// 実際の検証は isValidPosition で MonitorFromPoint を使って行う。
  List<Rect> getAllMonitorBounds() {
    if (!Platform.isWindows) {
      return [Rect.fromLTWH(0, 0, 1920, 1080)]; // デフォルト
    }

    try {
      // 仮想画面の境界を取得（すべてのモニタを含む）
      final xVirtual = GetSystemMetrics(SM_XVIRTUALSCREEN);
      final yVirtual = GetSystemMetrics(SM_YVIRTUALSCREEN);
      final cxVirtual = GetSystemMetrics(SM_CXVIRTUALSCREEN);
      final cyVirtual = GetSystemMetrics(SM_CYVIRTUALSCREEN);

      _logger.fine(
        'Virtual screen: x=$xVirtual, y=$yVirtual, width=$cxVirtual, height=$cyVirtual',
      );

      return [
        Rect.fromLTWH(
          xVirtual.toDouble(),
          yVirtual.toDouble(),
          cxVirtual.toDouble(),
          cyVirtual.toDouble(),
        ),
      ];
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to get virtual screen bounds, using default fallback',
        e,
        stackTrace,
      );
    }

    // 最終フォールバック
    return [Rect.fromLTWH(0, 0, 1920, 1080)];
  }

  /// ウィンドウが画面内の有効な位置にあるかチェック
  /// MonitorFromPoint を使って、ウィンドウの中心点と四隅がモニター上にあるかを確認
  bool isValidPosition(Rect windowBounds) {
    if (!Platform.isWindows) {
      return true; // 非Windows環境では常に有効とする
    }

    if (windowBounds.width <= 0 || windowBounds.height <= 0) {
      _logger.warning('Window bounds have invalid dimensions: $windowBounds');
      return false;
    }

    try {
      // ウィンドウの中心点を計算
      final centerX = (windowBounds.left + windowBounds.right) ~/ 2;
      final centerY = (windowBounds.top + windowBounds.bottom) ~/ 2;

      // MonitorFromPoint を使って中心点がモニター上にあるかチェック
      final point = calloc<POINT>();
      try {
        point.ref.x = centerX;
        point.ref.y = centerY;

        // MONITOR_DEFAULTTONULL: モニターが見つからない場合は NULL を返す
        final hMonitor = MonitorFromPoint(point.ref, MONITOR_DEFAULTTONULL);

        if (hMonitor == 0) {
          _logger.info(
            'Window center point ($centerX, $centerY) is not on any monitor',
          );
          return false;
        }

        // 追加チェック: ウィンドウの四隅のうち、少なくとも1つが
        // 仮想スクリーン内にあることを確認（より厳格な検証）
        final virtualBounds = getAllMonitorBounds().first;

        // ウィンドウの左上、右上、左下、右下のいずれかが仮想スクリーン内にあるか
        final topLeft = virtualBounds.contains(windowBounds.topLeft);
        final topRight = virtualBounds.contains(windowBounds.topRight);
        final bottomLeft = virtualBounds.contains(windowBounds.bottomLeft);
        final bottomRight = virtualBounds.contains(windowBounds.bottomRight);

        if (!topLeft && !topRight && !bottomLeft && !bottomRight) {
          _logger.info(
            'Window $windowBounds has no corners within virtual screen bounds $virtualBounds',
          );
          return false;
        }

        _logger.fine('Window $windowBounds is valid on monitor 0x${hMonitor.toRadixString(16)}');
        return true;
      } finally {
        calloc.free(point);
      }
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to validate window position, assuming invalid',
        e,
        stackTrace,
      );
      return false;
    }
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
