# ClipboardCopyService 詳細設計

## 1. 概要
ImageCard や ImagePreviewWindow から `Ctrl+C` が発火した際に、対象画像を Windows クリップボードへコピーする専用サービス。ClipboardMonitor への再トリガーを防ぐトークンを発行し、Photoshop 等の外部アプリへの貼り付けを可能にする。

## 2. 責務
- 画像ファイルのバイナリを読み込み、`CF_DIB` / `CF_BITMAP` 形式でクリップボードへ設定。
- コピー処理前後で `avoidSelfTriggerToken` を生成・設定し、ClipboardMonitor に通知。
- 失敗時のリトライとエラーログ出力を担当。

## 3. インターフェース
| メソッド | 説明 |
|----------|------|
| `Future<void> copyImage(ImageItem item)` | 画像を読み込み、クリップボードに設定 |
| `void registerMonitor(ClipboardMonitorGuard guard)` | ClipboardMonitor へガード通知先を登録 |

### ClipboardMonitorGuard
```dart
abstract class ClipboardMonitorGuard {
  void setGuardToken(String token, Duration ttl);
  void clearGuardToken();
}
```

## 4. フロー
1. UI から `copyImage` 呼び出し。サービス側は内部キューに積み、逐次処理する。
2. 処理直前に `UUID` ベースのトークンを生成し、`guard.setGuardToken(token, ttl: 2秒)` を実行。
3. 画像ファイルを `Uint8List` として読み込み、`RegisterClipboardFormat('PNG')` で PNG フォーマットを確保した上で `win32` API (`OpenClipboard` → `EmptyClipboard` → `SetClipboardData`) で登録。
4. コピー完了後 1 秒のディレイで `guard.clearGuardToken()` を実行し、次のキューアイテムを処理。
5. エラー発生時はトークンを即時解除し、例外を UI に伝搬。失敗したジョブはキューから除去し、再実行は UI に委譲。

## 5. ClipboardMonitor との連携
- Monitor 側はトークンが一致する更新を検知した場合、保存処理をスキップしてログ `self_copy_skipped` を出力。
- トークン TTL はデフォルト 2 秒。連続コピーを考慮し、再コピー時は上書き可能。
- トークンなし更新のみ通常処理。
- クリアディレイを待たずに再実行が到達した場合は、既存トークンを更新して再利用。

## 6. エラー処理
- `OpenClipboard` 失敗時は最大 3 回リトライし、失敗時は SnackBar とログ記録。
- 画像読み込み失敗時は例外を投げ、UI 側でダイアログ表示。
- コピー処理中に例外が発生した場合はトークンを解除し、ClipboardMonitor を通常状態へ戻す。

## 7. テスト方針
- `copyImage` 実行時に `setGuardToken` → `clearGuardToken` が呼ばれることをモックで検証。
- `win32` API 呼び出しをモックし、エラー時のリトライフローをテスト。
- 実際のクリップボード I/O は Integration テスト (Windows CI) で確認。
