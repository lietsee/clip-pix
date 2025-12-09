import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// サンプル画像ウィンドウ
/// ユーザーにコピーさせるための画像を表示するダイアログ
class SampleImageWindow extends StatefulWidget {
  const SampleImageWindow({super.key});

  /// ダイアログを表示
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (context) => const SampleImageWindow(),
    );
  }

  @override
  State<SampleImageWindow> createState() => _SampleImageWindowState();
}

class _SampleImageWindowState extends State<SampleImageWindow> {
  final GlobalKey _imageKey = GlobalKey();
  bool _isCopying = false;
  bool _showCopiedMessage = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey[850] : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // タイトル
            Text(
              'この画像をコピーしてください',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 20),
            // サンプル画像（アプリアイコン）
            GestureDetector(
              onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition),
              child: RepaintBoundary(
                key: _imageKey,
                child: Container(
                  width: 128,
                  height: 128,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark ? Colors.grey[700]! : Colors.grey[300]!,
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.asset(
                      'assets/icon/icon.png',
                      width: 128,
                      height: 128,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        // アイコンがない場合のフォールバック
                        return Container(
                          color: theme.colorScheme.primary,
                          child: const Icon(
                            Icons.photo_library,
                            size: 64,
                            color: Colors.white,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 操作説明
            Text(
              Platform.isMacOS ? '⌘+C または右クリック→コピー' : 'Ctrl+C または右クリック→コピー',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.grey[400] : Colors.grey[600],
              ),
            ),
            if (_showCopiedMessage) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 16),
                    SizedBox(width: 6),
                    Text(
                      'コピーしました！',
                      style: TextStyle(color: Colors.green, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            // コピーボタン
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isCopying ? null : _copyImage,
                icon: _isCopying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.content_copy),
                label: Text(_isCopying ? 'コピー中...' : '画像をコピー'),
              ),
            ),
            const SizedBox(height: 8),
            // 閉じるボタン
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                '閉じる',
                style: TextStyle(
                  color: isDark ? Colors.grey[400] : Colors.grey[600],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset globalPosition) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.content_copy, size: 18),
              SizedBox(width: 8),
              Text('コピー'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'copy') {
        _copyImage();
      }
    });
  }

  Future<void> _copyImage() async {
    if (_isCopying) return;

    setState(() {
      _isCopying = true;
      _showCopiedMessage = false;
    });

    try {
      // RepaintBoundaryから画像をキャプチャ
      final boundary =
          _imageKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        debugPrint('[SampleImageWindow] Failed to find RenderRepaintBoundary');
        return;
      }

      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        debugPrint('[SampleImageWindow] Failed to convert image to bytes');
        return;
      }

      final bytes = byteData.buffer.asUint8List();

      // クリップボードに画像をコピー（プラットフォーム固有の処理が必要）
      await _copyImageToClipboard(bytes);

      setState(() {
        _showCopiedMessage = true;
      });

      debugPrint('[SampleImageWindow] Image copied to clipboard');

      // 少し待ってからダイアログを閉じる
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('[SampleImageWindow] Error copying image: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isCopying = false;
        });
      }
    }
  }

  /// クリップボードに画像をコピー
  Future<void> _copyImageToClipboard(Uint8List bytes) async {
    // MethodChannelを使ってネイティブコードで画像をコピー
    const channel = MethodChannel('com.clip_pix/clipboard');
    await channel.invokeMethod<void>('writeImage', {'data': bytes});
  }
}
