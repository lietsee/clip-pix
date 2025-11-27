# データモデル

**作成日**: 2025-10-28
**最終更新**: 2025-11-27
**ステータス**: 実装完了

## モデル一覧

### ContentItem (基底クラス)

画像/テキストファイルの共通基底クラス。

```dart
abstract class ContentItem extends HiveObject {
  final String id;                    // 一意識別子（通常はファイルパス）
  final String filePath;              // ファイルパス
  final ContentType contentType;      // コンテンツの種類（IMAGE/TEXT）
  final ImageSourceType sourceType;   // ソースの種類（web/local/unknown）
  final DateTime savedAt;             // 保存日時（UTC）
  final String? source;               // ソースURL（該当する場合）
  final String memo;                  // メモ
  final int favorite;                 // お気に入りレベル（0-3）
}
```

### ImageItem

画像ファイルを表すモデル（ContentItemのサブクラス）。

```dart
class ImageItem extends ContentItem {
  final int? width;              // 画像幅（メタデータから取得）
  final int? height;             // 画像高さ
  final double? aspectRatio;     // アスペクト比

  // ContentTypeは常にContentType.image
}
```

### TextContentItem (2025-11-27追加)

テキストファイルを表すモデル（ContentItemのサブクラス）。

```dart
class TextContentItem extends ContentItem {
  final int? characterCount;     // 文字数
  final String? preview;         // プレビューテキスト（先頭100文字）

  // ContentTypeは常にContentType.text
}
```

### ContentType (2025-11-27追加)

コンテンツの種別。

```dart
enum ContentType {
  image,  // 画像ファイル（.jpg, .jpeg, .png）
  text,   // テキストファイル（.txt）
}
```

### ImageSourceType

画像/テキストの出典種別。

```dart
enum ImageSourceType {
  web,      // URLダウンロード
  local,    // クリップボードまたはローカルファイル
  unknown,  // 不明
}
```

**HiveAdapter**: TypeID 0

### ImageEntry

最近保存された画像の履歴エントリー。

```dart
class ImageEntry {
  final String path;            // 画像ファイルパス
  final DateTime savedTime;     // 保存日時
  final ImageSourceType source; // 出典
}
```

**用途**: `ImageHistoryNotifier` で最大20件保持

### GridCardPreference

個別カードのレイアウト設定。

```dart
class GridCardPreference {
  final String id;             // ContentItem.id
  final double width;          // カード幅（ピクセル）
  final double height;         // カード高さ
  final double scale;          // スケール倍率（1.0 = 100%）
  final int columnSpan;        // カラムスパン数
  final double? customHeight;  // ドラッグリサイズ時の高さ
  final Offset? panOffset;     // パン（ズーム位置）オフセット（2025-11-25追加）
}
```

**HiveAdapter**: TypeID 3
**デフォルト値**: `defaultWidth=200, defaultHeight=200, defaultScale=1.0, defaultColumnSpan=1`

### GridLayoutSettings

グリッド全体の設定。

```dart
class GridLayoutSettings {
  final int preferredColumns;      // デフォルト列数（初期表示）
  final int maxColumns;            // 最大列数
  final GridBackgroundTone background;  // 背景色
  final int bulkSpan;              // 一括リサイズ時の列幅
}
```

**HiveAdapter**: TypeID 4

### GridBackgroundTone

背景色の選択肢。

```dart
enum GridBackgroundTone {
  white,      // 白
  lightGray,  // 明るい灰
  darkGray,   // 暗い灰
  black,      // 黒
}
```

**HiveAdapter**: TypeID 5

**マッピング**:
- `white`: `Color(0xFFFFFFFF)`
- `lightGray`: `Color(0xFFE0E0E0)`
- `darkGray`: `Color(0xFF424242)`
- `black`: `Color(0xFF000000)`

### SelectedFolderState

選択中のフォルダとビュー状態。

```dart
class SelectedFolderState {
  final Directory? current;          // 選択中のディレクトリ
  final List<String> recentFolders;  // 最近使用したフォルダ（最大3件）
  final FolderViewMode viewMode;     // root or subfolder
  final String? currentTab;          // 選択中のサブフォルダ名
  final double scrollOffset;         // スクロール位置
}
```

**永続化**: Hive box `app_state` に保存

### FolderViewMode

フォルダビューモード。

```dart
enum FolderViewMode {
  root,       // ルートフォルダ表示
  subfolder,  // サブフォルダ表示（タブ切り替え）
}
```

### DeletionModeState (2025-11-27追加)

一括削除モードの状態。

```dart
class DeletionModeState {
  final bool isActive;              // 削除モードが有効
  final Set<String> selectedCardIds;  // 選択中のカードID
  final bool isDeleting;            // 削除処理実行中
}
```

