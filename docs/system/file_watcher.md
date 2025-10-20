# FileWatcher 詳細設計

## 1. 概要
フォルダ内の追加・削除・変更イベントを監視してUI更新を通知。

## 2. 責務
- OSレベルの変更通知を購読。
- Provider 経由で選択中のルートフォルダへ監視をアタッチ。
- 新規画像発見時は ImageLibraryNotifier へ追加連携し、GridViewModule の再描画を促す。
- 画像以外のイベントは無視し、ログのみに記録。

## 3. 入出力
| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 入力 | targetFolder | `Directory` | 監視対象フォルダ |
| 出力 | onFileAdded | `Function(File)` | 新規ファイル検知通知 |
| 出力 | onFileDeleted | `Function(String path)` | 削除通知 |
| 出力 | onStructureChanged | `VoidCallback` | サブフォルダ増減時のタブ再構築通知 |

## 4. 使用ライブラリ
- `package:watcher`

## 5. エラーハンドリング
- 監視失敗時はバックオフ3秒で再監視。
- 権限エラー時はユーザー通知。
- ログ出力は `./logs/app.log` に追記し、書き込み不能時は Provider 経由で SnackBar を要求。

## 6. 監視対象スコープ
- ルートフォルダ直下の全サブフォルダを `DirectoryWatcher` で個別監視し、`jpg|jpeg|png` のみを対象とする。
- サブフォルダ作成・削除イベントは `onStructureChanged` を発火し、タブUIの再構築を促す。
- 監視対象は Provider の `SelectedFolderState` が更新される度に再初期化し、未選択時は監視を停止。

## 7. イベントデバウンス
- 連続する同一パスのイベントは 250ms 窓でまとめ、重複通知を防ぐ。
- 監視開始直後の初期イベントスパイクは無視し、初期読み込みは ImageRepository / ImageLibraryNotifier 側で別途実行。

## 8. ログ・テレメトリ
- 重大エラー（監視初期化失敗、権限エラー）は `error` レベルで出力。
- 通常の追加／削除イベントは `debug` レベルでパス・イベント種別を JSON 形式でログ。
- ログ書き込み不可が連続3回発生した場合は監視を停止し、UI に警告バナーを表示。
