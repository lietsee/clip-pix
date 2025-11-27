# ClipboardMonitor 詳細設計

**最終更新**: 2025-11-27
**実装ファイル**: `lib/system/clipboard_monitor.dart`

## 1. 概要

クリップボードの画像/URL/テキストを監視し、自動的に保存処理をトリガー。

## 2. 責務

- Win32 hook またはフォールバックポーリングでクリップボード更新を検知
- 新しい画像 → `ImageSaver` へ送信
- 新しいURL → `UrlDownloadService` → `ImageSaver` へ送信
- 新しいテキスト（非URL） → `TextSaver` へ送信
- Provider の選択フォルダ状態を購読し、未選択時は監視を停止
- 取得データを JSON メタデータ生成用に正規化して渡す

## 3. 入出力

| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 出力 | `onImageCaptured` | `Future<void> Function(Uint8List, {String? source, ImageSourceType})` | 新規画像検出イベント |
| 出力 | `onUrlCaptured` | `Future<void> Function(String url)` | URLコピー検出イベント |
| 出力 | `onTextCaptured` | `Future<void> Function(String text)` | テキストコピー検出イベント |
| 入力 | `getSelectedFolder` | `Directory? Function()` | 監視状態判定のためのフォルダ取得 |

## 4. データ種別と優先順位

| 優先度 | クリップボード形式 | 処理先 | 説明 |
|--------|-------------------|--------|------|
| 1 | `CF_DIBV5` | `ImageSaver` | DIBV5 形式の画像（アルファチャンネル対応） |
| 2 | PNG (RegisterClipboardFormat) | `ImageSaver` | PNG 形式の画像 |
| 3 | `CF_DIB` | `ImageSaver` | DIB 形式の画像 |
| 4 | `CF_UNICODETEXT` (URL) | `UrlDownloadService` → `ImageSaver` | HTTP/HTTPS URL |
| 5 | `CF_UNICODETEXT` (Text) | `TextSaver` | 非URLテキスト |

**判定フロー**:
```
1. 画像形式チェック（DIBV5 → PNG → DIB）
   └─ 見つかった場合 → ImageSaver
2. テキストチェック（CF_UNICODETEXT）
   ├─ URLの場合 → UrlDownloadService
   └─ 非URLの場合 → TextSaver
```

## 5. 使用ライブラリ

- `win32` - Windows API 呼び出し
- `ffi` - ネイティブ FFI バインディング
- `crypto` - ハッシュベース重複検出

## 6. シーケンス番号監視

クリップボード変更検出のコア機能:

```dart
// 起動時にベースラインを取得
_baselineSequenceNumber = GetClipboardSequenceNumber();
_hasSequenceAdvanced = false;

// 400ms間隔でシーケンス番号をチェック
void _checkClipboardSequence() {
  final sequence = GetClipboardSequenceNumber();
  if (sequence != _lastSequenceNumber) {
    // 変更検出 → スナップショット処理
    _processClipboardSnapshot();
  }
}
```

- **起動直後**: ベースライン番号を記録し、最初の変更が発生するまでスキップ
- **変更検出**: シーケンス番号が変わったらスナップショット読み取り

## 7. ガードトークン

`ClipboardCopyService` による自己トリガー防止:

```dart
abstract class ClipboardMonitorGuard {
  void setGuardToken(String token, Duration ttl);
  void clearGuardToken();
}
```

- トークン設定中はクリップボード変更を無視
- TTL: デフォルト2秒
- `_isGuardActive` でトークン有効性をチェック

## 8. 重複検出

```dart
// SHA-1 ハッシュで重複判定
final Map<String, DateTime> _recentHashes;  // 直近2秒以内
final Set<String> _sessionHashes;           // セッション全体

bool _isDuplicate(String hash) {
  // 2秒以内の重複は無視
  _recentHashes.removeWhere((k, v) => now.difference(v) > _duplicateWindow);
  return _recentHashes.containsKey(hash);
}
```

## 9. イベントキュー

```dart
final Queue<_ClipboardEvent> _eventQueue;  // 最大10件

void _enqueueEvent(_ClipboardEvent event) {
  if (_eventQueue.length >= _maxQueueSize) {
    final dropped = _eventQueue.removeFirst();
    _logger.warning('queue_drop oldest=${dropped.timestamp}');
  }
  _eventQueue.add(event);
  _scheduleQueueDrain();
}
```

- FIFO キュー（最大10件）
- `ImageSaver` がビジー中はキューに蓄積
- 溢れた場合は最古を破棄

## 10. 監視制御

| 状態 | 動作 |
|------|------|
| フォルダ未選択 | 監視停止 |
| フォルダ選択済み | 監視開始 |
| `onFolderChanged(null)` | フック解除、監視停止 |
| `onFolderChanged(directory)` | フック再登録、監視再開 |

## 11. Win32 Hook 実装

```dart
// 専用 Isolate でフック登録
void _clipboardHookIsolate(_HookInitMessage message) {
  final setWinEventHook = user32.lookupFunction<...>('SetWinEventHook');

  final hookHandle = setWinEventHook(
    _eventSystemClipboard,  // 0x00000006
    _eventSystemClipboard,
    nullptr,
    _callbackPointer,
    0, 0,
    _wineventOutOfContext | _wineventSkipOwnProcess,
  );
}
```

- フック登録失敗時は 500ms ポーリングにフォールバック
- フック成功時はイベント駆動で即座に検出

## 12. エラーハンドリング

| エラー | 対策 |
|--------|------|
| Clipboard読み取り失敗 | 警告ログ、2秒後に再試行 |
| 連続5回失敗 | 監視停止、Provider に例外状態を通知 |
| フック登録失敗 | ポーリングにフォールバック |
| 連続5回フォールバック | 1分間監視停止、その後フック再試行 |

## 13. ロギング

| レベル | メッセージ例 |
|--------|-------------|
| `INFO` | `Clipboard hook initialized` |
| `FINE` | `Clipboard sequence changed: 123` |
| `FINE` | `Duplicate clipboard image ignored` |
| `WARNING` | `Clipboard hook initialization failed, falling back to polling` |
| `WARNING` | `queue_drop oldest=2025-11-27T12:00:00` |

## 14. 設定UI連携 (2025-11-25追加)

```dart
// AppBar と GridSettingsDialog で監視状態を同期
WatcherStatusNotifier.setClipboardActive(bool isActive)
```

- 設定ダイアログからクリップボード監視のON/OFFが可能
- 状態変更は `WatcherStatusNotifier` 経由で全UIに反映

## 15. 関連ドキュメント

- `docs/system/image_saver.md` - 画像保存
- `docs/system/text_saver.md` - テキスト保存
- `docs/system/url_download_service.md` - URLダウンロード
- `docs/system/clipboard_copy_service.md` - クリップボードコピー

## 16. 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | TEXT対応、シーケンス番号監視、設定UI連携を追記 |
| 2025-10-20 | 初版作成 |
