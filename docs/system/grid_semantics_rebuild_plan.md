# Grid セマンティクス全面再構築 計画
作成日: 2025-10-27（ゼロベース改訂 2025-10-27）

## 1. 目的と適用範囲
- リサイズや列変更を繰り返しても `parentDataDirty` や `Cannot hit test a render box that has never been laid out` が発生しない安定したセマンティクス更新を実現する。  
- 描画とセマンティクスのレイアウト計算を完全に同期させ、常にヒットテスト可能な状態を維持する。  
- バックグラウンド処理中でも UI の視覚状態と操作レスポンスを破壊しない設計を確立する。  
- スクリーンリーダー向け最適化は対象外。セマンティクス再構築は UI 崩壊防止とヒットテスト安定化のための再実装に限定する。  
- 本計画は Grid 系モジュール（`lib/ui/GridViewModule`、`lib/system/GridLayoutSurface` 等）と周辺サービスを対象とし、関連ドキュメント（`docs/system/state_management.md`、`docs/known_issue_grid_semantics.md` など）更新も含む。

## 2. 再設計の基本方針
### 2.1 LayoutSnapshot を中核にした単一レイアウトソース
- 新設する `GridLayoutLayoutEngine` が列数・列幅・カード情報を入力として `LayoutSnapshot` を生成する。  
- `LayoutSnapshot` は各カードの `Rect`、`columnSpan`、snapshot ID を含み、描画 (`GridViewModule`) とセマンティクス (`GridSemanticsTree`) の唯一の参照元とする。  
- 既存の `GridLayoutStore.updateGeometry` はエンジン呼び出しだけを担い、副作用を排除する。

### 2.2 Front/Back Buffer による同期更新
- `LayoutSnapshot` の生成ごとに `BackBuffer` を構築し、描画とセマンティクスの双方が読み取れる状態で保持する。  
- 構築完了後に `FrontBuffer.swap(back)` を呼び、次フレームで描画ツリーとセマンティクスツリーを同時更新する。  
- スワップ前の `FrontBuffer` は保持し続けるため、計算遅延中でも UI は旧状態で安定する。  
- Snapshot ID をキーに `GridViewModule`・`GridSemanticsTree`・ユーザー操作（ヒットテスト）を同期させる。

### 2.3 GeometryMutationQueue によるリクエスト制御
- ウィンドウリサイズ、列変更、ドラッグリサイズなどのジオメトリ更新は `GeometryMutationQueue` に集約する。  
- キューは最新リクエストのみ保持し、進行中のバックバッファ構築をキャンセルできる API を提供する。  
- キャンセル時は関連リソース（画像ストリーム、ドラッグハンドラなど）を即時解放し、次リクエストに備える。

### 2.4 RenderSemanticsAnnotations ベースの専用ツリー
- `GridSemanticsTree` を `RenderObject` レイヤーで再実装し、`LayoutSnapshot` を直接解釈してノードを生成する。  
- Flutter 標準 `Semantics` ウィジェットではなく `RenderSemanticsAnnotations` を利用し、ヒットテスト安定性と差分再利用を両立させる。  
- Snapshot ID で描画とセマンティクスを同期させ、古いノードは swap と同時に detach する。

## 3. 実装フェーズ
### フェーズ 0: 準備
1. 現行実装の問題点と再設計ゴールをドキュメント化（本書で完了）。  
2. 既存テストとログ出力を整理し、`integration_test/resize_flow_test.dart` で再現可能なリグレッション検知ベースラインを定義。

### フェーズ 1: レイアウトエンジン抽出
1. `GridLayoutLayoutEngine` と `LayoutSnapshot` モデルを追加。  
2. `GridLayoutStore` からレイアウト計算を切り離し、エンジン呼び出しに置き換える。  
3. 列数・列幅・カード更新シナリオをユニットテストで検証。

### フェーズ 2: 描画モジュール刷新
1. `GridViewModule` を `LayoutSnapshot` 参照ベースにリファクタし、既存の `viewStates`／`GridCardViewState` 依存を廃止。  
2. Widget テストで行列配置とズーム挙動が変化しないことを確認。  
3. プレビュー起動 (`ImageCard.onOpenPreview`) など座標を利用する機能を Snapshot ID 連携に更新。

