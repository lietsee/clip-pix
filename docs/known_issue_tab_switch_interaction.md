# ディレクトリタブ切り替え後の操作不能バグ - 調査記録

最終更新: 2025-11-28
対象コミット: `04b746d`

## 問題の症状

- ディレクトリタブをクリックして移動後、以下が発生:
  - カードのホバーが効かない
  - リサイズができない
  - ホイールスクロールができない
- ルートタブに戻っても同様に操作不能
- セマンティクス削除より前から発生していたバグ

## 試行した修正と結果

### 修正1: `_forceReconciliation()` の追加（コミット 0f5d02d）

**変更内容**:
- `_lastViewDirectory` フィールドを `_GridViewModuleState` に追加
- `build()` で `SelectedFolderState.viewDirectory` の変更を検出
- 変更時に `postFrameCallback` で `_forceReconciliation()` を呼び出し

**結果**: 失敗

**ログ分析**:
```
[GridViewModule] viewDirectory changed: F:\fav_test -> F:\fav_test\goodpic, scheduling forceReconciliation
[GridViewModule] _forceReconciliation: triggered by viewDirectory change
[GridLayoutStore] syncLibrary_start: directoryPath=F:\fav_test  ← 古いパスのまま
[GridViewModule] _reconcileEntries: newItems=49  ← 古いディレクトリの49画像
...
[ImageRepository] build_image_item path=F:\fav_test\goodpic\09.jpg  ← 新画像はここでロード開始
```

**問題点**:
`_forceReconciliation()` 実行時点で `widget.state.images` はまだ古いディレクトリの画像だった。
`ImageLibraryState` の更新は `MainScreen._ensureDirectorySync()` → `loadForDirectory()` で非同期に行われるため、
`_forceReconciliation()` が呼ばれた時点では間に合わない。

### 修正2: ディレクトリ不一致時のローディング表示（コミット 04b746d）

**変更内容**:
- `_forceReconciliation()` 呼び出しを削除
- `build()` で `viewDirectory != activeDirectory` の場合にローディング表示を返す
- `_forceReconciliation()` メソッドを削除

```dart
// build() 内
final currentViewDirectory = selectedState.viewDirectory?.path;
final activeDirectory = widget.state.activeDirectory?.path;
if (currentViewDirectory != null &&
    activeDirectory != null &&
    currentViewDirectory != activeDirectory) {
  debugPrint('[GridViewModule] directory mismatch: '
      'view=$currentViewDirectory, active=$activeDirectory, showing loading');
  return const Center(child: CircularProgressIndicator());
}
```

**期待した動作**:
1. タブクリック → `viewDirectory` が即座に更新
2. `build()` で不一致を検出 → ローディング表示
3. `loadForDirectory()` で新画像ロード
4. `didUpdateWidget` で `imagesChanged=true` → reconciliation 実行
5. `build()` で一致 → 正常描画

**結果**: 失敗（同じ問題が継続）

## 現在の実装状態

### `lib/ui/grid_view_module.dart` の関連部分

1. **State フィールド** (行 103-106):
```dart
// Track viewDirectory from SelectedFolderState to detect tab changes
// (ImageLibraryState.activeDirectory updates asynchronously, so we need
// to detect changes directly from SelectedFolderState in build())
String? _lastViewDirectory;
```

2. **build() メソッド** (行 359-370):
```dart
// Detect directory mismatch between viewDirectory and activeDirectory
// When user switches tabs, viewDirectory updates immediately but images
// are loaded asynchronously. Show loading until images are ready.
final currentViewDirectory = selectedState.viewDirectory?.path;
final activeDirectory = widget.state.activeDirectory?.path;
if (currentViewDirectory != null &&
    activeDirectory != null &&
    currentViewDirectory != activeDirectory) {
  debugPrint('[GridViewModule] directory mismatch: '
      'view=$currentViewDirectory, active=$activeDirectory, showing loading');
  return const Center(child: CircularProgressIndicator());
}
_lastViewDirectory = currentViewDirectory;
```

3. **didUpdateWidget** (行 138-277):
- `directoryChanged` は `oldWidget.state.activeDirectory` と `widget.state.activeDirectory` を比較
- `imagesChanged` は ID セットの比較（順序は無視）
- `imagesChanged || directoryChanged` の場合に reconciliation 実行

## タイミング問題の詳細

```
タブクリック
    ↓
SelectedFolderNotifier.switchToSubfolder()
    ↓
SelectedFolderState.viewDirectory が即座に更新 (F:\fav_test → F:\fav_test\goodpic)
    ↓
MainScreen.didChangeDependencies() がトリガー
    ↓
GridViewModule.build() が呼ばれる
  - selectedState.viewDirectory = F:\fav_test\goodpic (新)
  - widget.state.activeDirectory = F:\fav_test (古)
  - 不一致 → ローディング表示
    ↓
MainScreen._ensureDirectorySync() の postFrameCallback
    ↓
loadForDirectory(F:\fav_test\goodpic)
    ↓
ImageLibraryNotifier.state 更新
  - activeDirectory = F:\fav_test\goodpic
  - images = 新ディレクトリの画像リスト
    ↓
GridViewModule.didUpdateWidget() が呼ばれる
  - oldWidget.state.activeDirectory = F:\fav_test\goodpic (前回の build 時の値?)
  - widget.state.activeDirectory = F:\fav_test\goodpic
  - directoryChanged = false ← ここが問題の可能性
    ↓
reconciliation がスキップされる?
```

## 未解明の点

1. **なぜ操作不能になるのか**:
   - `isMutating=false`, `shouldHideGrid=false` なので `IgnorePointer` は原因ではない
   - reconciliation は実行されているように見える（ログ上）
   - しかし操作は効かない

2. **考えられる原因候補**:
   - `_entries` と `GridLayoutStore.viewStates` の不整合
   - Widget Key の重複や不一致による再構築の失敗
   - ScrollController のライフサイクル問題
   - HitTest の問題（透明な Widget が上にある可能性）
   - `PinterestSliverGrid` 内部の状態問題

## 関連ファイル

- `lib/ui/grid_view_module.dart` - メイン修正対象
- `lib/ui/main_screen.dart` - `_ensureDirectorySync()` でディレクトリ同期
- `lib/system/state/selected_folder_notifier.dart` - タブ切り替え処理
- `lib/system/state/image_library_notifier.dart` - 画像ロード処理
- `lib/ui/widgets/pinterest_grid.dart` - グリッド描画
- `lib/ui/widgets/grid_layout_surface.dart` - レイアウト管理

## デバッグ用ログ出力ポイント

- `[GridViewModule] build: isMutating=..., shouldHideGrid=...`
- `[GridViewModule] directory mismatch: view=..., active=...`
- `[GridViewModule] didUpdateWidget: imagesChanged=..., directoryChanged=..., oldPath=..., newPath=...`
- `[GridViewModule] _reconcileEntries: newItems=..., currentEntries=...`
- `[MainScreen] didChangeDependencies: viewDirectory=..., _lastSyncedFolder=...`
- `[MainScreen] _ensureDirectorySync: viewDirectory=..., current=...`

## 調査のヒント

1. `flutter run` の `-v` オプションでより詳細なログを取得
2. Flutter DevTools の Widget Inspector で Widget ツリーを確認
3. `debugDumpRenderTree()` でレンダーツリーを確認
4. HitTest のデバッグ: `debugPaintPointersEnabled = true`
