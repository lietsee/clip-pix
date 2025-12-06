import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/onboarding_repository.dart';
import 'onboarding_slide.dart';
import 'onboarding_slide_data.dart';

/// フルスクリーンのオンボーディング画面
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onComplete,
  });

  /// オンボーディング完了時のコールバック
  final VoidCallback onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _dontShowAgain = false;

  /// 最小ウィンドウサイズ
  static const double _minWindowHeight = 750.0;
  static const double _minWindowWidth = 800.0;

  @override
  void initState() {
    super.initState();
    // 最初のフレーム描画後にウィンドウサイズをチェック
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureMinimumWindowSize();
    });
  }

  /// ウィンドウサイズが最小値未満なら自動リサイズ
  Future<void> _ensureMinimumWindowSize() async {
    try {
      // window_managerの初期化を待つ
      await windowManager.ensureInitialized();

      final currentSize = await windowManager.getSize();
      double newWidth = currentSize.width;
      double newHeight = currentSize.height;
      bool needsResize = false;

      if (currentSize.height < _minWindowHeight) {
        newHeight = _minWindowHeight;
        needsResize = true;
      }
      if (currentSize.width < _minWindowWidth) {
        newWidth = _minWindowWidth;
        needsResize = true;
      }

      if (needsResize) {
        await windowManager.setSize(Size(newWidth, newHeight));
      }
    } catch (e) {
      // window_manager初期化前の場合は無視
      debugPrint('[OnboardingScreen] Failed to resize window: $e');
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < onboardingSlides.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _completeOnboarding();
    }
  }

  void _skipToEnd() {
    _completeOnboarding();
  }

  Future<void> _completeOnboarding() async {
    if (_dontShowAgain) {
      await context.read<OnboardingRepository>().setOnboardingCompleted(true);
    }
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final isLastPage = _currentPage == onboardingSlides.length - 1;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // スキップボタン（右上）
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: TextButton(
                  onPressed: _skipToEnd,
                  child: const Text('スキップ'),
                ),
              ),
            ),
            // ページコンテンツ
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                },
                itemCount: onboardingSlides.length,
                itemBuilder: (context, index) {
                  return OnboardingSlide(
                    data: onboardingSlides[index],
                    isActive: index == _currentPage,
                  );
                },
              ),
            ),
            // 下部コントロール
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  // ページインジケーター（ドット）
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      onboardingSlides.length,
                      (index) => _PageDot(isActive: index == _currentPage),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // 「次回から表示しない」チェックボックス（最終ページのみ）
                  if (isLastPage)
                    CheckboxListTile(
                      value: _dontShowAgain,
                      onChanged: (value) {
                        setState(() {
                          _dontShowAgain = value ?? false;
                        });
                      },
                      title: const Text('次回から表示しない'),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                  const SizedBox(height: 16),
                  // 次へ / 始めるボタン
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _nextPage,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(isLastPage ? '始める' : '次へ'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ページインジケーターのドット
class _PageDot extends StatelessWidget {
  const _PageDot({required this.isActive});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: isActive ? 24 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: isActive ? Theme.of(context).primaryColor : Colors.grey[300],
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
