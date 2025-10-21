# GridView 詳細設計

## 1. 概要
指定フォルダ内の画像を Pinterest 風に配置し、カードの列スパン・高さを尊重したタイルレイアウトを提供する。

## 2. 責務
- 画像カードの生成・配置・再描画。
- カードサイズ変更時の列スパン再計算。
- マウスホイールでズーム。
- ドラッグ＆ドロップでカードの並び順を変更し、Hive に永続化する。

## 3. 入出力
| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 入力 | imageList | `List<ImageItem>` | 表示対象画像情報 |
| 出力 | onResize | `Function(String id, Size newSize)` | サイズ変更通知 |
| 出力 | onSpanChange | `Function(String id, int span)` | 列スパン変更通知 |
| 出力 | onZoom | `Function(String id, double scale)` | ズーム変更通知 |
| 出力 | onReorder | `Function(List<String> order)` | 並び順の永続化 |

## 4. 依存関係
- ImageCard
- Hive (サイズ・スケール・列スパン・並び順記録)
- `PinterestSliverGrid`（カスタム Sliver）
- Overlay（ドラッグプレビュー表示）

## 5. エラーハンドリング
- 読み込み失敗画像はプレースホルダー表示。

## 6. 状態保持
- 各カードの `size`、`scale`、`columnSpan`、`customHeight` を Hive に保存・復元。
- 並び順はディレクトリごとに保存し、起動時に復元。

## 7. レイアウト設計
- ビューポート幅から左右 12px のマージンを除いた領域にカラムを定義し、`PinterestSliverGrid` で高さの異なるカードを隙間なく配置する。
- カード間ギャップは 3px、上下余白は 12px。列スパンに応じてカード幅を決定する。
- ルート表示・サブフォルダ表示で同一レイアウトを共有し、スクロール位置はそれぞれ別の `ScrollController` で保持。

## 8. リサイズフロー
- 画像カードは各自 `ValueNotifier<Size>` を保持し、リサイズ中に列スパンへスナップ。確定時に `onResize` / `onSpanChange` を発火し Hive に保存。
- サイズ更新や列スパン変更時には `_entries` を再構成し、`PinterestSliverGrid` が最適列を再計算する。

## 9. ズーム & パン
- ズームは右クリック＋ホイール時にのみ有効。カーソル位置を中心に拡大縮小。
- ズーム中はスクロールを抑制し、`Shift` + ドラッグで画像をパン。
- ズーム倍率は `0.5`〜`3.0` を維持。

## 10. 画像読み込み戦略
- `Image.file` に `gaplessPlayback` を指定し、ズーム時の点滅を抑制。
- カード描画時に `cacheWidth` を列幅・ズーム倍率から算出して指定。
- 読み込み失敗時はリトライボタン付きのプレースホルダを表示。

## 11. 差分更新と並べ替え
- FileWatcher から追加イベントを受け取った場合は Hive 順序をマージしつつ `_entries` を更新。
- 削除イベントは対象カードをフェードアウトさせ、`AnimatedOpacity` 経由でリストから除去。
- 並べ替え時はドラッグ中カードをオーバーレイ表示させ、ドロップ後に Hive の order ボックスへ保存。
- ルート → サブフォルダ遷移時は保存済み順序を読み込み、戻る際に再利用。
