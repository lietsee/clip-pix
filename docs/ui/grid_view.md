# GridView 詳細設計
最終更新: 2025-11-30

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
| 入力 | imageList | `List<ContentItem>` | 表示対象コンテンツ（ImageItem / TextContentItem） |
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

---

## 12. Entry Reconciliation Decision (2025-11-02追加)

### 12.1 概要
`GridViewModule.didUpdateWidget()`は、`ImageLibraryState`の画像リストが変更されたときに`_entries`を更新します。更新方法は2つあります：

1. **`_reconcileEntries()`**: 追加/削除/並び替えを処理（フル更新）
2. **`_updateEntriesProperties()`**: 既存エントリーのプロパティのみ更新（軽量更新）

### 12.2 決定ロジック

**実装** (`lib/ui/grid_view_module.dart:172-180`):

```dart
final activeEntriesCount = _entries.where((e) => !e.isRemoving).length;
final itemCountChanged = widget.state.images.length != activeEntriesCount;
final willReconcile = _entries.isEmpty || orderChanged || itemCountChanged;

if (willReconcile) {
  _reconcileEntries(orderedImages);  // 追加/削除を処理
} else {
  _updateEntriesProperties(orderedImages);  // プロパティ更新のみ
}
```

**判定条件**:
- `_entries.isEmpty`: 初回ロード
- `orderChanged`: 既存アイテムの相対順序が変わった
- `itemCountChanged`: アイテム数が変わった（追加または削除） ← **2025-11-02追加**

### 12.3 修正履歴 (commit 62608ac)

**問題点**:
テキストファイルをクリップボードからコピーした際、アサーション失敗が発生：

```
assertion failed: _entries and GridLayoutStore.viewStates must have same IDs
missing_entries=[note_17.txt, note_18.txt, note_19.txt]
```

**根本原因**:
1. テキストファイルが末尾に追加される（既存順序は維持）
2. `orderChanged=false`と判定
3. `_updateEntriesProperties()`が呼ばれる
4. `_updateEntriesProperties()`は既存`_entries`のみループ → **新規エントリーが追加されない**
5. `GridLayoutStore.viewStates`は`syncLibrary()`で70アイテムに更新
6. アサーション: `_entries`=67、`viewStates`=70 → **不一致**

**修正内容**:
`itemCountChanged`チェックを追加：

```dart
// 旧実装 (buggy)
final willReconcile = _entries.isEmpty || orderChanged;

// 新実装 (fixed)
final activeEntriesCount = _entries.where((e) => !e.isRemoving).length;
final itemCountChanged = widget.state.images.length != activeEntriesCount;
final willReconcile = _entries.isEmpty || orderChanged || itemCountChanged;
```

**効果**:
- テキストファイル追加時も`_reconcileEntries()`が実行される
- 新しい3つのエントリーが`_entries`に追加される
- `_entries`と`viewStates`のID集合が一致
- アサーションが成功

### 12.4 `_reconcileEntries()` vs `_updateEntriesProperties()`

| メソッド | 実行条件 | 処理内容 |
|---------|---------|---------|
| `_reconcileEntries()` | `_entries.isEmpty \|\| orderChanged \|\| itemCountChanged` | - 既存エントリーと新しいアイテムリストを比較<br>- 新規アイテムを`_entries`に追加<br>- 削除されたアイテムを`isRemoving=true`に設定<br>- `setState()`でリビルド |
| `_updateEntriesProperties()` | `!willReconcile` | - 既存`_entries`のみループ<br>- `favorite`/`memo`/`filePath`変更を検出<br>- 変更されたエントリーの`version`をインクリメント<br>- `setState()`は**呼ばない**（ObjectKeyによる差分更新） |

### 12.5 パフォーマンス考慮

**`_reconcileEntries()`のコスト**:
- 全エントリーの再作成: O(n)
- `setState()`による全ウィジェットリビルド

**`_updateEntriesProperties()`のコスト**:
- 既存エントリーのプロパティ比較: O(n)
- `setState()`なし（ObjectKeyによる差分更新のみ）

**最適化**:
- お気に入りクリックなどプロパティのみ変更時は`_updateEntriesProperties()`を使用
- アイテム追加/削除時のみ`_reconcileEntries()`を使用
- これにより不要なリビルドを最小化

### 12.6 ディレクトリ切り替え時の_entries管理 (2025-11-29追加)

#### 問題
タブ切り替え時、古いディレクトリの`_entries`と新しいディレクトリの`images`が混在し、レンダリング破損が発生していた。

