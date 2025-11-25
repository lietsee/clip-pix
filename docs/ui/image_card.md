# ImageCard 実装仕様（2025-10-26 時点）

最終更新: 2025-10-26  
対象コミット: `c44a51f`（fix: throttle grid geometry updates）

本書は `lib/ui/image_card.dart` に実装されているカードコンポーネントの仕様・挙動・描画フローを整理したものです。GridViewModule/ClipPix のリファクタ作業で参照できるよう、ユーザー操作とコールバックの関係、描画制御、既知の制約を詳細にまとめます。

## 1. 依存データと責務

| フィールド | 役割 |
|------------|------|
| `ImageItem item` | Hive 由来の画像メタデータ（`id`、`filePath` 等）。画像ロードキーとして利用。 |
| `GridCardViewState viewState` | `GridLayoutStore` から渡されるビュー状態。幅・高さ・スケール・列スパン・任意高さを保持。初期レイアウトを決定。 |
| `columnWidth / columnCount / columnGap` | 現在のグリッド列の寸法。リサイズスナップ計算に使用。 |
| `backgroundColor` | カード本体（Material Card）の塗色。グリッド背景とのコントラストを調整。 |
| `onResize / onSpanChange / onZoom` | ユーザー操作から `GridLayoutStore` へサイズ・列スパン・ズームを伝えるためのコールバック。 |
| `onRetry / onOpenPreview / onCopyImage` | 画像読み込みエラー、プレビュー表示、コピー操作のために呼び出される外部ハンドラ。 |
| `onReorder*` 系 | ドラッグ & ドロップでカード順序を変更する際のイベントフック。 |

ImageCard の責務は「単一画像の表示とインタラクション制御」。永続化やレイアウト再計算は親側（GridViewModule / GridLayoutStore）が担当する。

## 2. レイアウト構造

```
Focus
 └─ NotificationListener<ScrollNotification>
     └─ Listener (pointer events)
         └─ MouseRegion (カーソル切替)
             └─ ValueListenableBuilder<Size>  // _sizeNotifier
                 └─ SizedBox(width,height)
                     └─ Card (clip=antiAlias, elevation=2)
                         └─ Stack
                              ├─ _buildImageContent()  // Image＋オーバーレイ
                              └─ _buildHoverControls() // コピー・リサイズ・リオーダーハンドル
```

### 主要要素
- **フォーカス管理**: `FocusNode` でキーボードショートカット（Ctrl+±/Ctrl+C/Enter 等）を処理。
- **サイズ・スケール Notifier**: `ValueNotifier<Size>` と `ValueNotifier<double>` を内部に持ち、外部 `viewState` の変化を反映しつつユーザー操作による変更を即時反映。
- **Card コンテナ**: `backgroundColor` 指定の Material カード。描画領域は `Stack` で構 成。
- **Image レイヤ**: `Image.file` を `Transform` と `ClipRect` でラップ。ズーム・パンの行列を適用。
- **AnimatedSwitcher**: ローディング・エラー時のプレースホルダを切り替え（200ms）。
- **InkWell オーバーレイ**: タップ・ダブルタップでプレビューを開く。
- **Hover コントロール**: マウスホバーでコピーアイコン、右下リサイズハンドル、底部リオーダーハンドルを `AnimatedOpacity` でフェードイン。

## 3. ビジュアル状態 (`_CardVisualState`)

| 状態 | トリガ | 表示 |
|------|--------|------|
| `loading` | 初回ロード、再ロード、画像ストリーム chunk 受信時 | `_LoadingPlaceholder`（プログレスインジケータ） |
| `ready` | 画像デコード成功 | プレースホルダ非表示。`_loadingTimeout` を解除。 |
| `error` | ファイル不可／デコード失敗／タイムアウト | `_ErrorPlaceholder` を表示、リトライボタン（最大3回） |

`FileImage` の `ImageStream` を監視し、chunk 受信時に `loading` 継続、完了時に `ready` へ移行。一定時間進捗が無い場合 `_handleTimeoutRetry` でローカル再試行＋外部 `onRetry` を発火。

## 4. ユーザーインタラクション詳細

### 4.1 リサイズ（右下ハンドル）
- `GestureDetector` の `onPan*` で処理。
- つまみ更新中は `_isResizing = true`、リアルタイムで `_sizeNotifier` を更新。
- 横幅は列幅にスナップ:
  ```
  snappedSpan = round((width + gap) / (columnWidth + gap))
  snappedWidth = columnWidth * span + gap * (span - 1)
  ```
