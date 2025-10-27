# Grid セマンティクス再構築計画（全面再設計前提）  
作成日: 2025-10-27

## 背景
- 現行実装は `GridLayoutSurface` が描画とセマンティクスを同一ツリーで更新しており、リサイズ時に `!semantics.parentDataDirty` や `Cannot hit test a render box that has never been laid out` が再発。
- 一時的に試みた二重バッファ＋簡易セマンティクス分離は、レンダーツリーより先に仮座標を生成する設計上の欠陥で失敗した。
- 小手先の修正では根治できないため、描画・セマンティクス・ジオメトリ適用をゼロベースで再作成する。

## ゴール
1. どのようなリサイズ操作でもセマンティクス dirty を発生させない。
2. 描画とセマンティクスが常に同じレイアウト計算に基づき、ヒットテスト可能な状態を保証する。
3. バックグラウンド処理中でも UI は安定した状態を維持し、ユーザー操作を中断させない。

## 新アーキテクチャ概要

### 1. レイアウトソースの一本化
- 画像カードの配置計算を `GridLayoutStore` ではなく新設する `GridLayoutLayoutEngine` へ移し換える。
- `LayoutEngine` は列数・列幅を入力すると、各カードの `Rect`・`columnSpan` 等をまとめた `LayoutSnapshot` を生成。
- 描画 (`GridViewModule`) とセマンティクス (`GridSemanticsTree`) はこの同一スナップショットを参照して生成する。

### 2. 完全二重バッファ
- `LayoutEngine` がスナップショットを発行するたびに `FrontBuffer` / `BackBuffer` を更新。
- バックバッファの構築が完了したら `FrontBuffer.swap(back)` をコールし、1フレーム後に描画ツリーとセマンティクスツリーを同時更新。
- スワップ前に旧バッファを保持し続けるため、裏側での計算が長引いても UI は安定。

### 3. ジオメトリキュー＋明示的キャンセル
- ウィンドウリサイズや列変更はすべて `GeometryMutationQueue` に集約。
- キューは「最新リクエストのみ」を保持し、進行中のバックバッファ構築を即キャンセルできる API を提供。
- キャンセル時は関連リソース（画像ストリーム等）を即時解放。

### 4. セマンティクス専用レンダーツリー
- `GridSemanticsTree` を `RenderObject` ベースで再実装し、`LayoutSnapshot` を直接解釈してツリーを生成。
- Flutter 標準 `Semantics` ウィジェットではなく、`RenderSemanticsAnnotations` を利用して hit-test 安定性を担保。
- タッチ操作・スクリーンリーダー操作は `FrontBuffer` の snapshot ID を使って `GridViewModule` と同期。

## 実装ステップ

### フェーズ 0: 準備
1. `docs/` に現状の問題と再設計方針を明記（本ドキュメント）。
2. 既存テストを整理し、リグレッション検知用のベースライン（アサーションが出たら失敗する integration log チェック）を整備。

### フェーズ 1: レイアウトエンジン抽出
1. `GridLayoutLayoutEngine` を新規追加し、列数・列幅・カード情報から `LayoutSnapshot` を生成する。
2. 現行 `GridLayoutStore.updateGeometry` からスナップショット生成を呼び出すようリファクタ。
3. 単体テストで、入力列数/列幅が変わった時の `Rect` 計算を検証。

### フェーズ 2: 描画リファクタ
1. `GridViewModule` を改修し、`LayoutSnapshot` を直接参照するようにする。
2. 従来の `viewStates`／`GridCardViewState` 依存部分を `LayoutSnapshot` ベースに置き換え。
3. 描画テスト（Widget Test）で行列配置が変わっていないことを確認。

### フェーズ 3: 二重バッファ導入
1. `GridLayoutSurface` に `FrontBuffer` / `BackBuffer` 管理クラスを導入。
2. 既存の `_mutationInProgress` 分岐をバックバッファ構築→完了後 swap というストリームに書き換え。
3. キューキャンセル API を `GeometryMutationQueue` に追加し、バックバッファ構築タスクと連動させる。

### フェーズ 4: セマンティクスレンダーツリー
1. `GridSemanticsTree`（仮）を追加し、`RenderSemanticsAnnotations` ベースで snapshot -> node を構築。
2. フロントバッファ swap と同時にセマンティクスツリーを再生成し、古いノードは detach。
3. スクリーンリーダー向けテスト（手動・ログ）で `parentDataDirty` が出ないことを確認。

### フェーズ 5: 統合＆最適化
1. リサイズ連打・列変更連打のログを `.tmp/app.log` で収集し、親データ dirty/未レイアウトエラーが発生しないかを検証。
2. バックバッファ構築の CPU/メモリコストを計測し、必要に応じて差分更新・スロットル値を調整。
3. ドキュメント（特に `docs/known_issue_grid_semantics.md`）を最新設計に合わせて更新。

## 残リスクと対策
- **負荷増大**: 二重バッファ＋セマンティクス再生成はコストが大きいため、差分適用や優先度調整が不可欠。
  - → バックバッファ構築を低優先度 `SchedulerBinding.instance.scheduleTask(..., Priority.idle)` で開始し、リサイズが停止した瞬間に優先度を上げる。
- **スクリーンリーダーの大量通知**: セマンティクスツリーの全差し替えは VoiceOver/Narrator に大量の「要素変更」を通知する可能性がある。
  - → snapshot ID を比較し、変更のないノードは再利用する仕組みを検討。
- **開発工数**: フル再実装には相応の時間が必要。上記フェーズごとのマイルストーンで進捗を可視化し、段階的にレビューする。

## テスト戦略の見直し
- ユニット: `GridLayoutLayoutEngine` の計算、`GeometryMutationQueue` のキャンセル挙動。
- ウィジェット: `GridViewModule` が snapshot を正しく消費するか、swap 時にちらつきが発生しないか。
- Integration: リサイズ連打 + スクリーンリーダー ON の状態で `.tmp/app.log` をモニタし、アサーションが出ないことを確認。必要なら自動化スクリプトを作成。

## 次ステップ
1. チーム合意のもと再設計着手可否を決定。
2. フェーズ 0 / 1 を優先実装し、レイアウトエンジン抽出を進める。
3. 並行して既存ログ情報を整理し、ベースラインを設定。
