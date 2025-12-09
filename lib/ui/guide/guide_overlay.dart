import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import 'interactive_guide_controller.dart';

/// ガイドオーバーレイウィジェット
/// 画面下部にステップカードを表示する
class GuideOverlay extends StatefulWidget {
  const GuideOverlay({
    super.key,
    required this.child,
    this.highlightKeys,
  });

  final Widget child;
  final List<GlobalKey>? highlightKeys;

  @override
  State<GuideOverlay> createState() => _GuideOverlayState();
}

class _GuideOverlayState extends State<GuideOverlay> {
  bool _highlightReady = false;

  @override
  void didUpdateWidget(covariant GuideOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ハイライトキーが変わったらリセット
    if (!_keysEqual(oldWidget.highlightKeys, widget.highlightKeys)) {
      _highlightReady = false;
      _scheduleHighlightCheck();
    }
  }

  bool _keysEqual(List<GlobalKey>? a, List<GlobalKey>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _scheduleHighlightCheck() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final keys = widget.highlightKeys;
      if (keys == null || keys.isEmpty) return;

      // いずれかのキーでRenderBoxが取得できればOK
      bool anyReady = false;
      for (final key in keys) {
        final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
        debugPrint('[GuideOverlay] _scheduleHighlightCheck: key=$key, context=${key.currentContext}, renderBox=$renderBox');
        if (renderBox != null) {
          anyReady = true;
        }
      }

      if (anyReady) {
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
        final hasKeys = widget.highlightKeys != null && widget.highlightKeys!.isNotEmpty;
        if (guide.shouldShowGuideCard && hasKeys && !_highlightReady) {
          _scheduleHighlightCheck();
        }

        // カード操作フェーズかどうか判定
        final isCardOperationPhase = guide.phase == GuidePhase.cardResize ||
            guide.phase == GuidePhase.cardZoom ||
            guide.phase == GuidePhase.cardPan ||
            guide.phase == GuidePhase.cardPreview;

        return Stack(
          children: [
            widget.child,
            if (guide.shouldShowGuideCard) ...[
              // カード操作フェーズはオーバーレイなし（カードを自由に操作できるように）
              if (!isCardOperationPhase) ...[
                // ハイライトキーがある場合は穴あきオーバーレイ、なければ通常オーバーレイ
                if (hasKeys)
                  _buildHighlightOverlay(context, widget.highlightKeys!)
                else
                  _buildBackgroundOverlay(context, guide),
              ],
              // ガイドカード（常に表示）
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
      child: _TouchBlockingOverlay(
        allowedRects: const [],
        child: Container(
          color: Colors.black.withOpacity(0.3),
        ),
      ),
    );
  }

  Widget _buildHighlightOverlay(BuildContext context, List<GlobalKey> keys) {
    // ハイライト対象のRenderBoxを取得
    final rects = <Rect>[];
    const padding = 8.0;

    for (final key in keys) {
      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        final position = renderBox.localToGlobal(Offset.zero);
        final size = renderBox.size;
        rects.add(Rect.fromLTWH(
          position.dx - padding,
          position.dy - padding,
          size.width + padding * 2,
          size.height + padding * 2,
        ));
      }
    }

    // RenderBoxが取得できない場合は背景オーバーレイにフォールバック
    if (rects.isEmpty) {
      return Positioned.fill(
        child: _TouchBlockingOverlay(
          allowedRects: const [],
          child: Container(
            color: Colors.black.withOpacity(0.3),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: _TouchBlockingOverlay(
        allowedRects: rects,
        child: CustomPaint(
          painter: _HighlightPainter(
            highlightRects: rects,
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
    final isCompleted = guide.phase == GuidePhase.completed;

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
              // 進捗インジケーター（completedフェーズでは非表示）
              if (!isCompleted) ...[
                Row(
                  children: [
                    Text(
                      'ステップ ${guide.currentStepNumber}/${guide.totalInteractiveSteps - 1}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                      ),
                    ),
                    const Spacer(),
                    // 進捗ドット
                    Row(
                      children: List.generate(
                        guide.totalInteractiveSteps - 1, // completedステップは除外
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
              ],
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
                  // completedフェーズではスキップボタンを非表示
                  if (!isCompleted) ...[
                    TextButton(
                      onPressed: () => guide.skip(),
                      child: Text(
                        'スキップ',
                        style: TextStyle(
                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                  if (step.phase == GuidePhase.imageSaveConfirm) ...[
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => guide.proceedToShowcase(),
                      child: const Text('次へ'),
                    ),
                  ],
                  // completedフェーズでは完了ボタンを表示
                  if (isCompleted) ...[
                    ElevatedButton(
                      onPressed: () => guide.confirmComplete(),
                      child: Text(step.actionLabel ?? '完了'),
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
/// 指定した矩形以外を暗くする（複数矩形対応）
class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.highlightRects,
    required this.overlayColor,
  });

  final List<Rect> highlightRects;
  final Color overlayColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = overlayColor;

    // 画面全体のパス
    var resultPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    // 各ハイライト領域を穴として開ける
    for (final rect in highlightRects) {
      final highlightPath = Path()
        ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)));
      resultPath = Path.combine(
        PathOperation.difference,
        resultPath,
        highlightPath,
      );
    }

    canvas.drawPath(resultPath, paint);
  }

  @override
  bool shouldRepaint(_HighlightPainter oldDelegate) {
    if (highlightRects.length != oldDelegate.highlightRects.length) return true;
    for (var i = 0; i < highlightRects.length; i++) {
      if (highlightRects[i] != oldDelegate.highlightRects[i]) return true;
    }
    return overlayColor != oldDelegate.overlayColor;
  }
}

/// ハイライト領域以外のタッチをブロックするウィジェット
class _TouchBlockingOverlay extends SingleChildRenderObjectWidget {
  const _TouchBlockingOverlay({
    required this.allowedRects,
    super.child,
  });

  final List<Rect> allowedRects;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderTouchBlockingOverlay(allowedRects: allowedRects);
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderTouchBlockingOverlay renderObject) {
    renderObject.allowedRects = allowedRects;
  }
}

class _RenderTouchBlockingOverlay extends RenderProxyBox {
  _RenderTouchBlockingOverlay({required List<Rect> allowedRects})
      : _allowedRects = allowedRects;

  List<Rect> _allowedRects;
  set allowedRects(List<Rect> value) {
    _allowedRects = value;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // ハイライト領域内ならイベントを通過させる（false = 通過）
    for (final rect in _allowedRects) {
      if (rect.contains(position)) {
        return false;
      }
    }
    // それ以外はブロック（true = このウィジェットで消費）
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}
