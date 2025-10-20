# State Management 詳細設計

## 1. 目的
Provider + StateNotifier を用いて、フォルダ選択・監視制御・UI 更新を一元管理する。

## 2. Provider ツリー構成
- `AppStateProvider` : ルートに配置し、下記 StateNotifier とサービスを公開。
- `SelectedFolderNotifier` : 選択フォルダと履歴を管理。
- `WatcherStatusNotifier` : FileWatcher / ClipboardMonitor の稼働状態を追跡。
- `ImageHistoryNotifier` : 直近保存した画像のメタ情報を保持。
- `ClipboardCopyService` : 画像コピー処理とガードトークンを管理。

## 3. SelectedFolderState
| フィールド | 型 | 説明 |
|-----------|----|------|
| `current` | `Directory?` | 現在選択中のフォルダ |
| `history` | `List<Directory>` | 直近3件までのフォルダ履歴 |
| `viewMode` | `FolderViewMode` | `root` または `subfolder` |
| `currentTab` | `String?` | 選択中のサブフォルダ名（`viewMode=subfolder` の時に有効） |
| `rootScrollOffset` | `double` | ルート表示時のスクロール位置 |
| `isValid` | `bool` | フォルダが存在し書き込み可能か |

### 3.1 アクション
- `pickFolder()` : `file_selector` でディレクトリを取得し、`current`/`history` 更新。`viewMode` を `root` に初期化。
- `switchToRoot()` : `viewMode` を `root` に変更し、`currentTab` を null に設定。
- `switchToSubfolder(String name)` : `viewMode=subfolder` とし、`currentTab` を更新。
- `updateRootScroll(double offset)` : ルート表示スクロール位置を保持。
- `clearFolder()` : フォルダを解除し、監視を停止。
- `restoreFromHive(HiveBox box)` : アプリ起動時に履歴と表示モードを復元。
- `persist()` : 状態更新毎に Hive へ保存。

## 4. WatcherStatusState
| フィールド | 型 | 説明 |
|-----------|----|------|
| `fileWatcherActive` | `bool` | FileWatcher 稼働フラグ |
| `clipboardActive` | `bool` | ClipboardMonitor 稼働フラグ |
| `lastError` | `String?` | 直近の異常メッセージ |

### 4.1 アクション
- `onFolderChanged(Directory?)` : フォルダ選択状態に応じて監視の開始/停止を指示。
- `setError(String message)` : エラー発生時に UI 通知を促す。
- `clearError()` : エラー解消時に呼び出す。

## 5. ImageHistoryState
| フィールド | 型 | 説明 |
|-----------|----|------|
| `entries` | `Queue<ImageEntry>` | 直近保存(最大20件)のメタ情報 |

`ImageEntry`
| フィールド | 型 | 説明 |
|-----------|----|------|
| `filePath` | `String` | 保存した画像パス |
| `metadataPath` | `String` | JSON メタデータのパス |
| `sourceType` | `String` | `web`/`local`/`unknown` |
| `savedAt` | `DateTime` | 保存時刻 |

### 5.1 アクション
- `addEntry(ImageEntry entry)` : 新規保存時に履歴へ追加し、Queue サイズを調整。
- `clear()` : 初期化または設定リセット時に履歴を破棄。

- `SelectedFolderNotifier` : `hive_box.put('selected_folder', {...})` でフォルダ・履歴・`viewMode`・`currentTab`・`rootScrollOffset` を保存。
- `ImageHistoryNotifier` : オプションで `hive_box.put('image_history', ...)` 保存。既定はアプリ終了時のみ同期。
- Hive 初期化はアプリ起動時に `AppStateProvider` が実施し、復元時の例外はログに記録してデフォルト状態にフォールバック。

## 7. ClipboardCopyService 連携
- `AppStateProvider` で `ClipboardCopyService` をシングルトン生成し、`ClipboardMonitor` のガードインターフェースに登録。
- `ImageCard` / `ImagePreviewWindow` からの `onCopyImage` は `ClipboardCopyService.copyImage` を呼び出し、完了後にガードトークンを解除。
- `WatcherStatusNotifier` はコピー処理中に Monitor を停止させず、ガードトークン判定により自己トリガーを避ける。
- 最前面トグルなど他イベントとの競合が発生した場合は、Service 側で逐次処理キューに積み、重複コピーを防止。

## 8. UI 連携ポイント
- MainScreen : `SelectedFolderState` を監視し、AppBar ボタン表示と Tabs 再構築を行う。
- FileWatcher / ClipboardMonitor : `WatcherStatusNotifier` と `SelectedFolderNotifier` を購読し、開始/停止をコントロール。
- SnackbarController : `WatcherStatusState.lastError` を監視してユーザーに通知。

## 9. テスト方針
- StateNotifier のユニットテストで Hive モックを用い、履歴更新と復元を検証。
- 監視フラグの切り替えは FileWatcher / ClipboardMonitor のスタブを使って `onFolderChanged` の呼び出し順序を確認。
- ImageHistory のサイズ制限 (最大20件) と FIFO 振る舞いをテスト。
