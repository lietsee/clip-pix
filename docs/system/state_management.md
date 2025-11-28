# State Management 詳細設計
最終更新: 2025-11-27

## 1. 目的
Provider + StateNotifier を用いて、フォルダ選択・監視制御・UI 更新を一元管理する。

## 2. Provider ツリー構成
- `AppStateProvider` : ルートに配置し、下記 StateNotifier とサービスを公開。
- `SelectedFolderNotifier` : 選択フォルダと履歴を管理。
- `WatcherStatusNotifier` : FileWatcher / ClipboardMonitor の稼働状態を追跡。
- `ImageHistoryNotifier` : 直近保存した画像のメタ情報を保持。
- `ImageLibraryNotifier` : 表示中フォルダのコンテンツ一覧・読込状態を管理。
- `DeletionModeNotifier` : 一括削除モードの状態を管理（2025-11-27追加）。
- `ClipboardCopyService` : 画像/テキストコピー処理とガードトークンを管理。
- `ImageRepository` : ファイルシステムからのコンテンツ/メタデータ復元を担当。

## 3. SelectedFolderState
| フィールド | 型 | 説明 |
|-----------|----|------|
| `current` | `Directory?` | 現在選択中のフォルダ |
| `history` | `List<Directory>` | 直近3件までのフォルダ履歴 |
| `viewMode` | `FolderViewMode` | `root` または `subfolder` |
| `currentTab` | `String?` | 選択中のサブフォルダ名（`viewMode=subfolder` の時に有効） |
| `rootScrollOffset` | `double` | ルート表示時のスクロール位置 |
| `isValid` | `bool` | フォルダが存在し書き込み可能か |

### 3.1 アクション
- `pickFolder()` : `file_selector` でディレクトリを取得し、`current`/`history` 更新。`viewMode` を `root` に初期化。
- `switchToRoot()` : `viewMode` を `root` に変更し、`currentTab` を null に設定。
- `switchToSubfolder(String name)` : `viewMode=subfolder` とし、`currentTab` を更新。
- `updateRootScroll(double offset)` : ルート表示スクロール位置を保持。
- `clearFolder()` : フォルダを解除し、監視を停止。
- `restoreFromHive(HiveBox box)` : アプリ起動時に履歴と表示モードを復元。
- `persist()` : 状態更新毎に Hive へ保存。

## 4. WatcherStatusState
| フィールド | 型 | 説明 |
|-----------|----|------|
| `fileWatcherActive` | `bool` | FileWatcher 稼働フラグ |
| `clipboardActive` | `bool` | ClipboardMonitor 稼働フラグ |
| `lastError` | `String?` | 直近の異常メッセージ |

### 4.1 アクション
- `onFolderChanged(Directory?)` : フォルダ選択状態に応じて監視の開始/停止を指示。
- `setError(String message)` : エラー発生時に UI 通知を促す。
- `clearError()` : エラー解消時に呼び出す。

## 5. ImageHistoryState
| フィールド | 型 | 説明 |
|-----------|----|------|
| `entries` | `Queue<ImageEntry>` | 直近保存(最大20件)のメタ情報 |

`ImageEntry`
| フィールド | 型 | 説明 |
|-----------|----|------|
| `filePath` | `String` | 保存した画像パス |
| `metadataPath` | `String` | JSON メタデータのパス |
| `sourceType` | `String` | `web`/`local`/`unknown` |
| `savedAt` | `DateTime` | 保存時刻 |

### 5.1 アクション
- `addEntry(ImageEntry entry)` : 新規保存時に履歴へ追加し、Queue サイズを調整。
- `clear()` : 初期化または設定リセット時に履歴を破棄。

## 6. ImageLibraryState
| フィールド | 型 | 説明 |
|-----------|----|------|
| `activeDirectory` | `Directory?` | 現在表示しているフォルダ |
| `images` | `List<ContentItem>` | 表示対象コンテンツ（ImageItem / TextContentItem） |
| `isLoading` | `bool` | 読み込み中フラグ |
| `error` | `String?` | 直近のエラー |

### 6.1 アクション
- `loadForDirectory(Directory directory)` : フォルダ選択時に画像一覧をロード。
- `refresh()` : FileWatcher からの通知やユーザー操作で再読込。
- `addOrUpdate(File file)` : FileWatcher/ClipboardMonitor からの追加イベントで反映。
- `remove(String path)` : 削除イベントを反映。
- `clear()` : フォルダ解除時に状態を初期化。

- `SelectedFolderNotifier` : `hive_box.put('selected_folder', {...})` でフォルダ・履歴・`viewMode`・`currentTab`・`rootScrollOffset` を保存。
- `ImageHistoryNotifier` : オプションで `hive_box.put('image_history', ...)` 保存。既定はアプリ終了時のみ同期。
- `ImageLibraryNotifier` : 表示フォルダ変更や FileWatcher 通知ごとに `ImageRepository` を介して再構築し、必要に応じて Hive 永続化は行わない。
- Hive 初期化はアプリ起動時に `AppStateProvider` が実施し、復元時の例外はログに記録してデフォルト状態にフォールバック。