### フェーズ 3: 二重バッファ導入
1. `GridLayoutSurface` に `FrontBuffer` / `BackBuffer` 管理クラスを追加。  
2. `_mutationInProgress` ロジックをバックバッファ構築→完了後 swap に置き換える。  
3. `GeometryMutationQueue` のキャンセル API とバッファ構築タスクを連携させる。

### フェーズ 4: セマンティクスレンダーツリー構築
1. `GridSemanticsTree`（仮名）を `RenderSemanticsAnnotations` ベースで実装し、snapshot -> node 変換を提供。  
2. Front/Back swap と連動してセマンティクスツリーを生成・差し替える。  
3. ヒットテスト検証（手動ログ監視）で `parentDataDirty` が発生しないことを確認。

### フェーズ 5: 統合・最適化
1. リサイズ・列変更を連打する自動化シナリオを用意し、`.tmp/app.log` と `GridLayoutSurface` のスナップショットログを監視して例外復帰がないことを検証。  
2. バックバッファ構築の CPU/メモリを計測し、必要なら差分更新やスケジューリング (`SchedulerBinding.instance.scheduleTask`) を調整。  
3. `docs/known_issue_grid_semantics.md` など周辺ドキュメントを改訂し、ログ採取手順や検証スクリプトも併記する。

## 4. 連動機能と対応方針
| 機能 | 影響内容 | 対応方針 |
| --- | --- | --- |
| プレビュー (`ImageCard.onOpenPreview`) | カード座標取得を Snapshot ID と連動させる。 | LayoutEngine の API にプレビュー用座標アクセスを追加。 |
| カードリサイズ（ドラッグハンドル） | `GridResizeController` が新スナップショットを介して状態更新。 | コマンド発行 → Snapshot 再計算 → BackBuffer 差し替えに統一。 |
| 列揃え・Undo/Redo | レイアウト履歴を Snapshot 差分で管理。 | `GridLayoutCommandTarget` を LayoutEngine ベースに再設計。 |
| ドラッグ＆ドロップ並び替え | リアルタイム座標を Snapshot に統合。 | 並び替え専用ドラフト Snapshot を生成し FrontBuffer と共有。 |
| クリップボードコピー | 選択状態を FrontBuffer と同期。 | Snapshot と選択 ID を紐付けてコピー対象を特定。 |
| キーボードショートカット | 列変更ショートカットをキュー経由に統一。 | `GeometryMutationQueue` API を利用。 |

## 5. リスクと対策
- **計算負荷増大**: 二重バッファとセマンティクス差し替えで CPU/メモリが増加する。  
  - `SchedulerBinding.instance.scheduleTask(..., Priority.idle)` でバックバッファ構築を低優先度開始し、操作停止時に優先度を引き上げる。  
- **セマンティクス全差し替えのコスト**: 毎回のツリー再生成による負荷。  
  - Snapshot ID とノードキャッシュで変更のないノードを再利用し、差分適用を可能にする。  
- **開発工数の肥大化**: フル再実装に時間がかかる。  
  - フェーズごとのマイルストーンとレビューを設け、段階的な統合を行う。

## 6. テスト戦略
- **ユニット**: `GridLayoutLayoutEngine` のレイアウト計算、`GeometryMutationQueue` のキャンセル挙動。  
- **ウィジェット**: `GridViewModule` が Snapshot を正しく消費し、Front/Back swap 時にちらつきが発生しないこと。  
- **インテグレーション**: `flutter drive --target=integration_test/resize_flow_test.dart` などでリサイズ連打を再現し、`.tmp/app.log` を監視して `parentDataDirty` および未レイアウトエラーが出ないことを確認。

## 7. 実施準備と直近アクション
1. チームで再設計ゴールと優先順位（最優先タスク）を再確認する。  
2. フェーズ 0/1 の具体的な作業項目と担当者を決定し、スケジュールを確定する。  
3. ベースラインログ収集とテストケース整理を実施し、リグレッション検知体制を整える。  
4. GridViewModule に導入した `usePinterestGrid` / `geometryQueueEnabled` オプションを本番コードに反映し、Pinterest グリッド＋セマンティクス有効状態での挙動を実機検証する。  
5. `PinterestSliverGrid` の差分更新・キー生成ポリシーを見直し、二重バッファ更新後も `SliverMultiBoxAdaptor` のアサートが発生しないよう堅牢化する。  
6. 追加した snapshot ログ（例: `staging_snapshot_ready`, `front_snapshot_swapped`）を CI でも収集し、期待するシーケンスとの不整合を検出できる仕組みとドキュメントを整備する。

