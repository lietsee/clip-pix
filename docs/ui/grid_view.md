# GridView 詳細設計
最終更新: 2025-11-29

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
