# グリッドセマンティクス二重化計画（2025-10-26）

対象: `GridLayoutSurface` / `GridViewModule` 周辺。ウィンドウリサイズ時に発生する `!semantics.parentDataDirty` / `!childSemantics.renderObject._needsLayout` の常態化を解消するため、描画・セマンティクス・ジオメトリ適用を三段階で分離する。

## 背景

- 単一バッファ構成では、列幅・列数の更新が短時間に連続すると既存セマンティクスツリーが dirty のまま再利用され、アサーションが連鎖する。
- `ExcludeSemantics` とフレーム遅延では列幅のみの微細更新を完全には抑止できず、悪意ある操作（高速ドラッグ）で再発する。
- ただし UI 表示のリアルタイム性は維持したい。大幅なフリーズやズームアウトなど極端な UX 低下は避ける。

## 目標

1. 表示中（フロントバッファ）の描画・セマンティクスを常に安定させる。
2. 列幅／列数変更はすべて「裏バッファ構築 → 準備完了後に一括スワップ」で処理し、 dirty なツリーをフロントへ露出させない。
3. 更新頻度が極端に高い場合でもジオメトリ適用を間引き、裏バッファを破棄・再生成するだけで防御できる構造にする。

## アーキテクチャ概要

```
┌─────────────┐      ┌──────────────┐
│  Front Buffer │◀────┤  Swap Manager │
│  (Draw+Sem)   │      └─────▲────────┘
└──────▲────────┘            │
       │                     │
       │ swap()              │
       │                     │
┌──────┴────────┐      ┌─────┴────────┐
│  Back Buffer  │◀────┤ Geometry Queue│◀── Resize/Mutate requests
│  (Draw+Sem)   │ build└──────────────┘
└───────────────┘
```

### 1. ダブルバッファ（描画）

- `GridLayoutSurface` が保持する内部状態を `FrontGridState` / `BackGridState` に分割。
- 表示中は常に `FrontGridState`（既存の `GridViewModule` を利用）。裏側で `BackGridState` を `Offstage` の `GridViewModule` として構築。
- 裏側の構築が完了したら、`FrontGridState` と入れ替え（Widget ツリー上は `AnimatedSwitcher` 等でスワップ）。

### 2. セマンティクス分離

- フロント用セマンティクスツリーを `Semantics` コンテナとして独立保持。裏側構築時は `SemanticsNode` の JSON ライクな構造体を生成するだけで実際のツリーへは接続しない。
- スワップ時にのみ `SemanticsNode` を登録し直し、古いノードを dispose。
- これにより裏バッファ構築中の dirty はフロントへ届かない。

### 3. ジオメトリ更新キュー

- 幅/列変更リクエストを `GeometryMutationQueue` に蓄積し、一定周期（例: 60ms）で最後の1件のみを `BackGridState` へ適用。
- バック構築が進行中に新リクエストが到来した場合、進行中のジョブをキャンセルして再生成を開始。
- キャンセル処理で `BackGridState` を破棄し、関連リソース（画像キャッシュ、Ticker 等）を即時解放。

## 詳細フロー

1. **リクエスト受理**
   - `GridLayoutSurface._maybeUpdateGeometry` は従来通りジオメトリを計算する。しかし通知対象は `GeometryMutationQueue` のみ。
   - `BackGridState` がアイドルの場合は即 `enqueue()`, ビルド中なら `enqueueAndCancelCurrent()`.

2. **キュー処理**
   - `GeometryMutationQueue` は `Timer` または `SchedulerBinding.scheduleFrameCallback` を利用し、設定した周期で最新依頼を取り出す。
   - バック側に未完了ジョブがある場合は即キャンセル→再開。
   - バック構築は `Future` ベースで、完了時に `SwapManager` に `onBackReady()` を通知。

3. **バックバッファ構築**
   - `BackGridState` は `Offstage` 上で `GridViewModule` を生成。`ImageCard` など既存 Widget を再利用。
   - セマンティクスは別途 `BackSemanticsBuilder` が JSON 風構造体を作る（`SemanticEntry` 等）。`SemanticsNode` の生成はスワップ直前に限定。
   - バック側が完成したら `SwapCandidate` として `SwapManager` に登録。