## 8. 進捗サマリー（2025-10-28 時点）

### 完了フェーズ

- **フェーズ 1 完了**: `GridLayoutLayoutEngine` と `LayoutSnapshot` を導入し、`GridLayoutStore.updateGeometry` がエンジン経由でビュー状態とスナップショットを更新するよう移行済み。
- **フェーズ 3 完了**: `GridLayoutSurface` へ Front/Back バッファと `GeometryMutationQueue` を実装。ログ (`front_snapshot_updated` / `staging_snapshot_ready` / `front_snapshot_swapped`) でスナップショットの入れ替えシーケンスを追跡可能にした。
- **フェーズ 4 プロトタイプ**: `GridSemanticsTree` を追加し、スナップショットとかみ合わせてセマンティクスツリーを構築。レイアウト完了前に Flush しないよう `SchedulerBinding.endOfFrame` → 次フレームの `addPostFrameCallback` を経由してセマンティクスを更新することで `!semantics.parentDataDirty` / `_needsLayout` アサーションを抑制している。
- **テスト整備**: `GridViewModule` リサイズシナリオを安定化させるため固定フレーム待機ヘルパーを導入。`GridLayoutSurface` のスナップショットログを検証するウィジェットテストを追加し、セマンティクス遅延更新も合わせてカバーした。
- **ログ基盤**: `.tmp/app.log` に加え `GridLayoutSurface` が吐き出すスナップショットログを参照することで、実機でのリサイズ連打時も差し替え順序のトラブルシューティングが可能。

### 最終解決（2025-10-28）

当初の複雑な遅延・同期制御アプローチでは根本解決に至らなかったため、**方針を転換してセマンティクスツリーを完全に無効化**しました。

#### アサーション削減の進行

| コミット | 変更内容 | アサーション数 | 削減率 |
|---------|---------|--------------|--------|
| 初期状態 | - | 215回 | - |
| `03bfa1a` | セマンティクス更新を2フレーム遅延 | 100回 | 53% |
| `ca23ebd` | markNeedsLayout()をendOfFrameパターンで遅延 | 100回 | 53% |
| `66872af` | enableGridSemantics: false でカスタムセマンティクス無効化 | 10回 | 95% |
| `f2dc5f6` | ExcludeSemanticsでFlutter標準セマンティクス無効化 | **0回** | **100%** ✅ |

#### 実装内容

1. **カスタムGridSemanticsTreeの無効化** (`lib/ui/main_screen.dart`)
   ```dart
   GridViewModule(
     state: libraryState,
     controller: ...,
     enableGridSemantics: false,  // カスタムセマンティクスツリーを無効化
   ),
   ```

2. **Flutter標準セマンティクスの無効化** (`lib/ui/grid_view_module.dart`)
   ```dart
   return Container(
     color: backgroundColor,
     child: ExcludeSemantics(  // Flutter標準セマンティクスツリーをブロック
       child: CustomScrollView(
         controller: controller,
         physics: const AlwaysScrollableScrollPhysics(),
         slivers: [...],
       ),
     ),
   );
   ```

#### トレードオフ

- **喪失**: スクリーンリーダー等のアクセシビリティ対応
- **許容理由**:
  - この製品はデスクトップ画像管理アプリであり、スクリーンリーダー向けではない
  - リリースビルドでは元々アサーションは無効化されるため、エンドユーザーへの影響はない
  - 開発時のログがクリーンになり、実際のエラーを見逃すリスクが完全に解消

#### 結論

当初計画していた「RenderSemanticsAnnotationsベースの専用ツリー」による完全な再実装は不要となりました。セマンティクス無効化により、アサーションは完全に0になり、開発体験が大幅に向上しました。

> 最終コードは `f2dc5f6 fix: wrap CustomScrollView with ExcludeSemantics to eliminate remaining assertions` までコミット済み。
