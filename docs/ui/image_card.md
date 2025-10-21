# ImageCard 詳細設計

## 1. 概要
PinterestGrid (カスタム Sliver) 上に表示する単一画像カード。列幅単位のリサイズやズーム/パン、並べ替え操作を提供し、参考資料画像をシンプルにプレビューする。

## 2. 責務
- 画像サムネイルをプレビュー表示し、ロード中プレースホルダに切り替える。
- 右下リサイズハンドルの描画とドラッグ操作の検知（列幅単位で幅をスナップ）。
- 右クリック＋ホイールによるズーム操作を捕捉し、`onZoom` を発火。
- Shift+ドラッグによるパン操作（ズーム時）。
- エラー時のリトライ操作提供。
- 左ダブルクリック (または Enter キー) でプレビューウィンドウを起動。

## 3. 入出力
| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 入力 | item | `ImageItem` | 画像のパス/メタ情報を含むモデル |
| 入力 | sizeNotifier | `ValueNotifier<Size>` | 現在のカードサイズ |
| 入力 | scaleNotifier | `ValueNotifier<double>` | 現在のズーム倍率 |
| 入力 | columnWidth | `double` | 1 列分の幅 |
| 入力 | columnCount | `int` | カードが配置可能な列数 |
| 入力 | columnGap | `double` | 列間ギャップ |
| 出力 | onResize | `Function(String id, Size newSize)` | 新サイズのコールバック |
| 出力 | onSpanChange | `Function(String id, int span)` | 列スパン更新の通知 |
| 出力 | onZoom | `Function(String id, double scale)` | ズーム倍率のコールバック |
| 出力 | onRetry | `Function(String id)` | 読み込み失敗時のリトライ要求 |
| 出力 | onOpenPreview | `Function(ImageItem item)` | プレビューウィンドウ起動要求 |
| 出力 | onCopyImage | `Function(ImageItem item)` | 画像をクリップボードにコピーする要求 |
| 出力 | onStartReorder | `Function(String id, Offset globalPosition)` | 並べ替え開始通知 |
| 出力 | onReorderUpdate | `Function(String id, Offset globalPosition)` | 並べ替え中位置更新通知 |
| 出力 | onReorderEnd | `Function(String id)` | 並べ替え終了通知 |

## 4. 依存関係
- `ValueListenableBuilder`
- `GestureDetector` / `Listener`
- `Overlay`
- `Image.file`

## 5. UI レイアウト
```
┌─────────────────────────────┐
│ [プレビュー画像 (Transform + ClipRect)] │
│                     ┌─────┐ │ ←コピー/ズームボタンはホバーでフェードイン
│                     │ copy│ │
│                     └─────┘ │
│                             │
│              ┌───────┐      │ ←フッター中央にドラッグハンドル
│              │↕︎ drag│      │
│              └───────┘      │
│                             ◢ │ ←右下リサイズハンドル
└─────────────────────────────┘
```
- リサイズハンドルは 24×24px の半透明ボタン。
- コピー・ドラッグハンドル・リサイズハンドルはカーソルホバー時に 150ms でフェードイン。
- エラー時は中央にアイコン＋「再読み込み」ボタンを表示。

## 6. リサイズ仕様
- 幅は列スパン単位で変更。ドラッグ距離から最も近いスパンにスナップし、`onSpanChange` を通知。
- 高さは自由に変更可能（ドラッグ量に応じて `customHeight` として保存）。
- ドラッグ開始時に現在サイズとスパンを保存し、ドラッグ中は `sizeNotifier.value` を更新。ハンドル離脱で `onResize` / `onSpanChange` を発火。
- サイズの上下限: 最小 100×100 px、最大 1920×1080 px。
- グリッド列幅を超える要求は最も近いスパンに自動調整し、結果サイズを `sizeNotifier` に反映。
- リリース時に Hive へ永続化。

## 7. ズーム仕様
- 右クリック押下中にホイールが回転した場合のみ `onZoom` を発火。
- ズーム量: `scale += deltaY / 400`、範囲は 0.5〜3.0。
- ズーム結果は `scaleNotifier` に反映し、`Transform` + カスタムオフセットで描画。
- ズーム中はスクロールイベントを吸収し、ホイール位置を基準に画像を拡大（カーソル中心ズーム）。
- `Shift` キーを押しながら左ドラッグでパン。パン操作はズーム時にのみ有効。

## 8. 状態遷移
| 状態 | 表示内容 |
|------|----------|
| `loading` | プレースホルダ（シャマー）と進捗インジケータ |
| `ready` | 画像＋ホバー UI (コピー/ドラッグ/リサイズ) |
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
- `WidgetTest` で `sizeNotifier` / `scaleNotifier` を更新し、列幅スナップとズーム・パンが反映されることを確認。
- `GestureDetector` のドラッグ／ホイール操作をモックし、`onResize` / `onSpanChange` / `onZoom` の呼び出しを検証。
- 並べ替えハンドルのドラッグ開始とオーバーレイ表示をユニットテストで確認。
- Golden テストで `loading` / `ready` / `error` 状態を撮影。
