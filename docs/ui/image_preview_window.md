# ImagePreviewWindow 詳細設計

**最終更新**: 2025-12-06

## 1. 概要
ImageCard から起動される単独ウィンドウ。対象画像を等倍またはウィンドウ幅で表示し、最前面表示の切替と閉じる操作のみを提供する。

> **Note**: テキストファイル用のプレビューは `TextPreviewWindow` として別コンポーネントで提供されています。詳細は `lib/ui/text_preview_window.dart` を参照。

## 2. 表示要素
```
┌──────────────────────────────┐
│ [タイトルバー: ファイル名]         │
├──────────────────────────────┤
│ [画像プレビュー (Contain)]          │
│                                      │
│                                 ┌───┐│
│                                 │▲ ││ ← 最前面 ON/OFF トグル
│                                 └───┘│
│                                 ┌───┐│
│                                 │✕ ││ ← 閉じるボタン
│                                 └───┘│
└──────────────────────────────┘
```
- 最前面トグルはトグルボタンで、ON 時は強調色、OFF 時は通常色。
- 閉じるボタンは Window を破棄する。
- 画像以外の追加情報は表示しない。

## 3. 入出力
| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 入力 | item | `ImageItem` | 表示対象画像 |
| 入力 | initialAlwaysOnTop | `bool` | 起動時の最前面状態 (既定 false) |
| 出力 | onClose | `VoidCallback` | ウィンドウ閉鎖通知 |
| 出力 | onToggleAlwaysOnTop | `Function(bool isOn)` | 最前面状態変更通知 |
| 出力 | onCopyImage | `Function(ImageItem item)` | 画像をクリップボードにコピーする要求 |

## 4. 挙動
- ImageCard の左ダブルクリック／Enter で起動し、既に開いている場合はフォーカスを前面に移動。
- 画像はウィンドウのアスペクト比に合わせて `BoxFit.contain` で表示。
- 最前面トグル ON 時は Windows API (`SetWindowPos`) で `HWND_TOPMOST` に設定し、OFF で通常に戻す。
- 閉じるボタン、もしくは `Esc` キーでウィンドウを閉じる。

## 5. ショートカット
- `Esc` : ウィンドウを閉じる。
- `Ctrl+W` : 閉じる。
- `Ctrl+Shift+F` : 最前面トグル。
- `Ctrl+C` : 表示中の画像をクリップボードへコピー（ClipboardMonitor を明示的に抑止）。

## 6. エラーハンドリング
- 画像読み込み失敗時は灰色背景と「読み込み失敗」メッセージを表示し、`onClose` を即時通知。
- 最前面設定に失敗した場合は `./logs/app.log` にエラーを記録し、ボタンを OFF 状態に戻す。
- クリップボードへのコピーが失敗した場合は SnackBar で通知し、ログに `copy_failure` を記録。

## 7. テスト方針
- ウィンドウ生成／破棄をモックして、`onToggleAlwaysOnTop` イベントが正しく飛ぶか確認。
- 画像読み込み例外をシミュレートし、エラービューが表示されることを Golden テストで検証。
- 最前面トグルの状態が次回起動時に反映されるか（Hive 保存時のみ）を `StateNotifier` テストで確認。

## 8. 関連コンポーネント (2025-11-27追加)

### 8.1 プロセス管理
- **ImagePreviewProcessManager**: 画像プレビュープロセスのライフサイクル管理
- **OpenPreviewsRepository**: オープン中のプレビュー永続化

### 8.2 テキストプレビュー
テキストファイル（`.txt`）用のプレビューは以下のコンポーネントで提供：
- **TextPreviewWindow** (`lib/ui/text_preview_window.dart`)
- **TextPreviewProcessManager**: テキストプレビュープロセス管理

### 8.3 PDFプレビュー (2025-12-06追加)
PDFファイル（`.pdf`）用のプレビューは以下のコンポーネントで提供：
- **PdfPreviewWindow** (`lib/ui/widgets/pdf_preview_window.dart`)
- **PdfPreviewProcessManager**: PDFプレビュープロセス管理
- **詳細**: `docs/ui/pdf_card.md`

