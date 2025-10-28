# データレイヤー: Repositories

**作成日**: 2025-10-28
**ステータス**: 実装完了

## 概要

ClipPixのデータ永続化を担当するリポジトリクラス群です。すべてHiveベースで実装されています。

## リポジトリ一覧

### 1. GridLayoutSettingsRepository

**ファイル**: `lib/data/grid_layout_settings_repository.dart`

#### 管理データ

```dart
class GridLayoutSettings {
  final int preferredColumns;  // デフォルト列数
  final int maxColumns;        // 最大列数
  final GridBackgroundTone background;  // 背景色
  final int bulkSpan;          // 一括リサイズ時の列幅
}
```

#### Hive Box

- **名前**: `grid_layout`
- **キー**: `settings`
- **型**: `GridLayoutSettings`（TypeAdapter登録済み）

#### 主要API

```dart
GridLayoutSettings get value  // 現在の設定取得
Future<void> update(GridLayoutSettings settings)  // 設定更新
Stream<GridLayoutSettings> get stream  // 変更監視
```

### 2. GridCardPreferencesRepository

**ファイル**: `lib/data/grid_card_preferences_repository.dart`

#### 管理データ

```dart
class GridCardPreference {
  final String id;          // ImageItem.id
  final double width;       // カード幅
  final double height;      // カード高さ
  final double scale;       // スケール倍率
  final int columnSpan;     // カラムスパン数
  final double? customHeight;  // カスタム高さ
}
```

#### Hive Box

- **名前**: `grid_card_prefs`
- **キー**: ImageItem.id
- **型**: `GridCardPreference`

#### 主要API

```dart
GridCardPreference read(String id)  // 特定カードの設定取得
Future<void> save(GridCardPreference pref)  // 1件保存
Future<void> saveBatch(List<GridCardPreference> prefs)  // 一括保存
void delete(String id)  // 削除
```

### 3. GridOrderRepository

**ファイル**: `lib/data/grid_order_repository.dart`

#### 管理データ

カードのドラッグ&ドロップによるカスタム順序。

```dart
class GridOrder {
  final String folderId;        // フォルダID
  final List<String> orderedIds;  // ImageItem.idのリスト
}
```

#### Hive Box

- **名前**: `grid_order`
- **キー**: フォルダパス
- **型**: `List<String>`（JSON互換）

#### 主要API

```dart
List<String>? getOrder(String folderId)  // 順序取得
Future<void> saveOrder(String folderId, List<String> ids)  // 順序保存
```

### 4. ImageRepository

**ファイル**: `lib/data/image_repository.dart`

#### 責務

- 指定フォルダ内の画像ファイルスキャン
- JSONメタデータの読み込み
- `ImageItem` モデルへの変換

#### 主要API

```dart
Future<List<ImageItem>> scanFolder(String folderPath)  // フォルダスキャン
Future<ImageMetadata?> readMetadata(String imagePath)  // JSON読み込み
```

#### スキャン対象

- **画像拡張子**: `.jpg`, `.jpeg`, `.png`, `.gif`
- **メタデータ**: `image_name.json`（画像と同階層）

### 5. MetadataWriter

**ファイル**: `lib/data/metadata_writer.dart`

#### 責務

画像保存時にJSONメタデータを書き込む。

#### メタデータ構造

```json
{
  "source": "clipboard",
  "timestamp": "2025-10-28T10:30:00.000Z",
  "originalUrl": "https://example.com/image.jpg",
  "width": 1920,
  "height": 1080,
  "size": 524288
}
```

#### 主要API

```dart
Future<void> writeMetadata({
  required String imagePath,
  required ImageSourceType source,
  String? originalUrl,
  Size? imageSize,
  int? fileSize,
})
```

## Hive Box初期化

**ファイル**: `lib/main.dart`

```dart
Future<void> _openCoreBoxes() async {
  await Hive.openBox<GridLayoutSettings>('grid_layout');
  await Hive.openBox<GridCardPreference>('grid_card_prefs');
  await Hive.openBox<List<String>>('grid_order');
  await Hive.openBox<ImageEntry>('image_history');
  await Hive.openBox('app_state');  // SelectedFolderState
}
```

## TypeAdapter登録

```dart
void _registerHiveAdapters() {
  Hive.registerAdapter(ImageSourceTypeAdapter());     // TypeID: 0
  Hive.registerAdapter(ImageItemAdapter());            // TypeID: 1
  Hive.registerAdapter(ImageEntryAdapter());           // TypeID: 2
  Hive.registerAdapter(GridCardPreferenceAdapter());   // TypeID: 3
  Hive.registerAdapter(GridLayoutSettingsAdapter());   // TypeID: 4
  Hive.registerAdapter(GridBackgroundToneAdapter());   // TypeID: 5
}
```

## トランザクション管理

### 一括保存の最適化

```dart
// GridCardPreferencesRepository
Future<void> saveBatch(List<GridCardPreference> prefs) async {
  final box = Hive.box<GridCardPreference>('grid_card_prefs');
  await box.putAll(Map.fromEntries(
    prefs.map((p) => MapEntry(p.id, p))
  ));
}
```

**利点**: 複数カードのリサイズ時に1回のディスクI/Oで完了

## エラーハンドリング

### Box未初期化

```dart
if (!Hive.isBoxOpen('grid_layout')) {
  throw StateError('Hive box not initialized');
}
```

### ファイル読み込みエラー

```dart
try {
  final json = await File(metadataPath).readAsString();
  return ImageMetadata.fromJson(jsonDecode(json));
} catch (error) {
  _logger.warning('Failed to read metadata: $metadataPath', error);
  return null;  // nullで処理続行
}
```

## テストガイドライン

### ユニットテスト

```dart
test('GridLayoutSettingsRepository saves and loads', () async {
  await Hive.openBox('grid_layout');
  final repo = GridLayoutSettingsRepository();

  final settings = GridLayoutSettings(preferredColumns: 4, ...);
  await repo.update(settings);

  expect(repo.value.preferredColumns, 4);
});
```

### モック

```dart
class MockGridCardPreferencesRepository implements GridLayoutPersistence {
  final Map<String, GridCardPreference> _storage = {};

  @override
  GridLayoutPreferenceRecord read(String id) => _storage[id] ?? defaultPref;

  @override
  Future<void> saveBatch(List<GridLayoutPreferenceRecord> mutations) async {
    for (final m in mutations) {
      _storage[m.id] = m;
    }
  }
}
```

## パフォーマンス

### メモリ使用

- **grid_layout**: 1レコード（数百バイト）
- **grid_card_prefs**: カード数 × 100バイト（1000カード = 100KB）
- **grid_order**: フォルダ数 × ID配列サイズ

### ディスクI/O

- Hive はLazy Box非使用（全データをメモリに展開）
- `saveBatch` で一括書き込み最適化
- 変更時のみディスク同期

## 関連ドキュメント

- [Models](./models.md) - データモデル定義
- [GridLayoutStore](../system/state_management.md#gridlayoutstore) - リポジトリの使用側
