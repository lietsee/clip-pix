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

## 6. MasonryGridView 実装状況 ✅
- **実装完了**: `flutter_staggered_grid_view` から `PinterestSliverGrid` カスタム実装に移行完了
- **パフォーマンス**: ウィンドウリサイズ時のFPS安定（60ms スロットリング適用）
- **レイアウト安定性**: Front/Backバッファアーキテクチャによるちらつき防止
- **セマンティクス問題解決**: ExcludeSemanticsとオーバーレイ方式でアサーション解決
- **詳細**: `docs/system/pinterest_grid_migration.md`, `docs/system/grid_layout_surface.md` 参照

## 7. URL画像保存 ✅ 実装完了
- **実装状況**: `UrlDownloadService` として実装完了（2025-10-25）
- **使用パッケージ**: `http` パッケージ
- **サポート形式**: JPEG (`image/jpeg` → `.jpg`), PNG (`image/png` → `.png`)
- **タイムアウト**: 10秒（カスタマイズ可能）
- **フロー**: クリップボードURL → HTTP GET → Content-Type検証 → ImageSaverで保存
- **ファイル名**: `clipboard_{timestamp}.{ext}`（タイムスタンプでユニーク性保証）
- **エラーハンドリング**: ステータスコード、Content-Type、タイムアウト、ネットワークエラーすべて考慮
- **詳細**: `docs/system/url_download_service.md` 参照

## 8. 新機能
- **ウィンドウ位置永続化** ✅: `WindowBoundsService` による位置・サイズの自動保存/復元（`docs/system/window_bounds_service.md`）
- **クリップボード監視ON/OFF** ✅: AppBarにトグルスイッチ追加（commit: 26b3a38）
- **グリッド設定UI** ✅: カラム数、背景色、一括リサイズ、Undo/Redo（`docs/ui/grid_settings_dialog.md`）
- **GridLayoutStore** ✅: 中央集約型レイアウト管理、Front/Backバッファ、差分検出（`docs/system/grid_layout_surface.md`）