- 高さは 100〜1080、幅は 100〜1920 に clamp。
- 操作終了 (`onPanEnd`) 後に `onResize`, `onSpanChange` コールバックを呼ぶ。

### 4.2 ズーム & パン
- **マウス**: 右クリック押下中にホイールスクロール→指数関数的ズーム（`exp(-Δy / 300)`）。
- **キーボード**: `Ctrl` + `+`/`-`、`Ctrl` + `Shift` + `=` 等で ±0.1 ずつズーム。
- **パン**: 右クリック + ドラッグで有効。画像中央を基準に `clampPanOffset` で画角外へ出ないよう制限。
- ズーム時はフォーカス点（ホイール位置）を考慮してパン位置を補正。
- スケールは 0.5〜15.0 に clamp、更新時に `onZoom` で prefs レイヤへ保存要求。

### 4.3 コピー・プレビュー
- コピーアイコン（右上のボタン）クリック or `Ctrl+C` で `onCopyImage`。
- ダブルクリックでプレビュー (`onOpenPreview`)。シングルクリックはフォーカスのみ。
- `Enter`：プレビュー、`Shift+Enter`：サイズを 200×200 にリセットし `onResize`。

### 4.4 リオーダー
- 底部中央のドラッグハンドルで `onReorderPointerDown`／`onStartReorder`／`onReorderUpdate`／`onReorderEnd`。
- `GridViewModule` 側で `_GridEntry` を並べ替える。ドラッグ中は `AnimatedOpacity` で半透明化。

### 4.5 その他
- 右クリック押下状態を追跡し、ホイールズームと通常スクロールを分離 (`_consumeScroll`)。
- 画像ロード失敗時は `_handleRetry` が内部再ロード→外部 `onRetry`（Hive 更新／再走査）。

## 5. 画像描画の実装ポイント

1. **Transform**: `Matrix4` で平行移動→ズーム→逆移動。パン・ズーム位置は `_imageOffset` と `_currentScale` に依存。
2. **Caching**: `cacheWidth = (width * scale * devicePixelRatio).clamp(64,4096)`。ウィンドウ縮小時に画質がぼやけるのは、`cacheWidth` が頻繁に変動しストリームが更新され続ける点が影響。
3. **Gapless Playback**: `gaplessPlayback: true` によりズーム中の再描画でちらつきを抑制。ただしリサイズ連打時は古いフレームが残りやすい。
4. **ロード遅延対策**: `_setLoadingDeferred()` でフレーム後に状態更新。`_loadingTimeout` (タイムアウト処理) で stuck ローディングを検知。

## 6. コールバックとイベントフロー

```
ユーザー操作            内部状態                     外部通知
------------------------------------------------------------------------------------
右下ドラッグ            _sizeNotifier / _currentSpan -> onResize/onSpanChange
右クリック+ドラッグ     _imageOffset 更新             (通知なし)
右クリック+スクロール   _currentScale/_imageOffset -> onZoom
コピーアイコン          （状態変化なし）              onCopyImage
Retryボタン             _visualState=loading -> onRetry
ダブルクリック          (状態変化なし)               onOpenPreview
Enter / Shift+Enter     _sizeNotifier or onOpenPreview -> onResize / onOpenPreview
底部ドラッグハンドル     _isDragging フラグ            onReorder*
```

## 7. 既知の制約・課題

- **Semantics アサーション**: 連続リサイズ時に `!semantics.parentDataDirty` / `!childSemantics.renderObject._needsLayout` が発生。詳細は `docs/known_issue_grid_semantics.md` を参照。
- **画像ぼやけ**: ウィンドウ幅の急激な縮小で `cacheWidth` の再計算が追いつかず、暫定的に低解像でレンダリングされる場合がある。
- **プレビュー取り違え**: セマンティクス例外発生後に `_GridEntry` と `ImageCard` の対応が乱れるケースあり。現象は `GridViewModule` 側の再構築シーケンスと関連。

## 8. テストカバレッジ

- `test/ui/image_card_test.dart`
  - 列スパンスナップの挙動
  - ズーム時のスクロール抑制
  - `clampPanOffset` の境界テスト
- リオーダー・ズーム・リサイズに関わる統合テストは未整備。セマンティクス例外に直結する部分（AnimatedOpacity／Key の扱い）は今後のテスト追加が必要。

---

本ドキュメントはカード関連の仕様全体像を把握するためのベースライ ンとして運用します。動作が仕様と乖離する変更が入った際は、必ずここを更新し、関連テストも拡充してください。

