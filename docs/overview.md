# ClipPix 全体仕様書

## 1. 概要
Windows 向け Flutter デスクトップアプリ。  
クリップボード経由で画像を自動保存し、出典情報をJSONに記録する。  
フォルダ内画像は動的グリッドで表示・リサイズ・ズーム可能。

## 2. 構成図
UI層 ─ MainScreen / GridView / ImageCard / ImagePreviewWindow
状態管理層 ─ Provider(StateNotifier) / ViewModel
データ層 ─ ImageRepository / HiveAdapter
システム層 ─ ClipboardMonitor(win32) / FileWatcher / ImageSaver / ClipboardCopyService


## 3. データフロー
Clipboard → ImageSaver → JSON → FileWatcher → GridView再描画  
UI操作 → Provider(StateNotifier) → Hive永続化  
UI操作(Ctrl+C) → ClipboardCopyService → (ガード付クリップボード)

## 4. 依存モジュール一覧
| モジュール | 主要ライブラリ | 概要 |
|-------------|----------------|------|
| UI          | Flutter, Flutter Hooks | 表示系 |
| State       | provider | 状態管理 |
| System      | win32, watcher | OS／クリップボード操作 |
| Data        | Hive | 永続化 |

## 5. 共通仕様
- 画像保存ディレクトリ：ユーザー指定
- 保存形式：JPEG / PNG
- 出典情報：画像と同階層に `image_xxxx.json`
- ログ出力：アプリケーションディレクトリ配下 `./logs/app.log`

## 6. MasonryGridView 検証方針
- `flutter_staggered_grid_view` を採用し、Windows デスクトップ(Releaseモード)で FPS とメモリ利用を確認する。
- チェックリスト: ①カードリサイズ時のレイアウト安定性、②ホイールズームのヒットテスト、③1,000枚画像読み込み時のスクロールスムーズさ。
- 計測手順: `flutter run -d windows --profile` 実行 → DevTools の Performance タブでタイムライン、`Frame build` の平均を 16ms 以下に。
- ドラッグリサイズ検証: `WidgetTester` での自動化が難しいため、`integration_test/resize_flow_test.dart` を用意し、`flutter drive` で手動確認ログを残す。
- 問題発生時は `GridView.custom` への切替を比較ベースラインとして記録する。

## 7. URL画像保存方針（たたき台）
- 使用パッケージ: `http`（リトライは将来的に `retry` 導入を検討）。
- フロー: ①クリップボード文字列から URL 抽出 → ② GET でバイナリ取得 → ③ `content-type` と拡張子を突合 → ④ 保存ファイル名は `image_{timestamp}.{ext}`。
- タイムアウト: デフォルト 10 秒。失敗時はログに `download_timeout` と URL を記録し保存処理を中断。
- 同名ファイル回避: 生成名が既存と衝突した場合は `_1` `_2` を付与してリトライ。
- セキュリティ: HTTP→HTTPS 自動昇格は行わず、HTTP の場合はユーザーに警告ダイアログで確認を求める案を検討。
- ダウンロードは UI スレッドをブロックしないよう `compute` または isolate を検討し、完了後に JSON メタデータを作成して保存する。
