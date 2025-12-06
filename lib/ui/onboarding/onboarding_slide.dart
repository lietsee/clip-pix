import 'package:flutter/material.dart';

import 'onboarding_animations.dart';
import 'onboarding_slide_data.dart';

/// 個別のオンボーディングスライドウィジェット
class OnboardingSlide extends StatelessWidget {
  const OnboardingSlide({
    super.key,
    required this.data,
    required this.isActive,
  });

  /// スライドデータ
  final OnboardingSlideData data;

  /// このスライドがアクティブかどうか（表示中かどうか）
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48.0, vertical: 32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // アニメーションエリア（縦方向の60%）
          Expanded(
            flex: 6,
            child: Center(
              child: OnboardingAnimationWidget(
                icon: data.icon,
                iconColor: data.iconColor,
                animationType: data.animationType,
                isActive: isActive,
              ),
            ),
          ),
          const SizedBox(height: 32),
          // タイトル
          Text(
            data.title,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          // 説明文（縦方向の30%）
          Expanded(
            flex: 3,
            child: Text(
              data.description,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey[700],
                    height: 1.5,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