## 7. ClipboardCopyService 連携
- `AppStateProvider` で `ClipboardCopyService` をシングルトン生成し、`ClipboardMonitor` のガードインターフェースに登録。
- `ImageCard` / `ImagePreviewWindow` からの `onCopyImage` は `ClipboardCopyService.copyImage` を呼び出し、完了後にガードトークンを解除。
- `WatcherStatusNotifier` はコピー処理中に Monitor を停止させず、ガードトークン判定により自己トリガーを避ける。
- 最前面トグルなど他イベントとの競合が発生した場合は、Service 側で逐次処理キューに積み、重複コピーを防止。

## 8. UI 連携ポイント
- MainScreen : `SelectedFolderState` を監視し、AppBar ボタン表示と Tabs 再構築を行う。
- FileWatcher / ClipboardMonitor : `WatcherStatusNotifier` と `SelectedFolderNotifier` を購読し、開始/停止をコントロール。
- SnackbarController : `WatcherStatusState.lastError` を監視してユーザーに通知。

## 9. テスト方針
- StateNotifier のユニットテストで Hive モックを用い、履歴更新と復元を検証。
- ImageLibraryNotifier については一時ディレクトリを用いて `loadForDirectory` / `addOrUpdate` / `remove` の動作を確認。
- 監視フラグの切り替えは FileWatcher / ClipboardMonitor のスタブを使って `onFolderChanged` の呼び出し順序を確認。
- ImageHistory のサイズ制限 (最大20件) と FIFO 振る舞いをテスト。

---

## 9.5 DeletionModeNotifier (2025-11-27追加)

### 9.5.1 概要
一括削除モードの状態を管理する StateNotifier。複数カードを選択して一括削除する機能を提供。

**ファイル**: `lib/system/state/deletion_mode_notifier.dart`

### 9.5.2 DeletionModeState
| フィールド | 型 | 説明 |
|-----------|----|------|
| `isActive` | `bool` | 削除モードが有効か |
| `selectedCardIds` | `Set<String>` | 選択中のカードID集合 |
| `isDeleting` | `bool` | 削除処理実行中フラグ |

### 9.5.3 アクション
- `enterDeletionMode()` : 削除モードを有効化
- `exitDeletionMode()` : 削除モードを終了し、選択をクリア
- `toggleSelection(String cardId)` : カードの選択状態を切り替え
- `selectAll(List<String> cardIds)` : 全カードを選択
- `deselectAll()` : 全選択を解除
- `executeDelete(Function(List<String>) onDelete)` : 選択カードの削除を実行

### 9.5.4 便利プロパティ
```dart
bool get hasSelection => selectedCardIds.isNotEmpty;
int get selectedCount => selectedCardIds.length;
bool isSelected(String cardId) => selectedCardIds.contains(cardId);
```

### 9.5.5 UI連携
- **MainScreen**: AppBarに削除モードUI（選択数、実行ボタン、キャンセルボタン）を表示
- **ImageCard / TextCard**: 削除モード時にチェックボックスオーバーレイを表示
- **GridViewModule**: カードタップで `toggleSelection` を呼び出し

---

## 10. GridLayoutStore (2025-11-02追加)

### 10.1 概要
`GridLayoutStore`は`ChangeNotifier`を継承し、グリッドレイアウトのカード寸法・スケール・列設定を一元管理するストアです。

**ファイル**: `lib/system/state/grid_layout_store.dart`

**責務**:
- カードごとの幅・高さ・スケール・列スパン・カスタム高さを管理
- レイアウトエンジン（`GridLayoutLayoutEngine`）を用いてスナップショット生成
- Hive永続化レイヤー（`GridCardPreferencesRepository`）への書き込み
- Front/Back buffer パターンでレイアウト安定性を確保

### 10.2 主要APIと永続化タイミング

| メソッド | 用途 | 永続化 | スナップショット生成 |
|----------|------|--------|----------------------|
| `syncLibrary(List<ContentItem>)` | ImageLibraryからの同期 | × | ✓ (contentChanged時) |
| `updateGeometry(GridLayoutGeometry)` | ウィンドウリサイズ・列変更 | ✓ | ✓ |
| `updateCard({id, customSize, scale, columnSpan, offset})` | 個別カードリサイズ・パン | ✓ | ✓ |
| `applyBulkSpan(int span)` | 一括揃え | ✓ | × (invalidate) |
| `restoreSnapshot(GridLayoutSnapshot)` | Undo/Redo | ✓ | × (invalidate) |

### 10.3 Persistence Synchronization Pattern (2025-11-02)

**原則**: メモリとHiveを**常に同期**（Write-through cacheパターン）

