# ImagePreviewWindow 詳細設計

**最終更新**: 2025-11-27

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

### 8.3 起動パターン
```
ImageCard.onOpenPreview
  → ImagePreviewProcessManager.launchPreview(imageItem)
  → Process.start(executable, ['--preview', jsonPayload])
  → ImagePreviewWindow (別プロセス)
```
