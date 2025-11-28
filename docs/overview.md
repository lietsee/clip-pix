# ClipPix 全体仕様書

**最終更新**: 2025-11-27

## 1. 概要

Windows 向け Flutter デスクトップアプリ（macOS対応計画中）。
クリップボード経由で画像・テキストを自動保存し、出典情報をJSONに記録する。
フォルダ内コンテンツは動的グリッドで表示・リサイズ・ズーム・パン可能。

### 主要機能
- クリップボード監視による画像/URL/テキスト自動保存
- Pinterest スタイルのマソンリーグリッド表示
- カードのリサイズ、ズーム、パン操作
- 一括削除モード
- プレビューウィンドウ（画像/テキスト）
- サブフォルダタブ切り替え

## 2. 構成図

```
┌─────────────────────────────────────────────────────────────────┐
│                           UI 層                                 │
│  MainScreen / GridViewModule / ImageCard / TextCard            │
│  ImagePreviewWindow / TextPreviewWindow / GridSettingsDialog   │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────┐
│                       状態管理層                                │
│  Provider + StateNotifier                                       │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ AppStateProvider:                                          │ │
│  │   SelectedFolderNotifier / WatcherStatusNotifier          │ │
│  │   ImageHistoryNotifier / DeletionModeNotifier             │ │
│  │   TextPreviewProcessManager / ImagePreviewProcessManager  │ │
│  └───────────────────────────────────────────────────────────┘ │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ GridLayoutStore / GridResizeController                    │ │
│  │ GridLayoutMutationController / ImageLibraryNotifier       │ │
│  └───────────────────────────────────────────────────────────┘ │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────┐
│                        データ層                                 │
│  ImageRepository / GridCardPreferencesRepository               │
│  GridLayoutSettingsRepository / GridOrderRepository            │
│  TextPreviewStateRepository / ImagePreviewStateRepository      │
│  OpenPreviewsRepository / FileInfoManager / MetadataWriter     │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────┐
│                       システム層                                │
│  ClipboardMonitor(win32) / ClipboardCopyService               │
│  FileWatcher / ImageSaver / TextSaver                          │
│  UrlDownloadService / AudioService / DeleteService            │
│  WindowBoundsService / AppLifecycleService                     │
└─────────────────────────────────────────────────────────────────┘
```

## 3. データフロー

```
クリップボード監視:
  Clipboard → ClipboardMonitor → ImageSaver/TextSaver → FileWatcher → ImageLibraryNotifier → GridView再描画

UIからの操作:
  UI操作 → Provider(StateNotifier) → Hive永続化

クリップボードコピー:
  UI操作(Ctrl+C) → ClipboardCopyService → (ガード付クリップボード)

URL画像ダウンロード:
  URL検出 → UrlDownloadService → HTTP GET → ImageSaver → FileWatcher → 再描画
```

## 4. 依存モジュール一覧

| モジュール | 主要ライブラリ | 概要 |
|-------------|----------------|------|
| UI | Flutter, Flutter Hooks | 表示系 |
| State | provider, state_notifier | 状態管理 |
| System | win32, watcher | OS/クリップボード操作 |
| Data | Hive | 永続化 |
| Window | window_manager | ウィンドウ管理 |
| Audio | audioplayers | 効果音再生 |

## 5. 共通仕様

- **保存ディレクトリ**: ユーザー指定
- **保存形式**: 画像（JPEG/PNG）、テキスト（.txt）
- **メタデータ**: 統合JSON形式 `.fileInfo.json`
- **ログ出力**: `./logs/app.log`
- **設定保存**: `%APPDATA%/Clip-pix/` (Hive)

## 6. コンテンツタイプ

| タイプ | 拡張子 | クリップボード形式 | 説明 |
|--------|--------|-------------------|------|
| IMAGE | .jpg, .jpeg, .png | CF_DIBV5, CF_DIB, PNG | 画像ファイル |
| TEXT | .txt | CF_UNICODETEXT | テキストファイル（非URL） |
| URL | - | CF_UNICODETEXT | URL経由での画像ダウンロード |

## 7. 機能実装状況

### 7.1 PinterestSliverGrid ✅ 完了
- `flutter_staggered_grid_view` から `PinterestSliverGrid` カスタム実装に移行完了
- Front/Backバッファアーキテクチャによるちらつき防止
- 60ms スロットリングによるパフォーマンス最適化
- **詳細**: `docs/system/grid_layout_surface.md`

### 7.2 URL画像保存 ✅ 完了
- `UrlDownloadService` 実装済み
- JPEG/PNG対応、10秒タイムアウト
- **詳細**: `docs/system/url_download_service.md`

### 7.3 テキストカード ✅ 完了 (2025-10-29)
- クリップボードからのテキスト自動保存
- `TextSaver` サービス
- `TextPreviewWindow` でプレビュー表示
- **詳細**: `docs/system/text_saver.md`

