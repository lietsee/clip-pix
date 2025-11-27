# TextSaver 仕様書

**最終更新**: 2025-11-27
**実装ファイル**: `lib/system/text_saver.dart`

## 1. 概要

クリップボードからのテキストデータを `.txt` ファイルとして保存するサービス。
`ImageSaver` と同様の設計パターンを踏襲し、メタデータ記録と統合。

## 2. 依存関係

```dart
import 'dart:io';
import 'package:logging/logging.dart';
import '../data/metadata_writer.dart';
import '../data/models/content_type.dart';
import '../data/models/image_source_type.dart';
import 'image_saver.dart';  // SaveResult を共有
```

## 3. インターフェース

### コンストラクタ

```dart
TextSaver({
  required Directory? Function() getSelectedFolder,
  MetadataWriter? metadataWriter,
  Logger? logger,
  DateTime Function()? now,
})
```

| パラメータ | 型 | 説明 |
|-----------|-----|------|
| `getSelectedFolder` | `Directory? Function()` | 保存先フォルダ取得コールバック |
| `metadataWriter` | `MetadataWriter?` | メタデータ書き込み（デフォルト: `MetadataWriter()`） |
| `logger` | `Logger?` | ロガー（デフォルト: `Logger('TextSaver')`） |
| `now` | `DateTime Function()?` | 現在時刻取得（テスト用） |

### メソッド

#### `saveTextData`

```dart
Future<SaveResult> saveTextData(
  String textData, {
  String? source,
  ImageSourceType sourceType = ImageSourceType.local,
  String? fileName,
})
```

| パラメータ | 型 | 説明 |
|-----------|-----|------|
| `textData` | `String` | 保存するテキストデータ |
| `source` | `String?` | ソース情報（デフォルト: `'Clipboard'`） |
| `sourceType` | `ImageSourceType` | ソース種別（デフォルト: `local`） |
| `fileName` | `String?` | ファイル名（拡張子なし、デフォルト: `'note'`） |

**戻り値**: `SaveResult`
- `SaveResult.completed(filePath, metadataPath)` - 成功
- `SaveResult.failed(error)` - 失敗

## 4. 定数

| 定数 | 値 | 説明 |
|-----|-----|------|
| `_maxTextBytes` | `1024 * 1024` (1MB) | テキストデータの最大サイズ |
| `_maxWriteAttempts` | `3` | 書き込み試行回数 |
| `_defaultBaseName` | `'note'` | デフォルトファイル名 |

## 5. 保存フロー

```
1. ディレクトリ検証
   ├─ getSelectedFolder() で保存先取得
   └─ 書き込み可能性チェック（.clip_pix_write_test プローブファイル）

2. テキストサニタイズ
   ├─ 制御文字削除（\n, \t, \r 以外）
   └─ 前後空白トリム

3. サイズチェック
   └─ 1MB 上限超過で SaveResult.failed('text_too_large')

4. ファイル名生成
   ├─ fileName 指定あり → サニタイズして使用
   └─ fileName 指定なし → 'note' を使用
   └─ 衝突回避: note.txt, note_1.txt, note_2.txt ...

5. テキスト書き込み
   └─ リトライ（最大3回、200ms 間隔）

6. メタデータ保存
   └─ .fileInfo.json に追記（skipIndividualJson: true）

7. 結果返却
   └─ SaveResult.completed または SaveResult.failed
```

## 6. セキュリティ

### テキストサニタイズ

```dart
String _sanitizeText(String text) {
  // 制御文字削除（U+0000-U+001F、ただし \n, \t, \r は許可）
  final sanitized = text.replaceAllMapped(
    RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'),
    (match) => '',
  );
  return sanitized.trim();
}
```

### ファイル名サニタイズ

```dart
String _sanitizeFileName(String fileName) {
  // パストラバーサル攻撃防止（スラッシュ、バックスラッシュ削除）
  var sanitized = fileName.replaceAll(RegExp(r'[/\\]'), '');
  // 英数字、日本語、アンダースコア、ハイフン以外を置換
  sanitized = sanitized.replaceAll(
    RegExp(r'[^a-zA-Z0-9\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF_\-]'),
    '_',
  );
  return sanitized.isEmpty ? _defaultBaseName : sanitized;
}
```

## 7. メタデータ形式

`.fileInfo.json` に以下のレコードを追加:

```json
{
  "file": "note.txt",
  "saved_at": "2025-11-27T12:00:00.000Z",
  "source": "Clipboard",
  "source_type": "local",
  "content_type": "text"
}
```

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `file` | `String` | ファイル名 |
| `saved_at` | `String` | UTC ISO8601 形式 |
| `source` | `String` | ソース情報 |
| `source_type` | `String` | `local` / `web` |
| `content_type` | `String` | `text`（IMAGE の場合は省略可） |

## 8. エラーハンドリング

| エラーコード | 原因 | 対策 |
|-------------|------|------|
| `no_selected_directory` | 保存先未選択 | フォルダ選択を促す |
| `directory_not_writable` | 書き込み権限なし | 別フォルダを選択 |
| `text_too_large` | 1MB 超過 | テキストを分割 |
| `write_failed` | 3回のリトライ後も失敗 | ディスク容量・権限確認 |

## 9. ロギング

| レベル | メッセージ例 |
|--------|-------------|
| `INFO` | `text_saved path=... metadata=... size=...` |
| `WARNING` | `Save aborted: no target directory selected` |
| `WARNING` | `Failed to write text file attempt=1` |

## 10. ClipboardMonitor との統合

`ClipboardMonitor` が `CF_UNICODETEXT` を検出し、URLでないと判定した場合に `TextSaver.saveTextData()` を呼び出す。

```dart
// main.dart での接続
TextSaver(
  getSelectedFolder: () => selectedFolderNotifier.state.current,
  metadataWriter: metadataWriter,
)

// ClipboardMonitor コールバック
onTextCaptured: (text) async {
  await textSaver.saveTextData(text);
}
```

## 11. 関連ドキュメント

- `docs/system/clipboard_monitor.md` - クリップボード監視
- `docs/system/image_saver.md` - 画像保存（設計パターン参考）
- `docs/data/json_schema.md` - メタデータスキーマ

## 12. 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | 初版作成 |
| 2025-10-29 | 実装完了（commit c8253d9） |
