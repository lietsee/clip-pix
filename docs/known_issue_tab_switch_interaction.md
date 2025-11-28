# ディレクトリタブ切り替え後の操作不能バグ - 調査記録

最終更新: 2025-11-28
対象コミット: `dc40b78`

## 問題の症状

- ディレクトリタブをクリックして移動後、以下が発生:
  - カードのホバーが効かない
  - リサイズができない
  - ホイールスクロールができない
  - クリック時のヒットテスト可視化（青色表示）も出ない
- ルートタブに戻っても同様に操作不能
- セマンティクス削除より前から発生していたバグ

## 確認済みの事実

### ヒットテスト可視化の結果

`debugPaintPointersEnabled = true` を `lib/main.dart` に追加して調査:

1. **アプリ起動直後（ルートディレクトリ）**: グリッド上でクリックすると全体が濃い青色で表示される（ヒットテスト成功）
2. **タブ切り替え後**: グリッド上でクリックしても青色表示が出ない（ヒットテストが届いていない？）
3. **タブバー**: 切り替え後もタブバーは正常に青色表示（タブバーへのヒットテストは成功）

### MutationController の状態

- 最終状態: `isMutating=false`, `shouldHideGrid=false`
- `IgnorePointer` はイベントをブロックしていない

## 試行した修正と結果

### 修正1: `_forceReconciliation()` の追加（コミット 0f5d02d）

**変更内容**:
- `_lastViewDirectory` フィールドを `_GridViewModuleState` に追加
- `build()` で `SelectedFolderState.viewDirectory` の変更を検出
- 変更時に `postFrameCallback` で `_forceReconciliation()` を呼び出し

**結果**: 失敗

**問題点**:
`_forceReconciliation()` 実行時点で `widget.state.images` はまだ古いディレクトリの画像だった。

### 修正2: ディレクトリ不一致時のローディング表示（コミット 04b746d）

**変更内容**:
- `build()` で `viewDirectory != activeDirectory` の場合にローディング表示

**結果**: 失敗（`MainScreen.didChangeDependencies` で `context.read` を使用しているため変更検出できず）

### 修正3: `didUpdateWidget` でのディレクトリ・画像整合性チェック（コミット da9e24d）

**変更内容** (`lib/ui/grid_view_module.dart` 行 175-192):
```dart
// didUpdateWidget 内、if (imagesChanged || directoryChanged) { の直後
if (directoryChanged && widget.state.images.isNotEmpty) {
  final newDirPath = widget.state.activeDirectory?.path;
  if (newDirPath != null) {
    final firstImagePath = widget.state.images.first.id;
    final imagesMatchDirectory = firstImagePath.startsWith(newDirPath);

    if (!imagesMatchDirectory) {
      debugPrint('[GridViewModule] didUpdateWidget: skipping sync - '
          'images not yet updated for new directory. '
          'newPath=$newDirPath, firstImage=$firstImagePath');
      return; // 次の didUpdateWidget を待つ
    }
  }
}
```

**結果**: 部分的に機能（ログは出る）が、問題は継続

### 修正4: `MainScreen.build()` で `viewDirectory` 変更検出（コミット 96f501a）

**変更内容** (`lib/ui/main_screen.dart` 行 204-215):
```dart
// build() 内
final currentViewPath = selectedState.viewDirectory?.path;
if (_lastSyncedFolder != currentViewPath) {
  debugPrint('[MainScreen] build: viewDirectory changed, scheduling sync: '
      'old=$_lastSyncedFolder → new=$currentViewPath');
  _lastSyncedFolder = currentViewPath;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    _ensureDirectorySync(context, selectedState);
  });
}
```

**背景**:
以前は `didChangeDependencies` で `context.read<SelectedFolderState>()` を使用していたため、
`SelectedFolderState` の変更で `didChangeDependencies` が呼ばれなかった。
`build()` 内で `context.watch` を使用することで変更を検出可能に。

**結果**: sync はトリガーされるようになったが、問題は継続

### 修正5: `build()` の directory mismatch チェック強化（コミット dc40b78）