### 7.4 削除モード ✅ 完了
- `DeletionModeNotifier` による一括削除管理
- カード選択→一括削除のワークフロー
- `DeleteService` によるファイル削除

### 7.5 プレビューウィンドウ ✅ 完了
- 画像/テキストの別ウィンドウプレビュー
- ウィンドウ状態の永続化
- 別プロセス起動（`--preview`, `--preview-text` フラグ）
- **詳細**: `docs/ui/image_preview_window.md`

### 7.6 サブフォルダタブ ✅ 完了
- `FolderViewMode.root` / `FolderViewMode.subfolder`
- タブクリックでディレクトリ切り替え
- スクロール位置の記憶

### 7.7 グリッド設定 ✅ 完了
- カラム数、背景色、一括リサイズ
- Undo/Redo（3レベル）
- **詳細**: `docs/ui/grid_settings_dialog.md`

### 7.8 ウィンドウ位置永続化 ✅ 完了
- `WindowBoundsService` による位置・サイズの自動保存/復元
- **詳細**: `docs/system/window_bounds_service.md`

### 7.9 パンオフセット永続化 ✅ 完了 (2025-11-25)
- カードごとのズーム位置（パンオフセット）を永続化
- **詳細**: `docs/system/state_management.md#section-10.7`

### 7.10 macOS対応 📝 計画中
- クロスプラットフォーム抽象化レイヤー設計済み
- **詳細**: `docs/system/macos_cross_platform_migration.md`

## 8. 最近の重要な修正

### 2025-11-25
- **パンオフセット永続化バグ修正** (commit f716f23)
  - `updateGeometry()` でパンオフセットが失われる問題を解決

### 2025-11-02
- **ミニマップ更新バグ修正** (commit 8225c71)
  - 個別カードリサイズ時にミニマップが更新されない問題を解決
  - `GridLayoutStore.updateCard()` でスナップショット再生成パターンを確立

- **グリッド並び替えバグ修正** (commit 9925ac1)
  - お気に入りクリック時にグリッド全体が並び替わる問題を解決
  - Write-through cacheパターン適用

- **テキストコピー時のアサーション失敗修正** (commit 62608ac)
  - `GridViewModule` の reconcile 判定に `itemCountChanged` チェックを追加

## 9. アクセシビリティ

イラストレーター向けデスクトップアプリのため、アクセシビリティ機能（セマンティクス/スクリーンリーダー対応）は2025-11-28に完全削除:
- コードベースの簡素化
- レンダリングパフォーマンスの向上
- **履歴**: `docs/archive/grid_semantics_rebuild_plan.md`

## 10. ドキュメント構成

```
docs/
├── overview.md                 # 本ドキュメント
├── architecture/
│   ├── data_flow.md           # データフロー詳細
│   ├── state_management_flow.md # 状態管理アーキテクチャ
│   └── grid_rendering_pipeline.md # グリッドレンダリング
├── system/
│   ├── clipboard_monitor.md   # クリップボード監視
│   ├── clipboard_copy_service.md # クリップボードコピー
│   ├── image_saver.md         # 画像保存
│   ├── text_saver.md          # テキスト保存
│   ├── file_watcher.md        # ファイル監視
│   ├── url_download_service.md # URLダウンロード
│   ├── window_bounds_service.md # ウィンドウ位置
│   ├── state_management.md    # 状態管理詳細
│   ├── grid_layout_surface.md # グリッドレイアウト
│   ├── grid_layout_layout_engine.md # レイアウトエンジン
│   ├── grid_layout_mutation_controller.md # ミューテーション
│   ├── grid_layout_store_migration.md # ストア移行（履歴+現状）
│   └── macos_cross_platform_migration.md # macOS対応計画
├── ui/
│   ├── main_screen.md         # メイン画面
│   ├── grid_view.md           # グリッドビュー
│   ├── image_card.md          # 画像カード
│   ├── image_preview_window.md # プレビューウィンドウ
│   └── grid_settings_dialog.md # 設定ダイアログ
├── data/
│   ├── models.md              # データモデル
│   ├── repositories.md        # リポジトリ
│   └── json_schema.md         # JSONスキーマ
└── archive/                   # 完了/廃止ドキュメント
    ├── known_issue_grid_semantics.md
    ├── pinterest_grid_migration.md
    ├── grid_semantics_rebuild_plan.md
    └── grid_semantics_double_buffer_plan.md
```

## 11. 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | 全面改訂: TEXT機能、削除モード、プレビュー永続化、macOS計画追加 |
| 2025-11-02 | ミニマップ更新、グリッド並び替え、テキストコピーバグ修正 |
| 2025-10-28 | URL画像保存、ウィンドウ位置永続化、グリッド設定UI追加 |
| 2025-10-20 | 初版作成 |
