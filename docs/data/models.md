# データモデル

**作成日**: 2025-10-28
**ステータス**: 実装完了

## モデル一覧

### ImageItem

画像ファイルとメタデータを表すモデル。

```dart
class ImageItem {
  final String id;              // ファイルパスのハッシュ
  final String path;            // 画像ファイルの絶対パス
  final String fileName;        // ファイル名
  final DateTime modifiedTime;  // 更新日時
  final ImageMetadata? metadata;  // JSONメタデータ（オプション）
  final int? width;             // 画像幅（メタデータから取得）
  final int? height;            // 画像高さ
}
```

### ImageMetadata

画像保存時に記録されるメタデータ（JSON）。

```dart
class ImageMetadata {
  final ImageSourceType source;  // clipboard, url, file
  final DateTime timestamp;      // 保存日時
  final String? originalUrl;     // URL元（URL保存時のみ）
  final int? width;              // 画像幅
  final int? height;             // 画像高さ
  final int? fileSize;           // ファイルサイズ（バイト）
}
```

### ImageSourceType

画像の出典種別。

```dart
enum ImageSourceType {
  clipboard,  // クリップボードから保存
  url,        // URLダウンロード
  file,       // ファイルコピー
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
  final String id;             // ImageItem.id
  final double width;          // カード幅（ピクセル）
  final double height;         // カード高さ
  final double scale;          // スケール倍率（1.0 = 100%）
  final int columnSpan;        // カラムスパン数
  final double? customHeight;  // ドラッグリサイズ時の高さ
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
  final String? folderPath;        // 選択中のフォルダ
  final List<String> recentFolders;  // 最近使用したフォルダ（最大3件）
  final FolderViewMode viewMode;   // root or subfolder
  final String? currentTab;        // 選択中のサブフォルダ名
  final double scrollOffset;       // スクロール位置
}
```

**永続化**: Hive box `app_state` に保存

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
  final String id;             // ImageItem.id
  final double width;          // 描画幅
  final double height;         // 描画高さ
  final double scale;          // スケール
  final int columnSpan;        // カラムスパン
  final double? customHeight;  // カスタム高さ
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
  final String id;           // ImageItem.id
  final Rect rect;           // 描画位置とサイズ
  final int columnSpan;      // カラムスパン数
}
```

## JSON シリアライゼーション

### ImageMetadata JSON例

```json
{
  "source": "url",
  "timestamp": "2025-10-28T10:30:00.000Z",
  "originalUrl": "https://example.com/image.jpg",
  "width": 1920,
  "height": 1080,
  "size": 524288
}
```

### ファイル配置

```
selected_folder/
  ├── image_001.jpg
  ├── image_001.json  ← ImageMetadata
  ├── image_002.png
  └── image_002.json
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
  }
}
```

## バリデーション

### ImageItem

- `path`: 実在するファイルパス
- `id`: 空でない文字列

### GridCardPreference

- `width`, `height`: 正の数
- `scale`: 0より大きい（通常0.5〜2.0）
- `columnSpan`: 1以上、maxColumns以下

### GridLayoutSettings

- `preferredColumns`: 1〜maxColumns
- `maxColumns`: 1〜12
- `bulkSpan`: 1〜maxColumns

## 関連ドキュメント

- [Repositories](./repositories.md) - データアクセス層
- [State Management](../system/state_management.md) - モデルを使用する状態管理
