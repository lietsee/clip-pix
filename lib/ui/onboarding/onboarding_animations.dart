import 'package:flutter/material.dart';

import 'onboarding_slide_data.dart';

/// オンボーディング用アニメーションウィジェット
///
/// 各スライドのアイコンをアニメーション表示する。
/// 将来的にLottieに差し替え可能な設計。
class OnboardingAnimationWidget extends StatefulWidget {
  const OnboardingAnimationWidget({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.animationType,
    required this.isActive,
  });

  /// 表示するアイコン
  final IconData icon;

  /// アイコンの色
  final Color? iconColor;

  /// アニメーションタイプ
  final OnboardingAnimationType animationType;

  /// このスライドがアクティブかどうか（表示中かどうか）
  final bool isActive;

  @override
  State<OnboardingAnimationWidget> createState() =>
      _OnboardingAnimationWidgetState();
}

class _OnboardingAnimationWidgetState extends State<OnboardingAnimationWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _setupAnimation();

    // 初期表示時にアクティブならアニメーション開始
    if (widget.isActive) {
      _controller.forward();
    }
  }

  void _setupAnimation() {
    switch (widget.animationType) {
      case OnboardingAnimationType.fadeIn:
        _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOut),
        );
      case OnboardingAnimationType.slideUp:
        _animation = Tween<double>(begin: 50.0, end: 0.0).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
        );
      case OnboardingAnimationType.scaleIn:
        _animation = Tween<double>(begin: 0.5, end: 1.0).animate(
          CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
        );
      case OnboardingAnimationType.pulse:
        _animation = Tween<double>(begin: 0.9, end: 1.0).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
        );
    }
  }

  @override
  void didUpdateWidget(covariant OnboardingAnimationWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // スライドがアクティブになったらアニメーション開始
    if (widget.isActive && !oldWidget.isActive) {
      _controller.forward(from: 0.0);
    }
    // パルスアニメーションは繰り返し
    if (widget.animationType == OnboardingAnimationType.pulse &&
        widget.isActive) {
      _controller.repeat(reverse: true);
    } else if (!widget.isActive) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return _buildAnimatedChild(child!);
      },
      child: _buildIconContent(),
    );
  }

  Widget _buildAnimatedChild(Widget child) {
    switch (widget.animationType) {
      case OnboardingAnimationType.fadeIn:
        return Opacity(opacity: _animation.value.clamp(0.0, 1.0), child: child);
      case OnboardingAnimationType.slideUp:
        final progress = 1.0 - (_animation.value / 50.0);
        return Transform.translate(
          offset: Offset(0, _animation.value),
          child: Opacity(opacity: progress.clamp(0.0, 1.0), child: child),
        );
      case OnboardingAnimationType.scaleIn:
        return Transform.scale(scale: _animation.value, child: child);
      case OnboardingAnimationType.pulse:
        return Transform.scale(scale: _animation.value, child: child);
    }
  }

  Widget _buildIconContent() {
    final color = widget.iconColor ?? Theme.of(context).primaryColor;

    // TODO: 将来のLottie統合ポイント
    // if (widget.lottieAsset != null) {
    //   return Lottie.asset(
    //     widget.lottieAsset!,
    //     controller: _controller,
    //     onLoaded: (composition) {
    //       _controller.duration = composition.duration;
    //       if (widget.isActive) {
    //         _controller.forward();
    //       }
    //     },
    //   );
    // }

    return Container(
      width: 160,
      height: 160,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Icon(
        widget.icon,
        size: 80,
        color: color,
      ),
    );
  }
}
