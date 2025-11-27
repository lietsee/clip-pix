# データレイヤー: Repositories

**作成日**: 2025-10-28
**最終更新**: 2025-11-27
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
  final String id;            // ContentItem.id
  final double width;         // カード幅
  final double height;        // カード高さ
  final double scale;         // スケール倍率
  final int columnSpan;       // カラムスパン数
  final double? customHeight; // カスタム高さ
  final Offset? panOffset;    // パンオフセット（2025-11-25追加）
}
```

#### Hive Box

- **名前**: `grid_card_prefs`
- **キー**: ContentItem.id
- **型**: `GridCardPreference`

#### 主要API

```dart
GridCardPreference read(String id)  // 特定カードの設定取得
Future<void> save(GridCardPreference pref)  // 1件保存
Future<void> saveBatch(List<GridCardPreference> prefs)  // 一括保存
void delete(String id)  // 削除
```

#### 重要性 (2025-11-02追加)

`saveBatch()`はGridLayoutStoreの**write-through cacheパターン**の中核です：

- **メモリとHiveの同期**: すべてのカード状態更新メソッド（`updateGeometry()`, `updateCard()`, `applyBulkSpan()`, `restoreSnapshot()`）は、メモリ状態を更新後、即座に`saveBatch()`を呼び出してHiveに永続化します。

- **永続化を怠ると**: 後続の`syncLibrary()`呼び出しでHiveから**古い値**を読み込み、メモリ値とHive値の不一致が発生し、意図しないカードリビルドやグリッド並び替えが発生します（commit 9925ac1で修正）。

- **パフォーマンス**: バッチ保存により、個別保存よりもI/O効率が向上します。

詳細は`docs/system/state_management.md#103-persistence-synchronization-pattern-2025-11-02`を参照してください。

### 3. GridOrderRepository

**ファイル**: `lib/data/grid_order_repository.dart`

#### 管理データ

カードのドラッグ&ドロップによるカスタム順序。

```dart
class GridOrder {
  final String folderId;        // フォルダID
  final List<String> orderedIds;  // ContentItem.idのリスト
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

- 指定フォルダ内の画像/テキストファイルスキャン
- `.fileInfo.json` メタデータの読み込み
- `ContentItem` モデル（`ImageItem` / `TextContentItem`）への変換

#### 主要API

```dart
Future<List<ContentItem>> scanFolder(Directory directory)  // フォルダスキャン
Future<Map<String, FileInfoEntry>> loadFileInfo(Directory directory)  // メタデータ読み込み
```

#### スキャン対象

- **画像拡張子**: `.jpg`, `.jpeg`, `.png`
- **テキスト拡張子**: `.txt`（2025-11-27追加）
- **メタデータ**: `.fileInfo.json`（フォルダごとに1つ）

#### ContentItem生成ロジック

```dart
Future<List<ContentItem>> scanFolder(Directory directory) async {
  final fileInfo = await loadFileInfo(directory);
  final items = <ContentItem>[];

  await for (final entity in directory.list()) {
    if (entity is! File) continue;

    final ext = path.extension(entity.path).toLowerCase();
    final fileName = path.basename(entity.path);
    final info = fileInfo[fileName];

    if (['.jpg', '.jpeg', '.png'].contains(ext)) {
      items.add(ImageItem.fromFile(entity, info));
    } else if (ext == '.txt') {
      items.add(TextContentItem.fromFile(entity, info));
    }
  }

  return items;
}
```

### 5. OpenPreviewsRepository (2025-11-27追加)

**ファイル**: `lib/data/open_previews_repository.dart`

#### 責務

プレビューウィンドウの状態を永続化し、アプリ再起動時に復元可能にする。

#### 管理データ

```dart
class OpenPreviewEntry {
  final String itemId;       // ContentItem.id（ファイルパス）
  final bool alwaysOnTop;    // 常に最前面フラグ
  final DateTime openedAt;   // オープン日時
}
```

#### Hive Box

- **名前**: `open_previews`
- **キー**: ContentItem.id
- **型**: `OpenPreviewEntry`

#### 主要API

```dart
List<OpenPreviewEntry> getAll()                      // 全エントリ取得
Future<void> add(String itemId, {bool alwaysOnTop})  // エントリ追加
Future<void> remove(String itemId)                   // エントリ削除
Future<void> removeOlderThan(Duration duration)      // 古いエントリ削除
```

#### 使用例

```dart
// PreviewProcessManager
Future<void> registerProcess(String itemId, Process process, {bool alwaysOnTop}) async {
  _processes[itemId] = process;
  await _repository?.add(itemId, alwaysOnTop: alwaysOnTop);
}

void _handleProcessExit(String itemId) {
  _processes.remove(itemId);
  _repository?.remove(itemId);
}
```

### 6. MetadataWriter

**ファイル**: `lib/data/metadata_writer.dart`

#### 責務

画像/テキスト保存時にJSONメタデータを `.fileInfo.json` に追記。

#### 主要API

```dart
Future<void> appendEntry({
  required Directory directory,
  required String fileName,
  required String source,
  required ImageSourceType sourceType,
  ContentType contentType = ContentType.image,
})
```

#### 使用例

```dart
// ImageSaver
await metadataWriter.appendEntry(
  directory: targetDirectory,
  fileName: 'clipboard_20251027.jpg',
  source: 'Clipboard',
  sourceType: ImageSourceType.local,
);

// TextSaver
await metadataWriter.appendEntry(
  directory: targetDirectory,
  fileName: 'note.txt',
  source: 'Clipboard',
  sourceType: ImageSourceType.local,
  contentType: ContentType.text,
);
```

### 7. FileInfoManager

**ファイル**: `lib/data/file_info_manager.dart`

#### 責務

`.fileInfo.json` の読み込みと解析。

#### 主要API

```dart
Future<Map<String, FileInfoEntry>> loadFileInfo(Directory directory)
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
  await Hive.openBox('open_previews');  // OpenPreviewEntry（2025-11-27追加）
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
  final json = await File(fileInfoPath).readAsString();
  return FileInfoEntry.fromJson(jsonDecode(json));
} catch (error) {
  _logger.warning('Failed to read fileInfo: $fileInfoPath', error);
  return {};  // 空マップで処理続行
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
- **open_previews**: オープン中のプレビュー数 × 200バイト

### ディスクI/O

- Hive はLazy Box非使用（全データをメモリに展開）
- `saveBatch` で一括書き込み最適化
- 変更時のみディスク同期

## 関連ドキュメント

- [Models](./models.md) - データモデル定義
- [JSON Schema](./json_schema.md) - JSONスキーマ
- [GridLayoutStore](../system/state_management.md#gridlayoutstore) - リポジトリの使用側

## 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | OpenPreviewsRepository追加、ImageRepositoryのTEXT対応、統合メタデータ対応 |
| 2025-11-02 | write-through cacheパターンの重要性を追記 |
| 2025-10-28 | 初版作成 |
