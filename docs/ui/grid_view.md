# GridView 詳細設計

## 1. 概要
指定フォルダ内の画像を動的タイルで表示し、横幅ベースでラップ配置する。

## 2. 責務
- 画像カードの生成・配置・再描画。
- カードサイズ変更時のラップレイアウト再計算。
- マウスホイールでズーム。

## 3. 入出力
| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 入力 | imageList | `List<ImageItem>` | 表示対象画像情報 |
| 出力 | onResize | `Function(String id, Size newSize)` | サイズ変更通知 |
| 出力 | onZoom | `Function(String id, double scale)` | ズーム変更通知 |

## 4. 依存関係
- ImageCard
- Hive (サイズ・スケール記録)
- `SingleChildScrollView` / `Wrap`

## 5. エラーハンドリング
- 読み込み失敗画像はプレースホルダー表示。

## 6. 状態保持
- 各カードの `size` と `scale` を Hive に保存・復元。

## 7. レイアウト設計
- `SingleChildScrollView` 内で `Wrap` を用い、`spacing`/`runSpacing` は 12px。
- 各カードは保存済みの幅・高さで `SizedBox` 表示し、行内で自然に折り返す。
- ルート表示とサブフォルダ表示で同一レイアウトを共有し、スクロール位置はそれぞれ別の `ScrollController` で保持。

## 8. リサイズフロー
- 画像カードは各自 `ValueNotifier<Size>` を保持し、`ValueListenableBuilder` で幅・高さを更新。
- リサイズハンドル操作時に `onResize` を発火し、Hive に新サイズを書き込み後に `notifyListeners`。
- `Wrap` 再レイアウトにより横幅変更が即座に反映され、隣接カードの位置も再計算される。

## 9. ズーム操作
- ズームは右クリックを押下しながらマウスホイールを回転した場合にのみ有効。
- ズーム中はスクロールを抑制し、`onPointerSignal` で修飾キーを検出して `onZoom` を発火。
- ズーム倍率は `0.5`〜`3.0` を維持し、ズーム後にカードを再描画。

## 10. 画像読み込み戦略
- `Image.memory` / `Image.file` の `cacheWidth` をカードサイズに合わせて指定し、メモリ消費を抑制。
- Lazy Load は `MasonryGridView.builder` の `itemBuilder` で逐次ロードし、スクロール末尾 3 カード分で先読み。
- 読み込み失敗時はリトライボタン付きのプレースホルダを表示。

## 11. 差分更新
- FileWatcher から追加イベントを受け取った場合は、`imageList` へアイテム追加後に `setState` で更新。
- 削除イベントは対象カードをフェードアウトさせ、`AnimatedOpacity` 経由でリストから除去。
- ルート → サブフォルダ遷移時はキャッシュ済みのリストを保持し、戻る際に再利用。
