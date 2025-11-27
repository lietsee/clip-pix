# FileWatcher 詳細設計

**最終更新**: 2025-11-27
**実装ファイル**: `lib/system/file_watcher.dart`

## 1. 概要

フォルダ内の追加・削除・変更イベントを監視してUI更新を通知。
画像ファイル（JPEG/PNG）およびテキストファイル（.txt）を対象とする。

## 2. 責務

- OSレベルの変更通知を購読
- Provider 経由で選択中のルートフォルダへ監視をアタッチ
- 新規ファイル発見時は `ImageLibraryNotifier` へ追加連携し、`GridViewModule` の再描画を促す
- サポート対象外のファイルイベントは無視し、ログのみに記録
- サブフォルダの増減を検知し、タブUI再構築を通知

## 3. インターフェース

### コンストラクタ

```dart
FileWatcherService({
  required WatcherStatusNotifier watcherStatus,
  required FutureOr<void> Function(File file) onFileAdded,
  required FutureOr<void> Function(String path) onFileDeleted,
  required FutureOr<void> Function() onStructureChanged,
  Duration debounceDuration = const Duration(milliseconds: 250),
  Logger? logger,
})
```

| パラメータ | 型 | 説明 |
|-----------|-----|------|
| `watcherStatus` | `WatcherStatusNotifier` | 監視状態の通知先 |
| `onFileAdded` | `FutureOr<void> Function(File)` | 新規ファイル検知コールバック |
| `onFileDeleted` | `FutureOr<void> Function(String)` | ファイル削除検知コールバック |
| `onStructureChanged` | `FutureOr<void> Function()` | サブフォルダ構造変更コールバック |
| `debounceDuration` | `Duration` | デバウンス間隔（デフォルト: 250ms） |
| `logger` | `Logger?` | ロガー（デフォルト: `Logger('FileWatcherService')`） |

### メソッド

| メソッド | 説明 |
|----------|------|
| `Future<void> start(Directory directory)` | 監視開始 |
| `Future<void> stop()` | 監視停止 |
| `bool get isActive` | 監視中かどうか |

## 4. 使用ライブラリ

- `package:watcher` - クロスプラットフォーム対応のファイル監視
- `package:path` - パス正規化
- `package:logging` - ログ出力

## 5. 監視対象ファイル

```dart
static const Set<String> _supportedExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.txt',
};
```

| 拡張子 | コンテンツタイプ | 説明 |
|--------|-----------------|------|
| `.jpg`, `.jpeg` | IMAGE | JPEG画像 |
| `.png` | IMAGE | PNG画像 |
| `.txt` | TEXT | テキストファイル |

## 6. 監視対象スコープ

- ルートフォルダ直下の全サブフォルダを `DirectoryWatcher` で個別監視
- 隠しフォルダ（`.` で始まる名前）は除外
- サブフォルダ作成・削除イベントは `onStructureChanged` を発火し、タブUIの再構築を促す
- 監視対象は Provider の `SelectedFolderState` が更新される度に再初期化し、未選択時は監視を停止

### フォルダ構造例

```
selected_folder/        ← ルート監視
├── .hidden/           ← 除外
├── subfolder_a/       ← 個別監視
│   ├── image.png     ← 検知 (IMAGE)
│   └── note.txt      ← 検知 (TEXT)
├── subfolder_b/       ← 個別監視
└── screenshot.jpg     ← 検知 (IMAGE)
```

## 7. イベント処理フロー

```
WatchEvent
    │
    ▼
_shouldEmit() ─────────► 250ms以内の重複 → 無視
    │
    ▼
_handleEvent()
    │
    ├─► ADD/MODIFY
    │       │
    │       ├─► ディレクトリ → _onDirectoryAdded() → onStructureChanged
    │       │
    │       └─► ファイル
    │               │
    │               ├─► サポート対象 → onFileAdded(file)
    │               │
    │               └─► 対象外 → ログのみ
    │
    └─► REMOVE
            │
            ├─► 監視中のディレクトリ → _cleanupWatcher() → onStructureChanged
            │
            ├─► サポート対象ファイル → onFileDeleted(path)
            │
            └─► 対象外 → 無視
```

## 8. イベントデバウンス

```dart
bool _shouldEmit(String path, ChangeType type) {
  final key = '$path-${type.toString()}';
  final now = DateTime.now();
  final last = _debounceTracker[key];
  if (last != null && now.difference(last) < _debounceDuration) {
    return false;
  }
  _debounceTracker[key] = now;
  return true;
}
```

- 連続する同一パス・同一イベントタイプは 250ms 窓でまとめ、重複通知を防ぐ
- 監視開始直後の初期イベントは `_watcherReady` フラグで無視
- 初期読み込みは `ImageLibraryNotifier` 側で別途実行

## 9. 状態管理連携

```dart
// 監視開始時
_watcherStatus.setFileWatcherActive(true);

// 監視停止時
_watcherStatus.setFileWatcherActive(false);

// エラー発生時
_watcherStatus.setError('Watcher error: $error');
```

- `WatcherStatusNotifier` 経由でUI（AppBar、設定ダイアログ）に監視状態を反映
- エラー状態は SnackBar やバナーで表示

## 10. エラーハンドリング

| エラー | 対策 |
|--------|------|
| 監視対象ディレクトリ不在 | 警告ログを出力し、監視を開始しない |
| `watcher.ready` 失敗 | 警告ログを出力、イベント処理は継続 |
| 監視中のエラー | `WatcherStatusNotifier.setError()` で通知 |

## 11. 特殊ファイルの除外

```dart
// プローブファイルは削除イベントを無視
if (lower.endsWith('/.clip_pix_write_test') ||
    lower.endsWith('\\.clip_pix_write_test')) {
  return;
}
```

- `ImageSaver` / `TextSaver` が書き込み可能性チェックで作成するプローブファイルは無視

## 12. ロギング

| レベル | メッセージ例 |
|--------|-------------|
| `INFO` | `FileWatcher started for /path/to/folder` |
| `INFO` | `FileWatcher stopped` |
| `INFO` | `Subdirectory watcher added for /path/to/subfolder` |
| `INFO` | `Subdirectory watcher removed for /path/to/subfolder` |
| `FINE` | `File event dispatched for /path/to/image.png` |
| `FINE` | `File deletion dispatched for /path/to/note.txt` |
| `FINE` | `Ignore event for unsupported file: /path/to/file.pdf` |
| `WARNING` | `Watcher start aborted: directory does not exist` |
| `SEVERE` | `Watcher error for /path` |

## 13. 関連ドキュメント

- `docs/system/image_saver.md` - 画像保存
- `docs/system/text_saver.md` - テキスト保存
- `docs/system/state_management.md` - 状態管理
- `docs/ui/grid_view.md` - グリッドビュー

## 14. 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | .txt対応、WatcherStatusNotifier連携、API詳細追記 |
| 2025-10-20 | 初版作成 |
