# ImageCard 詳細設計

## 1. 概要
MasonryGridView 上に表示する単一画像カード。リサイズとズームに特化し、参考資料画像をシンプルにプレビューする。

## 2. 責務
- 画像サムネイルをプレビュー表示し、ロード中プレースホルダに切り替える。
- 右下リサイズハンドルの描画とドラッグ操作の検知。
- 右クリック＋ホイールによるズーム操作を捕捉し、`onZoom` を発火。
- エラー時のリトライ操作提供。
- 左ダブルクリック (または Enter キー) でプレビューウィンドウを起動。

## 3. 入出力
| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 入力 | item | `ImageItem` | 画像のパス/メタ情報を含むモデル |
| 入力 | sizeNotifier | `ValueNotifier<Size>` | 現在のカードサイズ |
| 入力 | scaleNotifier | `ValueNotifier<double>` | 現在のズーム倍率 |
| 出力 | onResize | `Function(String id, Size newSize)` | 新サイズのコールバック |
| 出力 | onZoom | `Function(String id, double scale)` | ズーム倍率のコールバック |
| 出力 | onRetry | `Function(String id)` | 読み込み失敗時のリトライ要求 |
| 出力 | onOpenPreview | `Function(ImageItem item)` | プレビューウィンドウ起動要求 |
| 出力 | onCopyImage | `Function(ImageItem item)` | 画像をクリップボードにコピーする要求 |

## 4. 依存関係
- `ValueListenableBuilder`
- `GestureDetector` / `Listener`
- `Image.file`
- `HoverBuilder` (独自ヘルパー予定)

## 5. UI レイアウト
```
┌─────────────────────────────┐
│ [プレビュー画像 (FittedBox)]        │
│                                     │
│                                     │
│                                     │
│                                     │
│                                     │
│                             ◢        │ ←右下リサイズハンドル
└─────────────────────────────┘
```
- ハンドルは 24×24px の半透明ボタン。
- 追加ラベルやフッターは表示せず、画像プレビューに集中。
- エラー時は中央にアイコン＋「再読み込み」ボタンを表示。

## 6. リサイズ仕様
- 右下ハンドルをドラッグした距離を基準に幅・高さを更新。
- ドラッグ開始時に現在サイズを保存し、MouseMove 毎に `sizeNotifier.value` を更新。
- サイズの上下限: 最小 100×100 px、最大 1920×1080 px。
- グリッドのカラム幅を超える要求は列幅に合わせて自動調整し、結果サイズを `sizeNotifier` に反映。
- リリース時に `onResize` を呼び、Hive へ永続化。

## 7. ズーム仕様
- 右クリック押下中にホイールが回転した場合のみ `onZoom` を発火。
- ズーム量: `scale += deltaY / 400`、範囲は 0.5〜3.0。
- ズーム結果は `scaleNotifier` に反映し、`Transform.scale` で描画。
- ズーム中はスクロールイベントを `Signal.stopPropagation()` 相当で抑止。

## 8. 状態遷移
| 状態 | 表示内容 |
|------|----------|
| `loading` | プレースホルダ（シャマー）と進捗インジケータ |
| `ready` | 画像＋リサイズハンドル |
| `error` | エラーアイコン + `再読み込み` ボタン + ログ記録 |

## 9. キーボード・アクセシビリティ
- カードフォーカス時に `Ctrl++` / `Ctrl+-` でズーム調整。
- `Enter` キーでプレビューウィンドウを開き、`Shift+Enter` でデフォルトサイズ (200×200) にリセット。
- `Ctrl+C` で `onCopyImage` を呼び出し、画像をクリップボードへ格納（ClipboardMonitor には通知しない）。
- ハンドルには `Semantics` ラベル「サイズ変更ハンドル」を付与。

## 10. エラーハンドリング
- 読み込み失敗時は `error` 状態に遷移し、`onRetry` で再読み込み要求。
- `onRetry` 実行後も失敗が続く場合は 3 回までリトライし、以降はログのみ。

## 11. テスト方針
- `WidgetTest` で `sizeNotifier`/`scaleNotifier` を更新し、レイアウトが反映されることを確認。
- `GestureDetector` のドラッグ／ホイール操作をモックし、`onResize`/`onZoom` の呼び出しを検証。
- Golden テストで `loading`/`ready`/`error` 状態を撮影。
