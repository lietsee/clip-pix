# ClipboardCopyService 詳細設計

**最終更新**: 2025-11-27
**実装ファイル**: `lib/system/clipboard_copy_service.dart`

## 1. 概要

ImageCard/TextCard や PreviewWindow から `Ctrl+C` が発火した際に、対象コンテンツを Windows クリップボードへコピーする専用サービス。ClipboardMonitor への再トリガーを防ぐトークンを発行。

## 2. 責務

- 画像ファイルのバイナリを読み込み、PNG 形式でクリップボードへ設定
- テキストファイルの内容を読み込み、`CF_UNICODETEXT` 形式でクリップボードへ設定
- コピー処理前後で `avoidSelfTriggerToken` を生成・設定し、ClipboardMonitor に通知
- 失敗時のリトライとエラーログ出力を担当

## 3. インターフェース

| メソッド | 説明 |
|----------|------|
| `Future<void> copyImage(ImageItem item)` | 画像を読み込み、PNG形式でクリップボードに設定 |
| `Future<void> copyText(TextContentItem item)` | テキストを読み込み、クリップボードに設定 |
| `void registerMonitor(ClipboardMonitorGuard guard)` | ClipboardMonitor へガード通知先を登録 |

### ClipboardMonitorGuard

```dart
abstract class ClipboardMonitorGuard {
  void setGuardToken(String token, Duration ttl);
  void clearGuardToken();
}
```

## 4. copyImage フロー

```
1. UI から copyImage(ImageItem) 呼び出し
2. 内部キューに積み、逐次処理
3. 処理直前にUUIDベースのトークンを生成
4. guard.setGuardToken(token, ttl: 2秒) を実行
5. 画像ファイルを Uint8List として読み込み
6. RegisterClipboardFormat('PNG') で PNG フォーマットを確保
7. win32 API (OpenClipboard → EmptyClipboard → SetClipboardData) で登録
8. コピー完了後 1秒のディレイで guard.clearGuardToken()
9. 次のキューアイテムを処理
```

## 5. copyText フロー (2025-10-29追加)

```
1. UI から copyText(TextContentItem) 呼び出し
2. テキストファイルを読み込み
3. 処理直前にUUIDベースのトークンを生成
4. guard.setGuardToken(token, ttl: 2秒) を実行
5. win32 API (OpenClipboard → EmptyClipboard → SetClipboardData(CF_UNICODETEXT)) で登録
6. コピー完了後 1秒のディレイで guard.clearGuardToken()
```

## 6. Win32 API 使用

### 画像コピー

```dart
Future<void> _setClipboardImage(Uint8List bytes) async {
  final format = _ensurePngFormat();  // RegisterClipboardFormat('PNG')

  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final opened = OpenClipboard(NULL);
    if (opened != 0) {
      try {
        EmptyClipboard();
        final handle = _bytesToGlobal(bytes);  // GlobalAlloc → GlobalLock → copy
        SetClipboardData(format, handle.address);
        return;
      } finally {
        CloseClipboard();
      }
    }
    await Future.delayed(Duration(milliseconds: 150));
  }
}
```

### テキストコピー

```dart
Future<void> _setClipboardText(String text) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final opened = OpenClipboard(NULL);
    if (opened != 0) {
      try {
        EmptyClipboard();
        final handle = _stringToGlobal(text);  // UTF-16 変換
        SetClipboardData(CF_UNICODETEXT, handle.address);
        return;
      } finally {
        CloseClipboard();
      }
    }
    await Future.delayed(Duration(milliseconds: 150));
  }
}
```

## 7. ClipboardMonitor との連携

- Monitor 側はトークンが一致する更新を検知した場合、保存処理をスキップ
- トークン TTL はデフォルト 2 秒
- 連続コピーを考慮し、再コピー時は上書き可能
- トークンなし更新のみ通常処理
- クリアディレイを待たずに再実行が到達した場合は、既存トークンを更新して再利用

## 8. エラー処理

| エラー | 対策 |
|--------|------|
| `OpenClipboard` 失敗 | 最大3回リトライ（150ms間隔） |
| ファイル読み込み失敗 | 例外を投げ、UI側でダイアログ表示 |
| コピー処理中の例外 | トークンを解除し、ClipboardMonitor を通常状態へ |

## 9. テスト方針

- `copyImage` / `copyText` 実行時に `setGuardToken` → `clearGuardToken` が呼ばれることをモックで検証
- `win32` API 呼び出しをモックし、エラー時のリトライフローをテスト
- 実際のクリップボード I/O は Integration テスト (Windows CI) で確認

## 10. 関連ドキュメント

- `docs/system/clipboard_monitor.md` - クリップボード監視
- `docs/ui/image_card.md` - 画像カード（コピー元UI）
- `docs/ui/image_preview_window.md` - プレビューウィンドウ

## 11. 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | copyText 対応、Win32 API 詳細を追記 |
| 2025-10-20 | 初版作成 |
