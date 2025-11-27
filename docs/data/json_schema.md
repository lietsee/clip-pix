# JSON出典情報スキーマ

**最終更新**: 2025-11-27
**実装ファイル**: `lib/data/metadata_writer.dart`, `lib/data/file_info_manager.dart`

## 概要

フォルダごとに生成される統合メタデータファイル `.fileInfo.json` の仕様。
画像およびテキストファイルのメタデータを配列形式で保存。

## ファイル配置

```
selected_folder/
├── .fileInfo.json       ← 統合メタデータファイル
├── image_001.jpg
├── image_002.png
├── note.txt
└── subfolder/
    ├── .fileInfo.json   ← サブフォルダ用
    └── photo.jpg
```

## スキーマ定義

### 配列形式

```json
[
  {
    "file": "image_20251020_123456.jpg",
    "saved_at": "2025-10-20T12:34:56.000Z",
    "source": "https://example.com/image.jpg",
    "source_type": "web"
  },
  {
    "file": "note.txt",
    "saved_at": "2025-10-20T12:35:00.000Z",
    "source": "Clipboard",
    "source_type": "local",
    "content_type": "text"
  }
]
```

## フィールド定義

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `file` | string | ✔ | ファイル名（パスではなくファイル名のみ） |
| `saved_at` | string | ✔ | 保存日時（ISO 8601 UTC形式） |
| `source` | string | ✔ | 出典元（URL または "Clipboard"） |
| `source_type` | enum | ✔ | 出典区分 |
| `content_type` | enum | - | コンテンツ種別（テキストの場合のみ必須） |

### source_type 値

| 値 | 説明 |
|----|------|
| `web` | URLからダウンロード |
| `local` | クリップボードまたはローカルファイル |
| `unknown` | 出典不明 |

### content_type 値 (2025-11-27追加)

| 値 | 説明 |
|----|------|
| `image` | 画像ファイル（省略時のデフォルト） |
| `text` | テキストファイル |

## 使用例

### 画像エントリ（クリップボード）

```json
{
  "file": "clipboard_20251027_143022.jpg",
  "saved_at": "2025-10-27T05:30:22.000Z",
  "source": "Clipboard",
  "source_type": "local"
}
```

### 画像エントリ（URLダウンロード）

```json
{
  "file": "download_20251027_143045.png",
  "saved_at": "2025-10-27T05:30:45.000Z",
  "source": "https://example.com/images/photo.png",
  "source_type": "web"
}
```

### テキストエントリ

```json
{
  "file": "note.txt",
  "saved_at": "2025-10-27T05:31:00.000Z",
  "source": "Clipboard",
  "source_type": "local",
  "content_type": "text"
}
```

## 実装詳細

### MetadataWriter

```dart
Future<void> appendEntry({
  required Directory directory,
  required String fileName,
  required String source,
  required ImageSourceType sourceType,
  ContentType contentType = ContentType.image,
}) async {
  final fileInfoPath = path.join(directory.path, '.fileInfo.json');
  final file = File(fileInfoPath);

  List<Map<String, dynamic>> entries = [];
  if (await file.exists()) {
    final content = await file.readAsString();
    entries = List<Map<String, dynamic>>.from(jsonDecode(content));
  }

  entries.add({
    'file': fileName,
    'saved_at': DateTime.now().toUtc().toIso8601String(),
    'source': source,
    'source_type': sourceType.name,
    if (contentType == ContentType.text) 'content_type': 'text',
  });

  await file.writeAsString(jsonEncode(entries));
}
```

### FileInfoManager

```dart
Future<Map<String, FileInfoEntry>> loadFileInfo(Directory directory) async {
  final fileInfoPath = path.join(directory.path, '.fileInfo.json');
  final file = File(fileInfoPath);

  if (!await file.exists()) {
    return {};
  }

  final content = await file.readAsString();
  final entries = List<Map<String, dynamic>>.from(jsonDecode(content));

  return {
    for (final entry in entries)
      entry['file'] as String: FileInfoEntry.fromJson(entry)
  };
}
```

## 互換性

### レガシー形式からの移行

以前の個別JSONファイル形式（`image_001.json`）は非推奨。
新しいファイルは `.fileInfo.json` に統合される。

```
// 旧形式（非推奨）
image_001.json → 個別メタデータ

// 新形式
.fileInfo.json → 統合メタデータ
```

### 下位互換性

- `.fileInfo.json` がない場合、個別JSONファイルを検索
- 両方存在する場合、`.fileInfo.json` を優先

## エラーハンドリング

| エラー | 対処 |
|--------|------|
| JSONパースエラー | 警告ログ、空配列として扱う |
| ファイル書き込みエラー | リトライ後、警告ログ |
| エントリ重複 | 上書き（同一ファイル名の場合） |

## 関連ドキュメント

- [Models](./models.md) - データモデル定義
- [Repositories](./repositories.md) - データアクセス層
- [ImageSaver](../system/image_saver.md) - 画像保存サービス
- [TextSaver](../system/text_saver.md) - テキスト保存サービス

## 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | content_type フィールド追加、統合メタデータ形式に更新 |
| 2025-10-20 | 初版作成 |