**便利プロパティ**:
- `hasSelection`: 選択があるか
- `selectedCount`: 選択数
- `isSelected(cardId)`: 特定カードが選択されているか

### GridLayoutGeometry

グリッドの幾何情報（計算用）。

```dart
class GridLayoutGeometry {
  final int columnCount;      // カラム数
  final double columnWidth;   // カラム幅（ピクセル）
  final double gap;           // カード間ギャップ
}
```

**用途**: `GridLayoutLayoutEngine.compute()` の入力

### GridCardViewState

カードのビュー状態（レンダリング用）。

```dart
class GridCardViewState {
  final String id;             // ContentItem.id
  final double width;          // 描画幅
  final double height;         // 描画高さ
  final double scale;          // スケール
  final int columnSpan;        // カラムスパン
  final double? customHeight;  // カスタム高さ
  final Offset? panOffset;     // パンオフセット（2025-11-25追加）
}
```

**用途**: `GridLayoutStore` が管理

### LayoutSnapshot

レイアウト計算結果のスナップショット。

```dart
class LayoutSnapshot {
  final String id;                          // スナップショットID
  final GridLayoutGeometry geometry;        // 使用したジオメトリ
  final List<LayoutSnapshotEntry> entries;  // カード配置情報
}
```

### LayoutSnapshotEntry

個別カードの配置情報。

```dart
class LayoutSnapshotEntry {
  final String id;           // ContentItem.id
  final Rect rect;           // 描画位置とサイズ
  final int columnSpan;      // カラムスパン数
}
```

## JSON シリアライゼーション

### 統合メタデータ形式 (.fileInfo.json)

```json
[
  {
    "file": "image_001.jpg",
    "saved_at": "2025-10-28T10:30:00.000Z",
    "source": "https://example.com/image.jpg",
    "source_type": "web"
  },
  {
    "file": "note.txt",
    "saved_at": "2025-10-28T10:31:00.000Z",
    "source": "Clipboard",
    "source_type": "local",
    "content_type": "text"
  }
]
```

### ファイル配置

```
selected_folder/
  ├── .fileInfo.json       ← 統合メタデータ
  ├── image_001.jpg
  ├── image_002.png
  └── note.txt
```

## Hive TypeAdapterの実装

### 例: GridCardPreferenceAdapter

```dart
class GridCardPreferenceAdapter extends TypeAdapter<GridCardPreference> {
  @override
  final int typeId = 3;

  @override
  GridCardPreference read(BinaryReader reader) {
    return GridCardPreference(
      id: reader.readString(),
      width: reader.readDouble(),
      height: reader.readDouble(),
      scale: reader.readDouble(),
      columnSpan: reader.readInt(),
      customHeight: reader.readBool() ? reader.readDouble() : null,
      panOffset: reader.readBool()
        ? Offset(reader.readDouble(), reader.readDouble())
        : null,
    );
  }

  @override
  void write(BinaryWriter writer, GridCardPreference obj) {
    writer.writeString(obj.id);
    writer.writeDouble(obj.width);
    writer.writeDouble(obj.height);
    writer.writeDouble(obj.scale);
    writer.writeInt(obj.columnSpan);
    writer.writeBool(obj.customHeight != null);
    if (obj.customHeight != null) {
      writer.writeDouble(obj.customHeight!);
    }
    writer.writeBool(obj.panOffset != null);
    if (obj.panOffset != null) {
      writer.writeDouble(obj.panOffset!.dx);
      writer.writeDouble(obj.panOffset!.dy);
    }
  }
}
```

## バリデーション

### ContentItem

- `filePath`: 実在するファイルパス
- `id`: 空でない文字列
- `contentType`: ImageItem なら `image`、TextContentItem なら `text`

### GridCardPreference

- `width`, `height`: 正の数
- `scale`: 0より大きい（通常0.5〜2.0）
- `columnSpan`: 1以上、maxColumns以下
- `panOffset`: 任意（nullの場合は中央配置）

### GridLayoutSettings

- `preferredColumns`: 1〜maxColumns
- `maxColumns`: 1〜12
- `bulkSpan`: 1〜maxColumns

## 関連ドキュメント

- [Repositories](./repositories.md) - データアクセス層
- [State Management](../system/state_management.md) - モデルを使用する状態管理
- [JSON Schema](./json_schema.md) - JSONスキーマ詳細

## 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | ContentItem基底クラス、TextContentItem、ContentType、DeletionModeState追加 |
| 2025-11-25 | GridCardPreferenceにpanOffset追加 |
| 2025-10-28 | 初版作成 |
