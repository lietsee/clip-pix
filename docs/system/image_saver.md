# ImageSaver 詳細設計

## 1. 概要
ClipboardMonitorやUI操作から渡された画像データを指定フォルダに保存。  
出典情報は JSON メタデータとして同一フォルダに記録。

## 2. 責務
- バイナリ画像データをファイル化。
- JPEG／PNG形式を自動判別して保存。
- 出典情報(JSON)を生成。
- 保存前に選択フォルダの存在・書き込み権限を検証。
- URL ダウンロードキューと連携し、保存完了後に進捗を更新。

## 3. 入出力
| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 入力 | imageData | `Uint8List` | 保存対象画像データ |
| 入力 | source | `String` | 出典URLまたは"Unknown" |
| 出力 | savedFilePath | `String` | 保存先ファイルパス |
| 出力 | metadataPath | `String` | 生成した JSON メタデータパス |
| 出力 | result | `SaveResult` | 保存結果（成功/失敗）を ClipboardMonitor へ通知 |

## 4. 依存関係
- JsonWriter
- Provider(StateNotifier)
- Hive(StorageConfig)

## 5. エラーハンドリング
- 書き込み失敗時は再試行（3回まで）。
- JSON破損時は再生成。
- フォルダ未選択またはアクセス不可の場合は処理を中断し、ClipboardMonitor にリトライ指示を返す。
- ログは `./logs/app.log` に出力し、連続失敗時は UI に警告を要求。

## 6. 保存フロー
1. Provider から現在の保存先フォルダを取得し、存在確認。
2. ファイル名を `image_{timestamp}` ベースで生成し、重複時は `_1` `_2` とインクリメント。
3. 画像データのフォーマットを推定し、JPEG/PNG のみに対応。その他はエラーとしてログ。
4. `File.writeAsBytes` で保存し、完了後に JSON メタデータ `{ file, saved_at, source, source_type }` を書き出す。
5. メタデータは Pretty ではなく単一行 JSON とし、再生成時は上書き。
6. 保存成功時に Provider の履歴へファイル情報を Push し、UI 更新をトリガー。
7. 保存処理完了後に `SaveResult` を発火し、ClipboardMonitor のキュー処理を再開させる。

## 7. JSONメタデータ仕様
- `file`: 保存した画像ファイル名。
- `saved_at`: ISO8601 UTC。`DateTime.now().toUtc().toIso8601String()`。
- `source`: ClipboardMonitor から渡された URL もしくは `"Unknown"`。
- `source_type`: `web` (URL) / `local` (Clipboard画像) / `unknown`。
- 拡張フィールドは `extra` オブジェクトにネームスペース付きで追加を検討。

## 8. URL ダウンロード連携
- ClipboardMonitor から URL 保存要求を受けた場合は、先にダウンロードタスクが `imageData` を生成してから本処理が呼ばれる想定。
- ダウンロードエラー時は ImageSaver を呼ばず、ClipboardMonitor 側でログ出力。
- 保存後に `metadataPath` を ClipboardMonitor に返し、ダウンロードキューの完了通知として利用。

## 9. テスト方針
- 単体テストで JPEG/PNG 推定、ファイル名重複解決、JSON 出力内容を検証。
- フォルダ未選択時は例外でなく null 戻り値を返し、呼び出し側が再試行する挙動を確認。
- 500 件連続保存の負荷テストでファイルディスクリプタリークが無いことを確認。
- 保存成功・失敗双方で `SaveResult` が発火し、ClipboardMonitor 側がキューを消化できることを確認。