#### 実装パターン
すべてのカード状態更新メソッドで以下のパターンを適用：

```dart
// 1. メモリ状態を更新
_viewStates[id] = nextState;

// 2. 永続化データを収集
final mutations = [...];
for (final state in result.viewStates) {
  mutations.add(_recordFromState(state));
}

// 3. Hiveに即座に永続化
if (mutations.isNotEmpty) {
  _persistence.saveBatch(mutations);
}

// 4. スナップショット再生成（必要な場合）
if (geometry != null) {
  final result = _layoutEngine.compute(...);
  _latestSnapshot = result.snapshot;
}

// 5. リスナーに通知（1回のみ）
notifyListeners();
```

#### 重要性
永続化を怠ると、後続の`syncLibrary()`呼び出しでHiveから**古い値**を読み込み、以下の問題が発生：

1. `contentChanged=true`が誤検出される（メモリ値とHive値の不一致）
2. 全カードがリビルドされ、視覚的にカード位置が変わる
3. ユーザー操作（お気に入りクリックなど）で意図しない並び替えが発生

**修正履歴** (commit 9925ac1):
- `updateGeometry()`に`saveBatch()`呼び出しを追加
- お気に入りクリック時のグリッド並び替えバグを解消

### 10.4 Snapshot Regeneration Pattern (2025-11-02)

**原則**: カード状態更新時は`_invalidateSnapshot()`ではなく**スナップショット再生成**

#### 実装パターン（updateCard例）
```dart
void updateCard({required String id, ...}) {
  // メモリ＋永続化
  _viewStates[id] = nextState;
  await _persistence.saveBatch([_recordFromState(nextState)]);

  // スナップショット再生成
  final geometry = _geometry;
  if (geometry != null) {
    final result = _layoutEngine.compute(
      geometry: geometry,
      states: orderedStates,
    );
    _previousSnapshot = _latestSnapshot;
    _latestSnapshot = result.snapshot;  // ← 新しいスナップショット
  }

  notifyListeners();
}
```

#### 効果
- ミニマップなどスナップショット消費者が**常に最新**を取得
- `latestSnapshot` getterが`null`を返さない
- スナップショットIDが変わるため、`shouldRepaint()`が正しく再描画を検出

**修正履歴** (commit 8225c71):
- `updateCard()`で`_invalidateSnapshot()`を削除、スナップショット再生成に変更
- カードリサイズ時のミニマップ更新バグを解消

### 10.5 関連コンポーネント
- `GridLayoutLayoutEngine`: レイアウト計算とスナップショット生成（`lib/system/grid_layout_layout_engine.dart`）
- `GridCardPreferencesRepository`: Hiveへのバッチ永続化（`lib/data/grid_card_preferences_repository.dart`）
- `GridLayoutSurface`: Front/Staging buffer管理（`lib/ui/widgets/grid_layout_surface.dart`）
- `GridViewModule`: Entry reconciliationとGridLayoutStore同期（`lib/ui/grid_view_module.dart`）

### 10.6 テスト方針
- `test/system/state/grid_layout_store_test.dart`: 永続化タイミングとスナップショット生成を検証
- `updateGeometry()`/`updateCard()`実行後にHiveモックで`saveBatch()`が呼ばれることを確認
- スナップショットIDが変わることを検証（`latestSnapshot?.id`の変化）
- `syncLibrary()`実行時に`contentChanged=false`となることを確認（永続化が正しく機能）

### 10.7 パンオフセット永続化 (2025-11-25追加)

#### 概要
画像カードのパン位置（右クリック+ドラッグでの画像移動）をHiveに永続化し、アプリ再起動後も復元。

#### データフロー
```
ImageCard._handlePointerUp
  → widget.onPan(id, offset)
  → GridViewModule._handlePan
  → GridLayoutStore.updateCard(id: id, offset: offset)
  → _persistence.saveBatch()
  → Hive永続化
```

#### GridCardViewStateの拡張
| フィールド | 型 | 説明 |
|------------|------|------|
| `offsetDx` | `double` | パンオフセットX |
| `offsetDy` | `double` | パンオフセットY |

#### updateGeometryでのオフセット保持
`GridLayoutLayoutEngine`はオフセットを追跡しないため、`updateGeometry()`で`_viewStates`を更新する際に既存のオフセットを保持：

```dart
final preservedState = existing != null
    ? GridCardViewState(
        id: state.id,
        width: state.width,
        height: state.height,
        scale: state.scale,
        columnSpan: state.columnSpan,
        customHeight: state.customHeight,
        offsetDx: existing.offsetDx,  // ← 既存値を保持
        offsetDy: existing.offsetDy,
      )
    : state;
```

**修正履歴** (commit f716f23):
- `updateGeometry()`でレイアウトエンジン結果をマージする際、パンオフセットを保持
- パン操作後に`updateGeometry()`が呼ばれてもオフセットがリセットされない
