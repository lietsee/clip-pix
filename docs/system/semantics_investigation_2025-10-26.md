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
  testWidgets('列数が変化したときだけ mutate コールバックが呼ばれる', ...);OK
  ```
  → 列数 3 のまま幅変更した場合はコールバックが発火せず、列数が 1 に変わったときにのみ 2 回目のコールバックが呼ばれることを確認。  
  ⇒ 列幅の微調整では依然として旧挙動のままセマンティクス競合が起こり得る。

### 仮説B: `GridLayoutMutationController` の begin/end は呼ばれているが、`GridViewModule` の rebuild が同フレーム内で re-entrant に発生し、セマンティクス更新と競合している

- **根拠**  
  `GridResizeStoreBinding` の mutation ラップは `WidgetsBinding.instance.addPostFrameCallback` で `endMutation()` を呼んでいる。ログから見るとアサーション直後に次フレームが継続して失敗しており、Semantics ツリーが安定する前に `GridLayoutSurface` が再度列サイズを更新している可能性が高い。

- **現状観測**  
  2025-10-26 実機チェックでは、ウィンドウリサイズ開始直後（初回）からアサーションが再発。`mutationController.isMutating` が true の間も例外が継続したため、begin/end のタイミングがずれているか、列幅だけの変更で `onMutateStart` が呼ばれていないと推測される。ログ追加は未実施。

### 仮説C: 画像取り違えは `_GridEntry` と `viewStates` のズレが原因

- **現状観測**  
  最新ビルドでは画像取り違えを再現できず、アサーションが出てもプレビュー画像は以 前と一致している。再現タイミングの違いによるものである可能性が高く、根本原因は依然不明。`_logEntries` での整合チェックは未着手。

## 現時点の結論

- 列数が変わらないリサイズではグリッド非表示が行われず、旧来のセマンティクス競合パスに戻っている（仮説Aが成立）。そのためウィンドウ幅の微小変動を繰り返すとアサーションは依然発生する。
- 列変更・一括揃え経路については未検証。ミューテーションコントローラー導入で改善している可能性はあるが、別途再現テストが必要。
- 画像取り違えはアサーションによる RenderObject 再利用が主因と考えられるが、追加ログによる確認が必要。

## 次のアクション（2025-10-26 時点）

1. **仮説Bの検証（継続中）**
   - ✅ `GridLayoutMutationController` に begin/end のロギングを導入し、フレームタイムスタンプと同フレーム再入回数を記録できるようにした（デバッグ／プロファイルビルドでは自動で有効化）。
   - ✅ `GridResizeStoreBinding` 経由のコマンドで begin/end が 1 回ずつ呼ばれることを確認するウィジェットテストを追加し、postFrameCallback 実行保証のための `scheduleFrame()` ガードを組み込んだ。
   - ✅ `GridLayoutSurface._commitPending` を `SchedulerBinding.scheduleTask(..., Priority.touch)` ベースに書き換え、列数変更時のセマンティクス更新を 1 フレーム後段に送るよう調整した。`GridLayoutSurface` 内でデバッグログを追加し、幾何更新のスケジューリング状況を追跡できるようにした。
   - ✅ 列幅のみの更新ではグリッドを非表示にせず、`GridLayoutMutationController.beginMutation(hideGrid: false)` を呼んでセマンティクスとポインタだけを抑制する軽量モードを実装した。`GridViewModule` では `shouldHideGrid` と `isMutating` を分離して扱い、Offstage は列変更時のみ行う。
   - ✅ `GridLayoutSurface` にジオメトリコミットのキュー制御を追加し、`onMutateEnd` が完了するまで次のコミットを遅延させるようにした。これにより `commit_pending skipped` 発生後も確実に再スケジュールされる。
   - ✅ `test/ui/grid_layout_surface_test.dart` を更新し、列変更パスで `GridLayoutStore.updateGeometry` が最低 2 回呼ばれることを確認するようにした（幅変更→列変更を順に適用）。
   - ▶️ デスクトップ実機でリサイズ操作を再現し、`.tmp/app.log` の begin/end ログ・`GridLayoutSurface` ログから width-only 更新が Semantics と競合していないか確認する。
2. **仮説Cの検証（進捗中）**
   - ✅ `GridViewModule._logEntries` で `_entries` と `layoutStore.viewStates` の ID リストと順序を同一ログに出力するよう拡張した。
   - ✅ ビルド前に ID セットが一致しているか `assert` で検証し、ズレがあれば詳細ログを吐く仕組みを追加した（`isRemoving` エントリは除外して評価）。
   - ✅ 実機ログでは初期同期時に一時的な `orderMatches=false` が出るが、その直後に `orderMatches=true` へ収束し整合性が取れていることを確認した。
   - ▶️ リサイズ中に `orderMatches=false` が継続するケースを追加で捕捉し、ズレが画像取り違え再現と結び付くか監視する。
3. **テスト拡張（TODO）**
   - ウィンドウリサイズ → プレビュー操作を自動化するテスト（または手動検証用ログ）を追加し、画像取り違えが発生する条件を特定する。現在はユニットテストで列変更時の geometry 更新まで確認済み。

### 2025-10-26 実機ログ観測メモ

- `[GridLayoutMutationController]` の begin/end ログはリサイズ操作全体で 3 ペアのみ。いずれも `phase=SchedulerPhase.postFrameCallbacks` かつ `concurrentBegins=1` で、ミューテーション深度に再入は確認できなかった。
- 上記 begin/end ログが出ていないタイミングでも `!semantics.parentDataDirty` アサーションが継続発生しており、列数が変わらない幅調整経路でグリッドが非表示化されていない（仮説A/B）の可能性が高い。
- リサイズ操作後半で `setState() or markNeedsBuild() called during build.` が記録されており、`GridLayoutSurface` 側でビルド中に追加のミューテーションが走っているか検証が必要。

→ 次段では `GridLayoutSurface._commitPending` にカラム変化有無と `onMutateStart` 呼び出しのログを追加し、列幅のみの更新フレームを可視化する。併せて、列幅変更でもミューテーションを強制開始する案と、`scheduleTask` でセマンティクス更新とフレームを分離する案を比較検証する。

### 2025-10-26 実装メモ

- `GridLayoutSurface` のジオメトリ適用を `scheduleTask(Priority.touch)` でディレイし、列変更時に Semantics 更新と描画が同フレームで衝突しないよう暫定対応した。幅のみの微調整は引き続き `Timer` 経由でディレイされるため、実機ログで競合が解消されたか確認する必要がある。
- 幅変更のみのケースはユニットテストで確定的に追えなかった（CI上では updateGeometry コール回数が 1 のままの場合がある）。実機ログでは `geometry_pending` が出ないケースがあり、`GridLayoutSurface` の制約取得／Timer 発火を追跡する追加ログが今後必要。
- `GridViewModule` のログは `orderMatches` の瞬断と整合性復帰を確認できた。プレビュー取り違え再現用の自動テストは未着手。

- `GridLayoutStore` と `GridLayoutSurface` のジオメトリ差分（`deltaWidth` / `deltaColumns`）をリリースでも出力するよう変更したため、実機ログで幅更新の頻度と変化量を直接追跡できるようになった。

### 2025-10-26 実機検証（列変更復帰遅延後）

- 列数変更時に `Priority.animation` でジオメトリコミットし、`onMutateEnd` を 2 フレーム遅延 → さらに `Priority.idle` 待機無しにダブル `addPostFrameCallback` で復帰させる構成に切り替えた。幅調整は `hide=false` でソフトミューテーションとし、表示を維持している。
- 最新ログでも `deltaColumns=±1` の直後に `!semantics.parentDataDirty` が連続発生しており、改善は限定的。ソフトミューテーション区間（`hide=false`）では例外が増えていないため、列変更復帰フレームをさらに遅延／セマンティクス安定を監視する仕組みが必要。
- Windows 実機で発生していた `Failed to post message to main thread` は二段階 `addPostFrameCallback` に切り替えることで消失した。

### TODO（2025-10-26 時点）

1. `GridLayoutSurface` で列変更が発生したフレームごとに `SemanticsBinding.hasScheduledSemanticsUpdate` と `endOfFrame` 到達をログする仕組みを追加し、Semantics がどのタイミングで落ち着くかを可視化する。
2. 列変更時の `onMutateEnd` 呼び出しを `endOfFrame` 完了後に遅延させ、必要に応じて `scheduleTask(Priority.idle)` をループさせて Semantics 安定を待つ仕組みを試作・検証する。
3. `_maybeUpdateGeometry` を拡張し、同一フレーム内で列数が往復するケース（4→3→4など）を間引いて最後の値のみ反映させることで、冗長な列変更イベントを削減する。
4. 画像取り違え再発防止を保証する自動テスト（リサイズ→プレビュー）を整備し、Semantics 例外が UX 上の不具合に直結していないか検証する。

上記検証で原因を特定した後、列幅変更時にもグリッドを非表示にするなどの実装的対策を検討する。

## 追加観測（2025-10-26T18:36 実機ログ）

- `.tmp/app.log` の最新ビルド（コミット `fix: defer grid geometry reset until post frame` 適用後）でも、列数が変わらない連続リサイズで `notify=false` のまま `GridLayoutStore.updateGeometry` が呼ばれ、その直後から `!semantics.parentDataDirty` と `!childSemantics.renderObject._needsLayout` が再度バーストしている。
- ミューテーションコントローラーは `hide=false` の軽量モードで begin/end を刻んでいるが、Semantics ツリーが dirty のまま復帰し、`GridLayoutSurface` が同じフレームで追加の geometry 更新を実行してしまっている。結果として parentData が安定せず RenderObject の再利用と衝突している。
- 1 フレーム後段にディレイしただけでは Semantics の dirty 解消が間に合わず、列幅変更も列変更と同じレベルで競合を起こしていると判断できる。

## 対応方針アップデート（2025-10-26 18:40）

1. **描画とセマンティクスの完全分離（新方針）**  
   - ミューテーション開始時に GridView 全体を `ExcludeSemantics`（もしくは `Semantics` の `container=false`）でラップし、列幅／列数問わず幾何更新が完了するまでセマンティクスツリーを切り離す。  
   - 描画は継続して行うことで、列幅変更中のちらつきは従来通り抑制する。
2. **復帰タイミングのエンド・オブ・フレーム保証**  
   - ミューテーション終了時は `SchedulerBinding.instance.endOfFrame` を待ち、さらに `Priority.idle` のタスクで `RendererBinding.instance.pipelineOwner.semanticsOwnerNeedsUpdate`（もしくは `SemanticsBinding.instance.hasScheduledSemanticsUpdate` のポーリング）を監視し、dirty が残っている間は再接続しない。
3. **マルチコミット抑制**  
   - セマンティクス切り離し中は `_pendingGeometry` を蓄積してまとめて適用し、復帰直前に最新の 1 つだけをコミットする。これにより幅変更が短時間に複数回走っても、Semantics 復帰後に過去のジオメトリが再適用されるのを防ぐ。

本方針をドキュメントに明記した上で、GridLayoutSurface / GridViewModule に実装を追加していく。

### 実装更新ログ（2025-10-26 18:47）

- `GridLayoutSurface` でミューテーション開始時に `ExcludeSemantics(excluding: true)` を必ず建て、列数／列幅どちらの更新でもセマンティクスを完全に切断するよう変更。
- 幾何更新の本体はフレーム末尾（`addPostFrameCallback`）にディレイし、ExcludeSemantics が反映された後で `GridLayoutStore.updateGeometry` を実行する。
- ミューテーション終了時は `endOfFrame` と `semanticsOwnerNeedsUpdate` / `hasScheduledSemanticsUpdate` をポーリングし、dirty が解消し次第にのみセマンティクスを再接続する。
- 上記更新により最新ログでは `!semantics.parentDataDirty` アサーションが初期数回まで大幅に減少。引き続き幅変更連続時の長期安定をモニタリングする。
- 幅更新が入った瞬間にセマンティクス除外フラグを立てるよう `_commitPending` を再調整し、ジオメトリコミットのスケジュールより前にツリーを切断できるようにした。
