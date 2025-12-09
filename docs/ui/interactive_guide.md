# インタラクティブガイド（操作ガイド）

**最終更新**: 2025-12-09

## 概要

初回起動時またはヘルプメニューから起動できるインタラクティブな操作ガイド。ユーザーが実際に操作を行うことで次のステップに進む体験型チュートリアル。

## ファイル構成

| ファイル | 役割 |
|---------|------|
| `lib/ui/guide/interactive_guide_controller.dart` | ガイドのステート管理（フェーズ遷移） |
| `lib/ui/guide/guide_overlay.dart` | ガイドカードUI、オーバーレイ表示 |
| `lib/ui/guide/guide_steps.dart` | GlobalKey管理、ShowCaseView用ステップ定義 |
| `lib/ui/guide/sample_image_window.dart` | サンプル画像表示ウィンドウ |

## ガイドフェーズ

```dart
enum GuidePhase {
  notStarted,       // 0: ガイド未開始
  folderSelection,  // 1: フォルダ選択待ち
  clipboardToggle,  // 2: クリップボード監視ON待ち
  sampleImageCopy,  // 3: サンプル画像コピー待ち
  imageSaveConfirm, // 4: 画像保存確認
  cardResize,       // 5: カードリサイズ体験
  cardZoom,         // 6: カードズーム体験
  cardPan,          // 7: カードパン体験
  cardPreview,      // 8: カードプレビュー体験
  uiShowcase,       // 9: ShowCaseView UIガイド
  completed,        // 10: ガイド完了
}
```

## フェーズ遷移フロー

```
notStarted
    │
    ▼ start()
folderSelection ──► clipboardToggle ──► sampleImageCopy ──► imageSaveConfirm
    │                    │                    │                    │
    │ onFolderSelected() │ onClipboardEnabled()│ onImageSaved()    │ proceedToShowcase()
    ▼                    ▼                    ▼                    ▼
                                                                uiShowcase
                                                                    │
                                                    onShowcaseComplete()
                                                                    ▼
cardResize ──► cardZoom ──► cardPan ──► cardPreview ──► completed
    │              │            │            │              │
    │onCardResized()│onCardZoomed()│onCardPanned()│onPreviewOpened()│confirmComplete()
                                                                    ▼
                                                               notStarted (リセット)
```

## InteractiveGuideController

### 主要プロパティ

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `phase` | `GuidePhase` | 現在のフェーズ |
| `isActive` | `bool` | notStarted/completed以外でtrue |
| `isInteractivePhase` | `bool` | folderSelection〜cardPreviewでtrue |
| `shouldShowGuideCard` | `bool` | ガイドカード表示が必要な場合true |
| `currentStep` | `InteractiveGuideStep?` | 現在のステップ情報 |
| `currentStepNumber` | `int` | 現在のステップ番号（1-indexed） |
| `totalInteractiveSteps` | `int` | インタラクティブステップの総数 |

### 主要メソッド

| メソッド | 説明 |
|---------|------|
| `start()` | ガイドを開始（条件に応じて開始フェーズを決定） |
| `skip()` | ガイドをスキップしてcompletedへ |
| `reset()` | ガイドをリセットしてnotStartedへ |
| `confirmComplete()` | 完了確認後にリセット |

### カード操作検出

カードのズーム/パン操作は、操作中ではなく**右クリックを離した時点**で完了判定を行う。これにより、ズーム後にカーソルが動いてもパンが誤検出されない。

```dart
// ImageCard
void _handlePointerUp(PointerUpEvent event) {
  widget.onRightClickReleased?.call(
    widget.item.id,
    didZoom: _didZoomThisSession,
    didPan: _didPanThisSession,
  );
  _didZoomThisSession = false;
  _didPanThisSession = false;
}

// GridViewModule
void _handleRightClickReleased(String id, {required bool didZoom, required bool didPan}) {
  final guide = context.read<InteractiveGuideController>();
  if (guide.phase == GuidePhase.cardZoom && didZoom) {
    guide.onCardZoomed();
  }
  if (guide.phase == GuidePhase.cardPan && didPan) {
    guide.onCardPanned();
  }
}
```

## GuideOverlay

### UI構造

```
Stack
├── child (メインコンテンツ)
├── ハイライトオーバーレイ（カード操作フェーズ以外）
│   └── _TouchBlockingOverlay + _HighlightPainter
└── ガイドカード（画面下部）
    ├── 進捗インジケーター（ステップX/X + ドット）
    ├── タイトル
    ├── 説明文
    └── ボタン行（スキップ / 次へ / 完了）
```

### ガイドカード表示

| フェーズ | 進捗表示 | スキップ | アクションボタン |
|---------|---------|---------|-----------------|
| インタラクティブフェーズ | あり | あり | フェーズによる |
| imageSaveConfirm | あり | あり | 「次へ」 |
| completed | なし | なし | 「完了」 |

### タッチブロッキング

ハイライト領域以外のタッチをブロックする`_TouchBlockingOverlay`:

```dart
class _RenderTouchBlockingOverlay extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // ハイライト領域内ならイベントを通過させる
    for (final rect in _allowedRects) {
      if (rect.contains(position)) {
        return false;
      }
    }
    // それ以外はブロック
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}
```

**注意**: カード操作フェーズ（cardResize/cardZoom/cardPan/cardPreview）ではオーバーレイを表示しない。Sliver内のウィジェットはRenderBox取得が不安定なため。

## ステップ定義

```dart
const List<InteractiveGuideStep> interactiveGuideSteps = [
  InteractiveGuideStep(
    phase: GuidePhase.folderSelection,
    title: 'フォルダを選択',
    description: '画像を保存するフォルダを選択してください。\n右上のフォルダボタンまたは中央のボタンをクリック！',
    actionLabel: 'フォルダ選択',
  ),
  // ... 中略 ...
  InteractiveGuideStep(
    phase: GuidePhase.completed,
    title: 'ガイド完了！',
    description: 'これでClipPixの基本操作は完了です。\n自由に画像を管理してください！',
    actionLabel: '完了',
  ),
];
```

## main_screen.dartとの連携

### ガイド開始

```dart
void _startGuide() {
  final guide = context.read<InteractiveGuideController>();
  final selected = context.read<SelectedFolderNotifier>().state;
  final watcher = context.read<WatcherStatusNotifier>().state;

  guide.start(
    hasFolderSelected: selected.selectedFolder != null,
    isClipboardRunning: watcher.isClipboardRunning,
  );
}
```

### 完了時の永続化

```dart
void _onGuideComplete() {
  context.read<OnboardingRepository>().setOnboardingCompleted(true);
}
```

## ShowCaseView（UIショーケース）

`uiShowcase`フェーズでは`showcaseview`パッケージを使用してUI要素をハイライト表示：

- フォルダ選択ボタン
- クリップボード監視スイッチ
- 新規テキストボタン
- ミニマップボタン
- 設定ボタン
- グリッドエリア

ShowCaseView完了後、カード操作フェーズ（cardResize〜cardPreview）に進む。