**変更内容** (`lib/ui/grid_view_module.dart` 行 378-405):
```dart
final currentViewDirectory = selectedState.viewDirectory?.path;
final activeDirectory = widget.state.activeDirectory?.path;

// Check 1: viewDirectory と activeDirectory の不一致
final directoriesMismatch = currentViewDirectory != null &&
    activeDirectory != null &&
    currentViewDirectory != activeDirectory;

// Check 2: images が activeDirectory に属しているか
bool imagesMismatch = false;
if (!directoriesMismatch &&
    activeDirectory != null &&
    widget.state.images.isNotEmpty) {
  final firstImagePath = widget.state.images.first.id;
  imagesMismatch = !firstImagePath.startsWith(activeDirectory);
}

if (directoriesMismatch || imagesMismatch) {
  debugPrint('[GridViewModule] directory mismatch: '
      'view=$currentViewDirectory, active=$activeDirectory, '
      'imagesMismatch=$imagesMismatch, showing loading');
  return const Center(child: CircularProgressIndicator());
}
```

**背景**:
`ImageLibraryNotifier.loadForDirectory()` は `activeDirectory` を即座に更新するが、
`images` は非同期でロードされる。この中間状態で `build()` が呼ばれると:
- `viewDirectory == activeDirectory` (両方 goodpic)
- しかし `images` はまだルートの画像

従来のチェックはパスしてしまうため、`images` の検証を追加。

**結果**: 失敗（同じ問題が継続）

## 現在の実装状態

### `lib/ui/grid_view_module.dart`

1. **didUpdateWidget** (行 175-192): ディレクトリ変更時に images の整合性をチェック
2. **build()** (行 378-405): `directoriesMismatch` と `imagesMismatch` の2段階チェック

### `lib/ui/main_screen.dart`

1. **build()** (行 204-215): `viewDirectory` 変更を検出して `_ensureDirectorySync` をスケジュール

### `lib/main.dart`

1. **debugPaintPointersEnabled = true**: ヒットテスト可視化が有効

## 発見した重要な事実

### ImageLibraryNotifier.loadForDirectory() の中間状態問題

```dart
// lib/system/state/image_library_notifier.dart 行 32-57
Future<void> loadForDirectory(Directory directory) async {
  state = state.copyWith(
    activeDirectory: directory,  // ← 即座に更新
    isLoading: true,
  );

  final images = await task;  // ← 非同期でロード

  state = state.copyWith(
    images: orderedImages,  // ← ロード完了後に更新
    activeDirectory: directory,
  );
}
```

この実装により:
1. `activeDirectory` が先に更新される
2. `images` はまだ古いディレクトリの画像リスト
3. この中間状態で `GridViewModule.build()` が呼ばれる可能性がある

## ログ出力ポイント

現在有効なログ:
- `[GridViewModule] build: isMutating=..., shouldHideGrid=...`
- `[GridViewModule] directory mismatch: view=..., active=..., imagesMismatch=...`
- `[GridViewModule] didUpdateWidget: imagesChanged=..., directoryChanged=...`
- `[GridViewModule] didUpdateWidget: skipping sync - images not yet updated...`
- `[MainScreen] build: viewDirectory changed, scheduling sync: ...`
- `[MainScreen] didChangeDependencies: viewDirectory=..., _lastSyncedFolder=...`
- `[MainScreen] _ensureDirectorySync: ...`
- `[ImageCard] onEnter/onExit: ...`
- `[ImageCard] onPointerDown: ...`

## 未解明の点

1. **なぜヒットテストが届かなくなるのか**:
   - `isMutating=false` なので `IgnorePointer` は原因ではない
   - ローディング表示が消えた後、グリッドは表示されている
   - しかしグリッド上でのクリックが検出されない

2. **考えられる原因候補**:
   - 透明な Widget がグリッドの上に被さっている？
   - `GridLayoutSurface` の Front/Back バッファの状態問題？
   - `PinterestSliverGrid` のレイアウト計算の問題？
   - `CustomScrollView` と `ScrollController` の状態問題？

## 関連ファイル

- `lib/ui/grid_view_module.dart` - 主要な修正対象
- `lib/ui/main_screen.dart` - `_ensureDirectorySync()` でディレクトリ同期
- `lib/system/state/selected_folder_notifier.dart` - タブ切り替え処理
- `lib/system/state/image_library_notifier.dart` - 画像ロード処理（中間状態問題の原因）
- `lib/ui/widgets/pinterest_grid.dart` - グリッド描画
- `lib/ui/widgets/grid_layout_surface.dart` - レイアウト管理

## 調査のヒント

1. `flutter run -d windows --profile` で DevTools を使用
2. Widget Inspector で Widget ツリーを確認
3. `debugDumpRenderTree()` でレンダーツリーを確認
4. タブ切り替え後の `GridLayoutSurface` の状態を確認
5. `_entries` と `GridLayoutStore.viewStates` の整合性を確認