4. **スワップ**
   - `SwapManager` が `front` と `back` を入れ替える（`setState`）。
   - セマンティクスは `SemanticsOwner` に対して `replaceChildren`（または Flutter の `Semantics` ウィジェットを再構築）で一括差し替え。
   - スワップ後、旧フロントをバックとして再利用する（ping-pong）。

5. **キャンセルシナリオ**
   - リサイズ中に短時間で複数回リクエストが飛ぶ場合、バック構築が頻繁にキャンセルされる。
   - フロントは常に安定しているため、ユーザーがプレビューやコピーを行ってもセマンティクス不整合は起きない。

## API/責務整理

| コンポーネント | 役割 | 備考 |
| --- | --- | --- |
| `GridLayoutSurface` | UI入口。キューへジオメトリを送る | `LayoutBuilder` は「現在表示中の front」幅情報のみに利用 |
| `GeometryMutationQueue` | リクエストの集約とスロットル | 最終リクエストのみを処理。キャンセルハンドリングを提供 |
| `BackGridBuilder` | バックバッファのウィジェット／セマンティクス構築 | 可視化されないため `TickerMode` 無効化等で負荷軽減 |
| `SwapManager` | バッファの切替とセマンティクス差し替え | 完了フラグとキャンセルフラグ両方を監視 |
| `FrontSemanticsController` | フロントセマンティクスの安定化 | ユーザー操作中も常に安定したノードを提供 |

## セマンティクス差し替えの手順

1. `BackSemanticsBuilder` が `List<SemanticEntry>` を生成。
2. スワップ直前に `SemanticsNode` を再構築し、`SemanticsConfiguration` を更新。
3. `SemanticsOwner.performAction` などでノード再利用が必要な場合は ID を付与してマッピング。
4. スワップ完了後に旧ノードを安全に dispose（`semanticsOwner.rootSemanticsNode.detach()` 等）。

## キュー設定の初期案

- スロットル間隔: 60ms（約 16fps）。これ以上の連続更新はリアルタイム追従を諦めて裏側で追随。
- タイムアウト: 500ms 以上裏側バッファが完成しない場合は最新リクエストのみを再実行し、古いジョブを破棄。
- 優先度: `SchedulerBinding.scheduleTask` の `Priority.touch`（リサイズ操作の一部として扱う）。
- キャンセル API: `cancelAndFlush()` を用意し、裏バッファ再構築中に新リクエストが来たら即破棄。

## 想定工数（概算）

1. 設計／ドキュメント更新 … 1.5〜2 人日  
2. 基盤コード整備（キュー、スワップ、セマンティクス分離） … 3〜4 人日  
3. 既存 Widget への適用・テスト（ユニット＋実機ログ検証） … 3 人日  
4. リグレッション対応・パフォーマンス調整 … 2 人日

## テスト戦略

- **ユニットテスト**  
  - キューのキャンセル／再投入が正しく動くか（最新ジョブのみ実行されるか）。
  - スワップ時にフロント／バックの役割が正しく入れ替わるか。
- **ウィジェットテスト**  
  - リサイズ中に複数回 `enqueue()` しても、フロントセマンティクスが常に同一ノードであること。
- **実機手動テスト**  
  - 長時間のウィンドウリサイズでも `.tmp/app.log` に `parentDataDirty` が出ないこと。
  - 列数変更直後でもプレビューやコピー操作が正しく動作すること。

## 残課題

- バックバッファ構築が重い場合、ユーザーは「滑らかな追随」を体感できない可能性がある。暫定対応として `Transform.scale` などフォールバック描画を検討。
- セマンティクス差し替え時にスクリーンリーダーが「大量の要素が一度に消えた」扱いをする可能性がある。必要に応じて `SemanticsService.announce` などで状態遷移を通知。
- バックバッファで画像を読み込む際のファイル I/O が二重になるため、キャッシュ戦略の見直しが必要。

## 実装順序（推奨）

1. ジオメトリ更新キュー（キャンセル・最新リクエストのみ処理）
2. バックバッファ構築／スワップ基盤
3. セマンティクス分離と差し替え処理
4. パフォーマンス計測＆チューニング（スロットル値調整、差分適用の検討）