#### 解決策
1. **ディレクトリ変更の即座検出**: `didUpdateWidget` でディレクトリパス変更を検出
2. **_entriesの即座クリア**: 古いエントリーをすぐにクリアして不整合を防止
3. **p.dirname()によるマッチング**: `startsWith` の代わりに `p.dirname()` を使用して正確なディレクトリ判定

#### 実装 (commit e05ff54, 4072ed0)
```dart
// grid_view_module.dart didUpdateWidget
if (directoryChanged && widget.state.images.isNotEmpty) {
  final newDirPath = widget.state.activeDirectory?.path;
  if (newDirPath != null) {
    final imageParentDir = p.dirname(widget.state.images.first.id);
    final imagesMatchDirectory = imageParentDir == newDirPath;
    if (!imagesMatchDirectory) {
      return; // 画像がまだ古いディレクトリのもの → 次のdidUpdateWidgetを待つ
    }
  }
}
```

#### 関連修正
- **ミニマップの再作成** (commit 2817932): viewMode変更時に正しいScrollControllerでミニマップを再作成
- **hasClientsリトライ** (commit a75a96d): ScrollControllerにクライアントがアタッチされるまでリトライ

---

## 13. PinterestSliverGridレイアウトループ修正 (2025-11-30追加)

### 13.1 問題
ビューポート下部のカードが表示されないバグがあった。スクロールしてカード全体が画面中央付近に来るまで表示されないケースが発生。

### 13.2 根本原因
`PinterestSliverGrid`のレイアウトループ終了条件に問題があった。

**問題のあるコード（lib/ui/widgets/pinterest_grid.dart:273-276）**:
```dart
if (childEnd > targetEndScrollOffset) {
  reachedEnd = true;
  break;
}
```

Masonryグリッドではカードは**最も低いカラム**に配置されるが、このコードは**1つのカード**が`targetEndScrollOffset`を超えた時点でループを終了していた。そのため、高いカードが1つでもtargetを超えると、他のまだ低いカラムにカードが配置されずにスキップされていた。

### 13.3 解決策（commit f787070）

終了条件を「全カラムの最小高さがtargetを超えたら終了」に変更:

```dart
// Masonryグリッドでは次のカードは必ず最も低いカラムに配置される
// 全カラムの最小高さがtargetを超えたら、全カラムがビューポートをカバー済み
final double minColumnHeight = columnHeights.reduce(math.min);
if (minColumnHeight > targetEndScrollOffset) {
  reachedEnd = true;
  break;
}
```

### 13.4 図解

```
Column 0     Column 1     Column 2
+-------+    +-------+    +-------+
|Card 0 |    |Card 1 |    |Card 2 |
|高400  |    |高300  |    |高500  |
+-------+    +-------+    +-------+
|Card 3 |    |Card 4 |    |       |
|高300  |    |高600  |    |       |  ← 旧実装: Card 4のchildEnd > targetで終了
+-------+    +-------+    |       |     Column 2は高さ500でtarget(800)未満なのに
                         |       |     Card 5が配置されない！
                         +-------+
                         |Card 5 |  ← 新実装: minColumnHeight(500) < target(800)
                         |高300  |     なので継続、Card 5が配置される
                         +-------+
```

### 13.5 関連ファイル
- `lib/ui/widgets/pinterest_grid.dart` - `RenderSliverPinterestGrid.performLayout()`
- `docs/architecture/grid_rendering_pipeline.md` - レンダリングパイプライン詳細

---

## 14. ドラッグ中の自動スクロール機能 (2025-11-30追加)

### 14.1 概要
カードをドラッグ中に画面端へカーソルを移動すると、自動的にスクロールが開始される。これにより、画面外の位置へもカードを移動できる。

### 14.2 トリガーゾーン
- **上部ゾーン**: ビューポート上端から20%の領域 → 上方向へスクロール
- **下部ゾーン**: ビューポート下端から20%の領域 → 下方向へスクロール
- **中央領域**: 自動スクロールなし（通常のドラッグ操作）

### 14.3 スクロール速度
- 端に近いほど速くスクロール（線形補間）
- 最大速度: 10px/frame（約60fps = 600px/秒）
- 計算式: `speed = maxSpeed * (1.0 - distanceRatio)`
  - `distanceRatio`: ゾーン内での相対位置（0.0=端、1.0=ゾーン境界）

### 14.4 実装詳細（commit d75a74b）

**状態変数** (`lib/ui/grid_view_module.dart`):
```dart
Timer? _autoScrollTimer;        // 16ms周期のスクロールタイマー
double _autoScrollSpeed = 0;    // 現在のスクロール速度（px/frame）
Offset? _lastDragGlobalPosition; // 最後のカーソル位置（スクロール後のドロップ位置更新用）
```

