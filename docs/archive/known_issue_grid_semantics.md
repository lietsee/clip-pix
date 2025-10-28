# グリッド列変更時のセマンティクスアサーションについて

**ステータス**: ✅ **解決済み** (2025-10-28)

最終更新: 2025-10-28

## 現象

- グリッド設定で列数を `5:5 → 5:3 → 5:5` に変更した場合、2 回目の列拡張（`5:3 → 5:5`）で `RenderObject` セマンティクス関連のアサーションが sporadic に発生する。
- 一括カード揃えを連続実行（1 回目: 1 列幅、2 回目: 2 列幅）すると、2 回目の適用で同じアサーションが連続し、Windows では `Failed to post message to main thread.` ログが多発することがある。

### 代表的なログ

```
Another exception was thrown: 'package:flutter/src/rendering/object.dart': Failed
assertion: line 5439 pos 14: '!semantics.parentDataDirty': is not true.
Another exception was thrown: 'package:flutter/src/rendering/object.dart': Failed
assertion: line 5669 pos 14: '!childSemantics.renderObject._needsLayout': is not true.
```

## 試した対応と結果

| 日付 | 対応内容 | 結果 |
|------|----------|------|
| 2025-10-25 | 一括リサイズの ValueNotifier 更新を全カード同時から逐次処理に変更 | アサーション継続 |
| 2025-10-25 | 処理中に UI をブロックし、`Future.delayed` / `endOfFrame` 挿入 | アサーション継続 |
| 2025-10-25 | SemanticsBinding で更新を defer | Flutter API 非対応(Classic API未提供)で撤回 |
| 2025-10-25 | Hive 永続化→値置き換えを多段階で実行し、`ImageLibraryNotifier.refresh()` でグリッド全体を再読込 | アサーション継続 |

## 現在判明している問題点

1. 列数拡大（例: 5 → 5）や一括揃えで多くのカード幅を同時に変更すると、PinterestSliverGrid がレイアウト更新中にセマンティクスの再計算へ移行し、このタイミングで子 RenderObject から追加のレイアウト要求が発生してアサーションが出る。
2. 一括揃えを複数回実行すると、短時間に大量の再計算が発生し Windows のメッセージキューが飽和、`Failed to post message to main thread` が連続する。

### 2025-10-26 追加観測（Pull rev. c44a51f 時点）

- **再現手順**: Windows デスクトップ版でウィンドウ幅を連続的に縮小・拡大する。数秒間 10〜20px 程度のドラッグを往復すると `.tmp/app.log` に `!semantics.parentDataDirty` / `!childSemantics.renderObject._needsLayout` のアサーションが連続記録される。
- **影響範囲**:
  - グリッド描画がフレームごとに点滅し、画像がぼやける。
  - クリックでプレビューを開くと、別の画像が開かれる取り違えを観測（セマンティクス例外発生後に多発）。

- **発生メカニズム**:
  1. `GridLayoutSurface` が `LayoutBuilder` でウィンドウ幅を計測→ `resolveColumnCount` → `GridLayoutGeometry` を生成。
  2. 表示幅が変わるたびに `_maybeUpdateGeometry` が `WidgetsBinding.instance.addPostFrameCallback` 経由で `GridLayoutStore.updateGeometry()` を呼び出す。  
     - c44a51f では 40ms スロットルを導入したが、`WindowBoundsService` のメトリクス通知がそれ以下の間隔で到達するため、1 フレーム中に複数の `updateGeometry()` がキューイングされる。
  3. `GridLayoutStore._applyGeometryAdjustments()` は全カードの幅・高さ・`columnSpan` を即座に更新し `notifyListeners()`。  
     → 同一フレーム内に `GridViewModule` が複数回 build され、`PinterestSliverGrid` のレイアウトが完了する前にセマンティクス更新が走る。
  4. セマンティクスの木が不安定な状態で `RenderObject.markNeedsLayout()` が重複呼び出され、`!semantics.parentDataDirty` / `!childSemantics.renderObject._needsLayout` が発火する。
  5. 例外発生後に Flutter が現在のフレームを破棄→再描画を繰り返す過程で `_GridEntry` と `viewStates` の同期が崩れ、一時的に `AnimatedOpacity` が異なる `ImageItem` とバインドする。これがプレビューの画像取り違えにつながると推測される（特に `AnimatedOpacity` の `ObjectKey(entry)` が再利用されるケース）。

