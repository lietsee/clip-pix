import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import 'interactive_guide_controller.dart';

/// ガイドオーバーレイウィジェット
/// 画面下部にステップカードを表示する
class GuideOverlay extends StatefulWidget {
  const GuideOverlay({
    super.key,
    required this.child,
    this.highlightKey,
  });

  final Widget child;
  final GlobalKey? highlightKey;

  @override
  State<GuideOverlay> createState() => _GuideOverlayState();
}

class _GuideOverlayState extends State<GuideOverlay> {
  bool _highlightReady = false;

  @override
  void didUpdateWidget(covariant GuideOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ハイライトキーが変わったらリセット
    if (oldWidget.highlightKey != widget.highlightKey) {
      _highlightReady = false;
      _scheduleHighlightCheck();
    }
  }

  void _scheduleHighlightCheck() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = widget.highlightKey;
      if (key == null) return;

      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      debugPrint('[GuideOverlay] _scheduleHighlightCheck: key=$key, context=${key.currentContext}, renderBox=$renderBox');
      if (renderBox != null) {
        setState(() {
          _highlightReady = true;
        });
      } else {
        // まだRenderBoxがない場合は再スケジュール
        _scheduleHighlightCheck();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<InteractiveGuideController>(
      builder: (context, guide, _) {
        // ガイドがアクティブになったらハイライトチェックをスケジュール
        if (guide.isInteractivePhase && widget.highlightKey != null && !_highlightReady) {
          _scheduleHighlightCheck();
        }

        return Stack(
          children: [
            widget.child,
            if (guide.isInteractivePhase) ...[
              // ハイライトキーがある場合は穴あきオーバーレイ、なければ通常オーバーレイ
              if (widget.highlightKey != null)
                _buildHighlightOverlay(context, widget.highlightKey!)
              else
                _buildBackgroundOverlay(context, guide),
              // ガイドカード
              _buildGuideCard(context, guide),
            ],
          ],
        );
      },
    );
  }

  Widget _buildBackgroundOverlay(
      BuildContext context, InteractiveGuideController guide) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Container(
          color: Colors.black.withOpacity(0.3),
        ),
      ),
    );
  }

  Widget _buildHighlightOverlay(BuildContext context, GlobalKey key) {
    // ハイライト対象のRenderBoxを取得
    final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
    // RenderBoxが取得できない場合は背景オーバーレイにフォールバック
    if (renderBox == null) {
      return Positioned.fill(
        child: IgnorePointer(
          ignoring: true,
          child: Container(
            color: Colors.black.withOpacity(0.3),
          ),
        ),
      );
    }

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    // ハイライト領域を少し広げる
    const padding = 8.0;
    final rect = Rect.fromLTWH(
      position.dx - padding,
      position.dy - padding,
      size.width + padding * 2,
      size.height + padding * 2,
    );

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: CustomPaint(
          painter: _HighlightPainter(
            highlightRect: rect,
            overlayColor: Colors.black.withOpacity(0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildGuideCard(
      BuildContext context, InteractiveGuideController guide) {
    final step = guide.currentStep;
    if (step == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Positioned(
      left: 16,
      right: 16,
      bottom: 32,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        color: isDark ? Colors.grey[850] : Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 進捗インジケーター
              Row(
                children: [
                  Text(
                    'ステップ ${guide.currentStepNumber}/${guide.totalInteractiveSteps}',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                  const Spacer(),
                  // 進捗ドット
                  Row(
                    children: List.generate(
                      guide.totalInteractiveSteps,
                      (index) => Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: index < guide.currentStepNumber
                              ? theme.colorScheme.primary
                              : (isDark ? Colors.grey[600] : Colors.grey[300]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // タイトル
              Text(
                step.title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              // 説明
              Text(
                step.description,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.grey[300] : Colors.grey[700],
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              // ボタン
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => guide.skip(),
                    child: Text(
                      'スキップ',
                      style: TextStyle(
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                      ),
                    ),
                  ),
                  if (step.phase == GuidePhase.imageSaveConfirm) ...[
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => guide.proceedToShowcase(),
                      child: const Text('次へ'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ハイライト用のカスタムペインター
/// 指定した矩形以外を暗くする
class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.highlightRect,
    required this.overlayColor,
  });

  final Rect highlightRect;
  final Color overlayColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = overlayColor;

    // 画面全体のパス
    final fullPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    // ハイライト領域のパス（角丸）
    final highlightPath = Path()
      ..addRRect(RRect.fromRectAndRadius(highlightRect, const Radius.circular(8)));

    // 差分を描画（ハイライト領域以外）
    final combinedPath = Path.combine(
      PathOperation.difference,
      fullPath,
      highlightPath,
    );

    canvas.drawPath(combinedPath, paint);
  }

  @override
  bool shouldRepaint(_HighlightPainter oldDelegate) {
    return highlightRect != oldDelegate.highlightRect ||
        overlayColor != oldDelegate.overlayColor;
  }
}
