# グリッド列変更時のセマンティクスアサーションについて

最終更新: 2025-10-25

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

## 課題

- 列数変更／一括揃えのような大量のカード更新時は、Semantics ツリーが完全に安定した後でグリッドを再構築する仕組みが必要。
- 現行の「Provider 経由で再読込しつつ ValueNotifier を毎カード更新する」構造では、セマンティクス完了を保証できていない。

## 次のステップ候補 (2025-10-25 時点)

1. 列数変更処理を `WidgetsBinding.instance.scheduleTask(..., Priority.touch)` 等でさらに後段にずらし、Semantics 更新と確実に分離する。
2. 一括揃え時はグリッド全体を一旦非表示にしてリビルドし、更新完了後に表示する（セマンティクス対象を完全に入れ替える）方式に変更する。
3. Semantics の提供範囲を見直し、デスクトップ版ではカード配列に対する詳細なアクセシビリティ情報を簡略化する。

## 関連ファイル

- `lib/ui/grid_view_module.dart`
- `.tmp/app.log`, `.tmp/ikkatsu.log`（再現ログ）