**主要メソッド**:
| メソッド | 役割 |
|---------|------|
| `_checkAutoScroll(Offset)` | カーソル位置を判定し、スクロール開始/停止/速度更新を決定 |
| `_startAutoScroll(double)` | 16ms周期のタイマーを開始 |
| `_stopAutoScroll()` | タイマーをキャンセルし、速度をリセット |
| `_performAutoScroll()` | 実際のスクロール実行とドロップ位置の再計算 |

### 14.5 フロー図

```
_updateReorder(globalPosition)
       │
       ▼
_checkAutoScroll(globalPosition)
       │
       ├─ 上部20%ゾーン内? ──▶ _startAutoScroll(負の速度)
       │
       ├─ 下部20%ゾーン内? ──▶ _startAutoScroll(正の速度)
       │
       └─ 中央領域? ─────────▶ _stopAutoScroll()

_performAutoScroll() [16ms周期]
       │
       ├─ scrollController.jumpTo(newOffset)
       │
       └─ _updateDropTargetAfterScroll() ← ドロップ先を再計算
```

### 14.6 注意点
- **タイマー管理**: `_endReorder()`と`dispose()`で必ずタイマーをキャンセル
- **境界チェック**: スクロール位置は`minScrollExtent`〜`maxScrollExtent`にクランプ
- **ドロップ位置更新**: スクロール後は`_lastDragGlobalPosition`を使って新しいドロップ先を計算

---

## 15. スクロール＆ハイライト機能 (2025-11-30追加)

### 15.1 概要
`scrollToAndHighlight(String id)`メソッドにより、指定IDのカードにスクロールし、パルスアニメーションでハイライト表示する。

### 15.2 公開API

```dart
/// 指定IDのカードにスクロールし、ハイライト表示する
void scrollToAndHighlight(String id);
```

### 15.3 内部フロー

1. **ID検索**: `_entries`から`id`または`id`で終わる`filePath`を持つエントリーを検索
2. **Rect取得**: `GridLayoutStore.latestSnapshot`から該当カードの`Rect`を取得
3. **スクロール**: `ScrollController.animateTo()`でカードが画面中央付近に来るよう調整
4. **ハイライト設定**: `_highlightedId`をセットし、`setState()`で再ビルド
5. **自動解除**: 2秒後に`_highlightedId`をクリア

### 15.4 実装詳細

```dart
void scrollToAndHighlight(String id) {
  // 1. エントリー検索
  final entry = _entries.firstWhereOrNull(
    (e) => e.id == id || e.item.filePath.endsWith(id),
  );
  if (entry == null) return;

  // 2. スナップショットからRect取得
  final snapshot = gridLayoutStore.latestSnapshot;
  final rect = snapshot?.rects[entry.id];
  if (rect == null) return;

  // 3. スクロール位置計算
  final viewportHeight = widget.controller.position.viewportDimension;
  final targetOffset = rect.top - (viewportHeight / 2) + (rect.height / 2);

  // 4. スクロール実行
  widget.controller.animateTo(
    targetOffset.clamp(0.0, widget.controller.position.maxScrollExtent),
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeInOut,
  );

  // 5. ハイライト設定
  setState(() => _highlightedId = entry.id);

  // 6. 2秒後に解除
  Future.delayed(const Duration(seconds: 2), () {
    if (mounted && _highlightedId == entry.id) {
      setState(() => _highlightedId = null);
    }
  });
}
```

### 15.5 新規アイテム自動スクロール

`_reconcileEntries()`内で新規追加されたアイテムを検知し、自動的に`scrollToAndHighlight`を呼び出す。

**タイミングの工夫**:
- `_entries`に追加された後、2回の`addPostFrameCallback`で遅延実行
- 1回目: 現在フレームのレイアウト完了を待機
- 2回目: スナップショット更新を待機

```dart
// _reconcileEntries内
final List<String> newlyAddedIds = <String>[];
// ... アイテム追加時にnewlyAddedIds.add(item.id)

if (newlyAddedIds.isNotEmpty) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scrollToAndHighlight(newlyAddedIds.last);
    });
  });
}
```

### 15.6 関連コンポーネント
- **MainScreen._HistoryStrip**: Chipクリックで`scrollToAndHighlight`を呼び出し
- **ImageCard.isHighlighted**: ハイライト状態を受け取りパルスアニメーション表示
- **TextCard.isHighlighted**: 同上
