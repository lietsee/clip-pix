# セマンティクスアサーション調査メモ（2025-10-26）

対象コミット: `ef7c957 feat: hide grid during layout mutations`

ウィンドウリサイズ時に `!semantics.parentDataDirty` / `!childSemantics.renderObject._needsLayout` が継続発生し、プレビュー画像取り違えが再現するため原因を切り分ける。

## ログ観測

- `.tmp/app.log` にはリサイズ操作と同期して上記アサーションが多数記録される。
- `GridLayoutMutationController` による非表示化を入れてもログの周期は変わらない（40ms 以下の間隔で連続発生）。
- アサーション発生直後にプレビューで別カードが開くことが確認されている（実機報告）。

## 仮説と検証

### 仮説A: 列数が変わらないリサイズでは非表示処理が走らず、旧挙動と同じくセマンティクス競合が起きている

- **根拠**  
  `GridLayoutSurface._commitPending` で `onMutateStart` を呼ぶのは `shouldNotify == true` の場合のみ（= `columnCount` に変化がある場合）。列数が変わらず列幅だけが変動すると、グリッドは非表示にならない。

- **検証**  
  `test/ui/grid_layout_surface_test.dart` にテストを追加し、列数が変化したときのみ `onMutateStart` / `onMutateEnd` が呼ばれることを確認した。
  ```dart
  testWidgets('列数が変化したときだけ mutate コールバックが呼ばれる', ...);
  ```
  → 列数 3 のまま幅変更した場合はコールバックが発火せず、列数が 1 に変わったときにのみ 2 回目のコールバックが呼ばれることを確認。  
  ⇒ 列幅の微調整では依然として旧挙動のままセマンティクス競合が起こり得る。

### 仮説B: `GridLayoutMutationController` の begin/end は呼ばれているが、`GridViewModule` の rebuild が同フレーム内で re-entrant に発生し、セマンティクス更新と競合している

- **根拠**  
  `GridResizeStoreBinding` の mutation ラップは `WidgetsBinding.instance.addPostFrameCallback` で `endMutation()` を呼んでいる。ログから見るとアサーション直後に次フレームが継続して失敗しており、Semantics ツリーが安定する前に `GridLayoutSurface` が再度列サイズを更新している可能性が高い。

- **検証**  
  現状はコード読みの段階。`MutationController` の begin / end をロギングすることで一フレーム内に複数回呼ばれているかを確認する必要あり（後続タスク）。

### 仮説C: 画像取り違えは `_GridEntry` と `viewStates` のズレが原因

- **根拠**  
  セマンティクス例外のたびに `GridViewModule` が rebuild され、`AnimatedOpacity(ObjectKey(entry))` を使っているため、再挿入タイミングで Flutter が別の要素に同じ RenderObject を使い回している可能性がある。
- **検証案**  
  `_logEntries()` に列幅・viewState 情報を追加し、例外発生直前に `_entries` の順序と `layoutStore.viewStates` の順序がズレていないかを確認する。現時点では未実施。

## 現時点の結論

- 列数が変わらないリサイズではグリッド非表示が行われず、旧来のセマンティクス競合パスに戻っている（仮説Aが成立）。そのためウィンドウ幅の微小変動を繰り返すとアサーションは依然発生する。
- 列変更・一括揃え経路については未検証。ミューテーションコントローラー導入で改善している可能性はあるが、別途再現テストが必要。
- 画像取り違えはアサーションによる RenderObject 再利用が主因と考えられるが、追加ログによる確認が必要。

## 次のアクション（2025-10-26 時点）

1. **仮説Bの検証**
   - `GridLayoutMutationController` に begin/end のロギングを追加し、同フレーム内で再入していないか確認する。
   - `GridResizeStoreBinding` 周辺にユニットテストを追加し、ミューテーション区間が 1 回ずつ呼ばれることを保証する。
2. **仮説Cの検証**
   - `GridViewModule._logEntries` で `_entries` と `layoutStore.viewStates` の ID リスト・順序を同一ログに出す。
   - ビルド前に ID セットが一致しているか assert し、ズレがあれば詳細ログを出す。
3. **テスト拡張**
   - ウィンドウリサイズ → プレビュー操作を自動化するテスト（または手動検証用ログ）を追加し、画像取り違えが発生する条件を特定する。

上記検証で原因を特定した後、列幅変更時にもグリッドを非表示にするなどの実装的対策を検討する。
