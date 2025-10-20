# ClipboardMonitor 詳細設計

## 1. 概要
クリップボードの画像／URLを監視し、自動的に保存処理をトリガー。

## 2. 責務
- Win32 hook またはフォールバックポーリングでクリップボード更新を検知。
- 新しい画像・URLがあれば ImageSaver へ送信。
- Provider の選択フォルダ状態を購読し、未選択時は監視を停止。
- 取得データを JSON メタデータ生成用に正規化して渡す。

## 3. 入出力
| 種別 | 名称 | 型 | 説明 |
|------|------|----|------|
| 出力 | onImageCaptured | `Function(Uint8List imageData)` | 新規画像検出イベント |
| 出力 | onUrlCaptured | `Function(String url)` | URLコピー検出イベント |
| 入力 | getSelectedFolder | `Directory? Function()` | 監視状態判定のためのフォルダ取得 |

## 4. 使用ライブラリ
- `win32`

## 5. エラーハンドリング
- Clipboard読み取り失敗時は `./logs/app.log` に警告を記録し、2秒後に再試行。
- 連続5回失敗した場合は監視を停止し、Provider に例外状態を通知。

## 6. 実装方針
- 監視用 isolate を専用に起動し、`SetWinEventHook(EVENT_SYSTEM_CLIPBOARD)` + `WINEVENT_SKIPOWNPROCESS` で通知を取得。Hook 登録に失敗した場合のみ 500ms ポーリングにフォールバックする。
- フォールバックは Win32 API で `AddClipboardFormatListener` が利用できない環境（hook 失敗、アクセス拒否など）で有効化し、hook 再試行は 30 秒間隔で実施。
- データ種別は `RegisterClipboardFormat('PNG')` で確保した PNG を優先し、取得できなかった場合は `CF_DIB` を解析して RGBA → PNG へ変換したデータを ImageSaver に渡す（CF_UNICODETEXT のみ正規化して URL 判定）。
- URL 検出時は `UrlDownloadService` を通じてバイト列と拡張子を取得し、ImageSaver へフォワードする。
- テキストは `CF_UNICODETEXT` を参照し、画像と同時に取得できた場合は画像保存を優先し、URL はメタデータの `source` へ割り当てる。
- URL の正規化では `Uri.tryParse` を使用し、HTTP/HTTPS のみ許容。判定不可の文字列は破棄してログに残す。
- 同一コンテンツを短時間に複数回検出した場合はハッシュ(Digest)で重複判定し、直近の保存から 2 秒以内は無視。
- アプリ内で `ClipboardCopyService` が設定したガードトークン (`avoidSelfTriggerToken`) を確認し、一致する更新は保存処理をスキップ。

## 7. 監視制御
- フォルダが選択されていない、または `image_saver` がビジー状態の間は監視を一時停止する。
- Provider から `onFolderChanged(null)` を受け取った場合はクリップボードフックを解除し、再選択時に再登録。
- URL ダウンロードや ImageSaver が進行中でも監視は継続し、更新イベントは FIFO キューに蓄積（上限 10 件）。溢れた場合は最古を破棄しログ `queue_drop` を記録。
- ImageSaver からの完了イベント（`SaveResult.completed|failed`）を受け取った時点でキュー処理を再開し、結果に応じて次イベントへ進む。
- 自己コピーガード発動中 (`avoidSelfTriggerToken` 有効) のイベントはキューへ積まず、トークン解除後も処理しない。

## 8. ログ
- 画像保存トリガー時には `info` レベルでソース種別（bitmap/url）とファイル名を記録。
- ハッシュ重複でスキップした場合は `debug` レベルでスキップ理由を記録。
- 監視方式変更（hook→poll）が発生した際は `warn` レベルで理由を記録し、hook 復帰時にもログを残す。
- 例外発生時は `error` レベルでスタックトレースを記録し、ユーザーには SnackBar で通知。

## 9. リカバリ戦略
- hook 失敗・アクセス拒否などでフォールバックが連続 5 回発生した場合は 1 分間監視を停止し、再度 hook を試行。
- UI から「再試行」コマンドを受け取った場合は即座に hook 再登録を行う。
- フォルダ再選択時にはキューをクリアし、`ImageSaver` 完了通知から再開する。