### 8.4 起動パターン
```
ImageCard.onOpenPreview
  → ImagePreviewProcessManager.launchPreview(imageItem)
  → Process.start(executable, ['--preview', jsonPayload, '--parent-pid', parentPid])
  → ImagePreviewWindow (別プロセス)
```

### 8.5 親プロセス監視による自動終了
プレビューウィンドウは別プロセスで起動されるため、メインアプリ終了時に孤児プロセスとなる問題がある。これを解決するため、親プロセスの生存監視を行う。

**仕組み:**
1. メインアプリがプレビュー起動時に `--parent-pid` 引数で自身のPIDを渡す
2. プレビューウィンドウは1秒ごとに親プロセスの存在を確認
3. 親プロセスが終了したことを検知したら `exit(0)` で自動終了

**プラットフォーム実装:**
| OS | 検出方法 | 応答速度 |
|----|----------|----------|
| Windows | Win32 `OpenProcess` + `GetExitCodeProcess` API | 数ミリ秒 |
| macOS | `ps -p $pid` コマンド | 数十ミリ秒 |

**コード位置:** `lib/main.dart` の `_isParentProcessAlive()` 関数

## 9. カスケード配置 (2025-12-03追加)

### 9.1 概要
複数のプレビューウィンドウを開く際、各ウィンドウを少しずつずらして配置する機能。ウィンドウの完全な重なりを防ぐ。

### 9.2 動作仕様
| 操作 | 配置方法 |
|------|----------|
| ダブルクリックで開く | カスケードオフセットを適用（保存位置がない場合） |
| アプリ再起動時の復元 | 保存された位置を使用（既存の動作） |
| 端に到達 | オフセットを原点(0, 0)にリセット |

### 9.3 オフセット設定
| パラメータ | 値 |
|------------|-----|
| ステップ量 | +20px（X, Y両方向） |
| 最大X | 400px |
| 最大Y | 300px |

### 9.4 実装詳細

**状態管理** (`lib/ui/grid_view_module.dart`):
```dart
static Offset _cascadeOffset = Offset.zero;
static const double _cascadeStep = 20.0;
static const double _cascadeMaxX = 400.0;
static const double _cascadeMaxY = 300.0;
```

**オフセット計算** (`_getNextCascadeOffset()`):
```dart
Offset _getNextCascadeOffset() {
  final current = _cascadeOffset;
  final newOffset = Offset(
    _cascadeOffset.dx + _cascadeStep,
    _cascadeOffset.dy + _cascadeStep,
  );
  // 最大値を超えたらリセット
  if (newOffset.dx > _cascadeMaxX || newOffset.dy > _cascadeMaxY) {
    _cascadeOffset = Offset.zero;
  } else {
    _cascadeOffset = newOffset;
  }
  return current;
}
```

**ペイロード**:
```dart
{
  // ... 既存フィールド
  'cascadeOffsetX': cascadeOffset.dx,
  'cascadeOffsetY': cascadeOffset.dy,
}
```

### 9.5 配置計算 (`lib/main.dart`)
1. `screen_retriever`で画面サイズを取得
2. ウィンドウを画面中央に配置する座標を計算
3. カスケードオフセットを加算
4. `windowManager.setPosition()`で位置を設定

### 9.6 図解
```
1枚目:              2枚目:              3枚目:
┌─────────┐        ┌─────────┐        ┌─────────┐
│ Preview │        │ Preview │        │ Preview │
│    1    │        │    2    │        │    3    │
└─────────┘        └─────────┘        └─────────┘
   (0,0)            (+20,+20)          (+40,+40)

最大到達後（リセット）:
┌─────────┐
│ Preview │ ← (0,0)に戻る
│   21    │
└─────────┘
```

### 9.7 関連ファイル
- `lib/ui/grid_view_module.dart`: `_cascadeOffset`, `_getNextCascadeOffset()`
- `lib/main.dart`: プレビュープロセスの位置設定ロジック
