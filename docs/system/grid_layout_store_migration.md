# GridLayoutStore バッチ適用方式導入計画
最終更新: 2025-11-02

## 目的
- グリッド列変更・一括揃え時に発生している RenderObject セマンティクスアサーション（`docs/known_issue_grid_semantics.md`）を解消する。
- 各カードが個別の `ValueNotifier` に依存している現行構造を見直し、レイアウト更新をバッチ適用に統一して `notifyListeners()` 回数を最小化する。
- 将来のグリッド設定/整列機能拡張に向けて、状態管理をサービス層に集約しテスト容易性を高める。

## 実装状況 (2025-11-02更新)

### ✅ 完了した改善
GridLayoutStore移行計画の一環として、以下の重要なバグ修正が完了しました：

1. **スナップショット再生成パターンの確立** (commit 8225c71)
   - `updateCard()`でのスナップショット無効化問題を解決
   - ミニマップ更新バグを修正
   - 詳細: [Snapshot Regeneration Pattern](#snapshot-regeneration-pattern-2025-11-02)

2. **永続化同期の徹底** (commit 9925ac1)
   - `updateGeometry()`でのHive永続化漏れを修正
   - お気に入りクリック時のグリッド並び替えバグを解決
   - 詳細: [Persistence Synchronization](#persistence-synchronization-2025-11-02)

3. **Entry Reconciliation ロジックの改善** (commit 62608ac)
   - テキストファイル追加時のアサーション失敗を修正
   - `itemCountChanged`検出を追加
   - 詳細: `docs/ui/grid_view.md`

### 🚧 進行中の課題
- Semanticsツリー最適化（Front/Back buffer安定化）
- GeometryMutationQueue統合

## 現状整理
- `lib/ui/grid_view_module.dart` がカードごとに `_sizeNotifiers` / `_scaleNotifiers` を動的生成し、Provider 経由で `ImageLibraryState`（`ImageLibraryNotifier`）を再読込。
- 一括揃え (`GridResizeController`) は各カードの Notifier を逐次更新するため、同一フレーム内で大量の `notifyListeners` が発火 → Semantics ツリーがレイアウト途中で再評価されアサーションが起きる。
- Hive 永続化 (`GridCardPreferencesRepository`) は個別カード単位でサイズ/スケールを保存。バッチ更新時もカード単位で `saveSize` が走り、I/O が密集。

## 目標アーキテクチャ概要
- `GridLayoutStore`（仮称）を `lib/system/state/` 配下に追加し、`ChangeNotifier` としてグリッド寸法・スケール・列設定を一元管理。
- カード UI は `Selector<GridLayoutStore, GridCardViewState>` などで自カードのビュー状態のみ購読。`ValueListenableBuilder` の階層を廃止。
- 列変更/一括揃え/ドラッグリサイズは `GridLayoutStore` がコマンドを受け、内部で「ドラフト状態を計算 → 永続層へバッチ保存 → `notifyListeners()` 1 回」で commit。
- `GridResizeController` は store を介して snapshot を取得・適用し、Undo/Redo を store 主導に刷新。

## 導入ステップ（テスト先行）
1. **テスト要件の明文化**
   - `docs/system/state_management.md` を更新し、`GridLayoutStore` の責務・API・スナップショット仕様を追加。
   - セマンティクス崩れ再現と解消を確認する手順を QA セクションに追記。

2. **テスト整備（先行実装）**
   1. `test/system/` 配下に `grid_layout_store_test.dart` を新設。以下を追加:
      - 初期化時にカード状態を正しくロードすること。
      - 列変更コマンド適用時に `notifyListeners()` が 1 回であること（`expect(store.debugListenerInvocations, equals(1))` 等で検証）。
      - バルク適用後、Semantics 安定化のための「待機イベント（`Future<void> store.commit()`）」が逐次呼び出されること。
   2. 既存の `GridResizeController` テスト（`test/system/grid_resize_controller_test.dart`）を拡張し、store をモック化した上で `apply`/`undo`/`redo` がドラフト作成 → commit を要求することを確認。
   3. UI テスト（`test/ui/grid_view_module_test.dart` 新設予定）では `WidgetTester` を用い、列変更後にカード rebuild が 1 フレームで完了すること、Semantics ツリーが除外→復帰されることを Golden 含め検証。

3. **段階的実装**
   1. **Store / DTO 実装**
      - `lib/system/state/grid_layout_store.dart` を追加。`GridCardViewState`、`GridLayoutDraft`、`GridLayoutMutation` 等の補助クラスを定義。
      - Hive 永続化レイヤー（`GridCardPreferencesRepository`）にバッチ API (`saveBatch(List<GridCardPreferenceMutation>)`) を追加し、テストで保証。
   2. **Controller 層改修**
      - `GridResizeController` を store ベースに移行。旧 Notifier 直接操作ロジックを削除し、Undo/Redo スナップショットを store から取得。
      - `ImageLibraryNotifier.refresh()` 呼び出しを列変更フローから排除し、store commit 後に必要な場合のみ差分取得。
   3. **UI 層改修**
      - `GridViewModule` の `_sizeNotifiers` / `_scaleNotifiers` を削除し、`Selector` と `AnimatedContainer` 等で store の更新結果を描画。
      - カードコンポーネント (`lib/ui/image_card.dart`) は store から渡される `GridCardViewState` を参照。リサイズコールバックは store コマンドを発行。
   4. **移行フェーズ限定処理**
      - 段階的導入中に旧ロジックと新ロジックを切り替えられる Feature Flag (`GridLayoutFeature.newStoreEnabled`) を追加し、比較テストを実施。

4. **ドキュメントおよび QA**
   - `docs/system/clipboard_monitor.md` など関連仕様から Grid 構成の参照がある場合は new store に合わせて更新。
   - QA 手順: Windows 実機で `5:5 → 5:3 → 5:5` を 5 回繰り返し、`.tmp/ikkatsu.log` に Semantics アサーションが出ないことを確認。`flutter drive --target=integration_test/resize_flow_test.dart` を update。

5. **移行完了条件**
   - すべての単体テスト・ウィジェットテスト・統合テストが新 store でパス。
   - Feature Flag を常時有効にしても旧 ValueNotifier ロジックを参照しないことをコードベースで確認（`rg '_sizeNotifiers'` などでチェック）。
   - known issue ドキュメントの問題点セクションに「GridLayoutStore 導入済みで解消」と追記し、抜け漏れがないことを確認。

## リスクと対策
- **I/O 負荷**: Hive のバッチ保存実装が未確立 ⇒ 先行テストでモック化し、コミット単位で I/O 回数が減ることを測定。
- **UI 瞬間的なスパイク**: バッチ反映時のレイアウトが一斉に走るため、`AnimatedSwitcher` や最小限のフェードで視覚的な破綻を防止。
- **Undo/Redo の一貫性**: Store 側でスナップショット差分を厳密に取る。テストで `apply → undo → redo` の round trip を保証。
- **移行期間のデグレード**: Feature Flag により段階的にリリースし、ログ（`Logger('GridLayoutStore')`）で旧構造へのフォールバックを検知。

## 用語整理
- **ドラフト**: 未コミットの `GridLayoutMutation` 群。カード幅・高さ・スケール情報を保持。
- **コミット**: ドラフトを store 状態と Hive に反映し、`notifyListeners()` を 1 回だけ実行する操作。
- **ビュー状態 (`GridCardViewState`)**: UI が参照する読み取り専用データ。`id`, `width`, `height`, `scale`, `span`, `isAnimating` 等を含む。

## 今後の検討
- Store 導入後、Semantics 情報の段階的簡略化（カード詳細をフォーカス時にロード）を追加し、アクセシビリティ負荷を制御。
- `GridLayoutStore` のバッチ適用を他機能（お気に入り・タグ付け）にも拡張し、状態管理の一貫性を高める。

---

## Snapshot Regeneration Pattern (2025-11-02)

### 問題点
カード個別リサイズ時にミニマップが更新されないバグが発生していました：

```dart
// 旧実装 (buggy)
void updateCard({required String id, ...}) {
  _viewStates[id] = nextState;
  await _persistence.saveBatch([...]);
  notifyListeners();
  _invalidateSnapshot();  // ← _latestSnapshot = null にセット
}
```

`_invalidateSnapshot()`は`_latestSnapshot`を`null`にセットするため、ミニマップが`latestSnapshot` getterを参照すると古い`_previousSnapshot`が返されていました。

### 解決策
`updateCard()`メソッドでスナップショットを再生成するパターンに統一：

```dart
// 新実装 (fixed) - lib/system/state/grid_layout_store.dart:503-524
void updateCard({required String id, ...}) {
  _viewStates[id] = nextState;
  await _persistence.saveBatch([_recordFromState(nextState)]);

  // スナップショット再生成（updateGeometry()と同じパターン）
  final geometry = _geometry;
  if (geometry != null) {
    final orderedStates = _orderedIds
        .map((id) => _viewStates[id])
        .whereType<GridCardViewState>()
        .toList(growable: false);
    final result = _layoutEngine.compute(
      geometry: geometry,
      states: orderedStates,
    );
    if (_latestSnapshot != null) {
      _previousSnapshot = _latestSnapshot;
    }
    _latestSnapshot = result.snapshot;  // ← 新しいスナップショットをセット
  }

  notifyListeners();
}
```

### 効果
- ミニマップが`latestSnapshot`を参照すると、**常に最新のスナップショット**が返される
- カードリサイズ、列変更、ウィンドウリサイズすべてで同じパターンを使用
- スナップショットIDが変わるため、`_MinimapPainter.shouldRepaint()`が正しく再描画を検出

### 関連コンポーネント
- `lib/ui/widgets/grid_minimap_overlay.dart`: スナップショット変更を検出して再描画
- `lib/system/grid_layout_layout_engine.dart`: レイアウト計算とスナップショット生成

---

## Persistence Synchronization (2025-11-02)

### 問題点
お気に入りボタンクリック時にグリッド全体が並び替わるバグが発生していました：

**実行フロー（旧実装）**:
1. ユーザーがお気に入りボタンをクリック
2. `ImageLibraryNotifier.updateFavorite()` → `syncLibrary()`呼び出し
3. `GridLayoutStore.syncLibrary()`がHiveから**古い値（200.00）**を読み込み
4. メモリには**新しい値（234.20）**があるが、Hiveには永続化されていない
5. 59カードで`contentChanged=true`が検出され、全カードがリビルド
6. 視覚的にカード位置が入れ替わる

**根本原因**: `updateGeometry()`がメモリを更新してもHiveに永続化していなかった。

### 解決策
`updateGeometry()`でHive永続化を徹底：

```dart
// 旧実装 (buggy)
void updateGeometry(GridLayoutGeometry geometry, ...) {
  final result = _layoutEngine.compute(...);
  for (final state in result.viewStates) {
    _viewStates[state.id] = state;  // メモリのみ更新
  }
  // Hiveへの永続化なし！
  if (changed && notify) {
    notifyListeners();
  }
}

// 新実装 (fixed) - lib/system/state/grid_layout_store.dart:307-325
void updateGeometry(GridLayoutGeometry geometry, ...) {
  final result = _layoutEngine.compute(...);

  // 永続化用のmutationsを収集
  final List<GridLayoutPreferenceRecord> mutations = [];
  for (final state in result.viewStates) {
    _viewStates[state.id] = state;
    mutations.add(_recordFromState(state));  // ← 永続化データ作成
  }

  // Hiveに永続化
  if (mutations.isNotEmpty) {
    debugPrint('[GridLayoutStore] updateGeometry_persist: mutationCount=${mutations.length}');
    _persistence.saveBatch(mutations);  // ← バッチ永続化
  }

  if (changed && notify) {
    notifyListeners();
  }
}
```

### 効果
- メモリとHiveが**常に同期**される（Write-through cacheパターン）
- 後続の`syncLibrary()`呼び出しでHiveから読み込んでも、最新値が取得される
- `contentChanged=false`となり、不要なカードリビルドが発生しない

### 関連メソッド
すべてのカード状態更新メソッドで永続化を実施：

- `updateGeometry()`: ウィンドウリサイズ・列変更時
- `updateCard()`: 個別カードリサイズ・スケール変更時
- `applyBulkSpan()`: 一括揃え時
- `restoreSnapshot()`: Undo/Redo時

### テスト方法
1. アプリ起動後、ウィンドウをリサイズしてカード幅を変更
2. Hive DBをクリアせずにお気に入りボタンをクリック
3. ログで`contentChanged=false`を確認
4. 視覚的にカード位置が変わらないことを確認

