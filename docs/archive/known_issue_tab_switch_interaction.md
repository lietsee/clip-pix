# ディレクトリタブ切り替え後の操作不能バグ - 調査記録

**ステータス**: ✅ 解決済み (2025-11-29)
**最終更新**: 2025-11-29
**解決コミット**: `e05ff54`, `4072ed0`, `a75a96d`, `2817932`

## 解決サマリー

このバグは以下の修正で解決されました:

| コミット | 修正内容 |
|---------|---------|
| `e05ff54` | ディレクトリ変更時に `_entries` を即座にクリア（レンダリング破損防止） |
| `4072ed0` | `startsWith` → `p.dirname()` でディレクトリマッチング精度向上 |
| `a75a96d` | ミニマップ: ScrollControllerにクライアントがアタッチされた時のリトライ |
| `2817932` | ミニマップ: viewMode変更時に正しいScrollControllerで再作成 |

---

## 問題の症状（解決済み）

- ディレクトリタブをクリックして移動後、以下が発生:
  - カードのホバーが効かない
  - リサイズができない
  - ホイールスクロールができない
  - クリック時のヒットテスト可視化（青色表示）も出ない
- ルートタブに戻っても同様に操作不能
- セマンティクス削除より前から発生していたバグ

## 根本原因

### 問題1: _entries と images の不整合

タブ切り替え時、古いディレクトリの `_entries` と新しいディレクトリの `images` が混在し、レンダリング破損が発生。

**解決**: ディレクトリ変更時に `_entries` を即座にクリア（`e05ff54`）

### 問題2: ディレクトリマッチングの誤判定

`startsWith` を使用していたため、類似パス名で誤判定が発生。

**解決**: `p.dirname()` を使用した正確なディレクトリ判定（`4072ed0`）

### 問題3: ミニマップのScrollControllerミスマッチ

ルート→サブフォルダ切り替え時、ミニマップが古い `_rootScrollController` を使い続けていた。

**解決**: viewMode変更時にミニマップを再作成（`2817932`）

---

## 過去の調査記録（アーカイブ）

### 確認済みの事実

#### ヒットテスト可視化の結果

`debugPaintPointersEnabled = true` を `lib/main.dart` に追加して調査:

1. **アプリ起動直後（ルートディレクトリ）**: グリッド上でクリックすると全体が濃い青色で表示される（ヒットテスト成功）
2. **タブ切り替え後**: グリッド上でクリックしても青色表示が出ない（ヒットテストが届いていない？）
3. **タブバー**: 切り替え後もタブバーは正常に青色表示（タブバーへのヒットテストは成功）

#### MutationController の状態

- 最終状態: `isMutating=false`, `shouldHideGrid=false`
- `IgnorePointer` はイベントをブロックしていない

### 試行した修正と結果

#### 修正1: `_forceReconciliation()` の追加（コミット 0f5d02d）

**変更内容**:
- `_lastViewDirectory` フィールドを `_GridViewModuleState` に追加
- `build()` で `SelectedFolderState.viewDirectory` の変更を検出
- 変更時に `postFrameCallback` で `_forceReconciliation()` を呼び出し

**結果**: 失敗

#### 修正2: ディレクトリ不一致時のローディング表示（コミット 04b746d）

**変更内容**:
- `build()` で `viewDirectory != activeDirectory` の場合にローディング表示

**結果**: 失敗

#### 修正3: `didUpdateWidget` でのディレクトリ・画像整合性チェック（コミット da9e24d）

**結果**: 部分的に機能するが、問題は継続

#### 修正4: `MainScreen.build()` で `viewDirectory` 変更検出（コミット 96f501a）

**結果**: sync はトリガーされるようになったが、問題は継続

#### 修正5: `build()` の directory mismatch チェック強化（コミット dc40b78）

**結果**: 失敗（同じ問題が継続）

#### 修正6-9: 最終解決（コミット e05ff54, 4072ed0, a75a96d, 2817932）

**結果**: ✅ 解決

### 発見した重要な事実

#### ImageLibraryNotifier.loadForDirectory() の中間状態問題

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

## 関連ファイル

- `lib/ui/grid_view_module.dart` - 主要な修正対象
- `lib/ui/main_screen.dart` - `_ensureDirectorySync()` でディレクトリ同期
- `lib/system/state/selected_folder_notifier.dart` - タブ切り替え処理
- `lib/system/state/image_library_notifier.dart` - 画像ロード処理（中間状態問題の原因）
- `lib/ui/widgets/pinterest_grid.dart` - グリッド描画
- `lib/ui/widgets/grid_layout_surface.dart` - レイアウト管理
- `lib/ui/widgets/grid_minimap_overlay.dart` - ミニマップオーバーレイ