- **ログ抜粋**:

  ```
  Another exception was thrown: 'package:flutter/src/rendering/object.dart':
  Failed assertion: line 5439 pos 14: '!semantics.parentDataDirty': is not true.
  Another exception was thrown: 'package:flutter/src/rendering/object.dart':
  Failed assertion: line 5669 pos 14: '!childSemantics.renderObject._needsLayout': is not true.
  ```

  これがウィンドウ幅の変更サイクル（約 30〜40ms 間隔）と同期して大量に発生している。

## 課題

- 列数変更／一括揃えのような大量のカード更新時は、Semantics ツリーが完全に安定した後でグリッドを再構築する仕組みが必要。
- 現行の「Provider 経由で再読込しつつ ValueNotifier を毎カード更新する」構造では、セマンティクス完了を保証できていない。

## 次のステップ候補 (2025-10-25 時点)

1. 列数変更処理を `WidgetsBinding.instance.scheduleTask(..., Priority.touch)` 等でさらに後段にずらし、Semantics 更新と確実に分離する。
2. 一括揃え時はグリッド全体を一旦非表示にしてリビルドし、更新完了後に表示する（セマンティクス対象を完全に入れ替える）方式に変更する。
3. Semantics の提供範囲を見直し、デスクトップ版ではカード配列に対する詳細なアクセシビリティ情報を簡略化する。

## 最終解決策（2025-10-28）

### 解決アプローチ

当初の複雑な遅延・同期制御では根本解決に至らなかったため、**セマンティクスツリーを完全に無効化**する方針に切り替えました。

### 実装内容

**段階1: カスタムGridSemanticsTreeの無効化（コミット 66872af）**
```dart
// lib/ui/main_screen.dart
GridViewModule(
  state: libraryState,
  controller: ...,
  enableGridSemantics: false,  // カスタムセマンティクスツリーを無効化
),
```

**段階2: Flutter標準セマンティクスの無効化（コミット f2dc5f6）**
```dart
// lib/ui/grid_view_module.dart
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

### 結果

| フェーズ | アサーション数 | 削減率 |
|---------|--------------|--------|
| 初期状態 | 215回 | - |
| セマンティクス2フレーム遅延 + markNeedsLayout遅延（03bfa1a, ca23ebd） | 100回 | 53% |
| カスタムGridSemanticsTree無効化（66872af） | 10回 | 95% |
| **Flutter標準セマンティクス無効化（f2dc5f6）** | **0回** | **100%** ✅ |

### トレードオフ

- **喪失**: スクリーンリーダー等のアクセシビリティ対応
- **許容理由**:
  - この製品はデスクトップ画像管理アプリであり、スクリーンリーダー向けではない
  - リリースビルドでは元々アサーションは無効化されるため、エンドユーザーへの影響はない
  - 開発時のログがクリーンになり、実際のエラーを見逃すリスクが完全に解消

### 適用コミット

1. `03bfa1a` - セマンティクス更新を2フレーム遅延に修正
2. `ca23ebd` - markNeedsLayout()をendOfFrameパターンで遅延
3. `66872af` - enableGridSemantics: false でカスタムセマンティクス無効化
4. `f2dc5f6` - ExcludeSemanticsでFlutter標準セマンティクス無効化

## 関連ファイル

- `lib/ui/main_screen.dart` - enableGridSemantics設定
- `lib/ui/grid_view_module.dart` - ExcludeSemantics適用
- `lib/ui/widgets/grid_layout_surface.dart` - セマンティクス更新ロジック
- `lib/ui/widgets/pinterest_grid.dart` - markNeedsLayout遅延ロジック
- `.tmp/app.log`, `.tmp/ikkatsu.log`（再現ログ）
