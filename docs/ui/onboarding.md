# オンボーディング（初回起動チュートリアル）

## 概要

初回起動時にフルスクリーンのスライド形式チュートリアルを表示する機能。横スワイプまたは「次へ」ボタンで進行し、アプリの主要機能を紹介する。

## ファイル構成

| ファイル | 役割 |
|---------|------|
| `lib/data/onboarding_repository.dart` | Hive永続化（表示フラグ管理） |
| `lib/ui/onboarding/onboarding_screen.dart` | メイン画面（PageView、ナビゲーション） |
| `lib/ui/onboarding/onboarding_slide.dart` | 個別スライドウィジェット |
| `lib/ui/onboarding/onboarding_animations.dart` | アニメーションウィジェット |
| `lib/ui/onboarding/onboarding_slide_data.dart` | スライドデータモデル |

## スライド構成（6枚）

1. **Welcome** - ClipPixへようこそ
2. **フォルダ選択** - 最初に保存フォルダを選択
3. **クリップボード監視** - 画像/テキストの自動保存機能
4. **グリッド操作** - リサイズ、ズーム、並び替え
5. **プレビュー** - ダブルクリックで大きく表示
6. **完了** - 設定から再表示可能

## クラス設計

### OnboardingRepository

```dart
class OnboardingRepository extends ChangeNotifier {
  OnboardingRepository(this._box);
  final Box<dynamic> _box;
  static const _key = 'onboarding_completed';

  bool get hasCompletedOnboarding => _box.get(_key, defaultValue: false) as bool;
  Future<void> setOnboardingCompleted(bool completed) async { ... }
  Future<void> resetOnboarding() async { ... }
}
```

### OnboardingScreen

- `PageController` で横スワイプ対応
- ドット型ページインジケーター
- 「戻る」「スキップ」「次へ」「始める」ボタン
- 最終ページに「次回から表示しない」チェックボックス
- 最小ウィンドウサイズ保証（800x750）

#### ナビゲーションボタン
| ページ | 表示ボタン |
|--------|-----------|
| 1ページ目 | 「次へ」のみ |
| 2～5ページ目 | 「戻る」+「次へ」 |
| 最終ページ | 「戻る」+「始める」 |

```dart
void _previousPage() {
  if (_currentPage > 0) {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }
}
```

### OnboardingAnimationWidget

4種類のアニメーション:
- `fadeIn` - フェードイン
- `slideUp` - 下からスライドアップ
- `scaleIn` - 拡大アニメーション
- `pulse` - パルス（繰り返し）

`SingleTickerProviderStateMixin` + `AnimationController` で実装。
将来的にLottieアニメーション差し替え可能な設計。

## main.dart統合

```dart
// Provider追加
ChangeNotifierProvider<OnboardingRepository>.value(
  value: onboardingRepo,
),

// 条件付きホーム
home: Consumer<OnboardingRepository>(
  builder: (context, repo, _) {
    if (!repo.hasCompletedOnboarding) {
      return OnboardingScreen(
        onComplete: () => repo.setOnboardingCompleted(true),
      );
    }
    return const MainScreen();
  },
),
```

## 設定ダイアログからの再表示

`grid_settings_dialog.dart` に「チュートリアルを再表示」ボタンを追加：

```dart
OutlinedButton.icon(
  onPressed: () async {
    await context.read<OnboardingRepository>().resetOnboarding();
    Navigator.of(context).pop();
  },
  icon: const Icon(Icons.help_outline),
  label: const Text('チュートリアルを再表示'),
),
```

## ウィンドウサイズ調整

チュートリアル表示時にウィンドウサイズが小さいと説明文が見切れるため、最小サイズを保証：

```dart
static const double _minWindowHeight = 600.0;
static const double _minWindowWidth = 800.0;

Future<void> _ensureMinimumWindowSize() async {
  try {
    await windowManager.ensureInitialized();
    final currentSize = await windowManager.getSize();
    // 最小サイズ未満なら自動リサイズ
    if (needsResize) {
      await windowManager.setSize(Size(newWidth, newHeight));
    }
  } catch (e) {
    debugPrint('[OnboardingScreen] Failed to resize window: $e');
  }
}
```

**注意**: `addPostFrameCallback`で最初のフレーム描画後に実行し、`windowManager.ensureInitialized()`を先に呼ぶ必要がある。

## Lottie差し替えパス

後からLottie対応する場合:
1. `lottie: ^2.7.0` を `pubspec.yaml` に追加
2. `OnboardingSlideData` に `lottieAsset` フィールド追加
3. `OnboardingAnimationWidget._buildIconContent()` でLottie優先表示
