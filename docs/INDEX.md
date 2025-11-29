# ClipPix ドキュメント一覧

**最終更新**: 2025-11-29

ClipPixプロジェクトの全ドキュメントとその概要です。

---

## 概要ドキュメント

| ファイル | 概要 |
|---------|------|
| [overview.md](./overview.md) | プロジェクト全体の概要、機能一覧、技術スタック、開発ステータス |
| [DOCUMENTATION_UPDATE_2025-10-28.md](./DOCUMENTATION_UPDATE_2025-10-28.md) | ドキュメント更新履歴と変更ログ |

---

## データレイヤー (`docs/data/`)

| ファイル | 概要 |
|---------|------|
| [models.md](./data/models.md) | データモデル定義（ContentItem, ImageItem, TextContentItem, GridCardPreference, GridLayoutSettings等） |
| [json_schema.md](./data/json_schema.md) | `.fileInfo.json` 統合メタデータファイルのJSONスキーマ仕様 |
| [repositories.md](./data/repositories.md) | Hiveベースのリポジトリクラス群（GridLayoutSettingsRepository, GridCardPreferencesRepository, GridOrderRepository, ImageRepository, OpenPreviewsRepository等） |

---

## システムレイヤー (`docs/system/`)

### クリップボード・ファイル監視

| ファイル | 概要 |
|---------|------|
| [clipboard_monitor.md](./system/clipboard_monitor.md) | Win32 APIを使用したクリップボード監視、画像/URL/テキスト検出、ガードトークン機構 |
| [clipboard_copy_service.md](./system/clipboard_copy_service.md) | 画像・テキストのクリップボードコピー、ガードトークン管理、Win32 API統合 |
| [file_watcher.md](./system/file_watcher.md) | ファイルシステム監視（画像・テキストの追加/削除/変更検出）、WatcherStatusNotifier連携 |

### 保存サービス

| ファイル | 概要 |
|---------|------|
| [image_saver.md](./system/image_saver.md) | クリップボード画像の保存、ファイル名生成、メタデータ書き込み |
| [text_saver.md](./system/text_saver.md) | クリップボードテキストの.txt保存、重複検出、メタデータ書き込み |
| [url_download_service.md](./system/url_download_service.md) | URLからの画像ダウンロード、JPEG/PNG対応、Content-Type検証 |

### 状態管理

| ファイル | 概要 |
|---------|------|
| [state_management.md](./system/state_management.md) | Provider + StateNotifierパターン、各Notifierの責務（SelectedFolderNotifier, WatcherStatusNotifier, ImageHistoryNotifier, ImageLibraryNotifier, DeletionModeNotifier）、GridLayoutStore |

### グリッドレイアウト

| ファイル | 概要 |
|---------|------|
| [grid_layout_layout_engine.md](./system/grid_layout_layout_engine.md) | Pinterestスタイルレイアウト計算エンジン、マサリーアルゴリズム、スナップショット生成 |
| [grid_layout_surface.md](./system/grid_layout_surface.md) | Front/Stagingダブルバッファアーキテクチャ、ジオメトリ更新スロットリング |
| [grid_layout_mutation_controller.md](./system/grid_layout_mutation_controller.md) | グリッドミューテーションライフサイクル管理、ネスト対応、不整合検出 |
| [grid_layout_store_migration.md](./system/grid_layout_store_migration.md) | GridLayoutStoreへの移行計画、バッチ適用方式、永続化同期パターン |

### その他

| ファイル | 概要 |
|---------|------|
| [window_bounds_service.md](./system/window_bounds_service.md) | ウィンドウ位置・サイズの永続化、Win32 API統合、200msデバウンス |
| [macos_cross_platform_migration.md](./system/macos_cross_platform_migration.md) | macOSクロスプラットフォーム対応の移行計画 |

---

## UIレイヤー (`docs/ui/`)

| ファイル | 概要 |
|---------|------|
| [main_screen.md](./ui/main_screen.md) | メイン画面、フォルダ選択、タブ表示、AppBar、一括削除モード、プレビューウィンドウ管理 |
| [grid_view.md](./ui/grid_view.md) | Pinterestスタイルグリッド表示、カードリサイズ、ズーム、ドラッグ&ドロップ、Entry Reconciliation |
| [image_card.md](./ui/image_card.md) | 画像カードコンポーネント、リサイズ・ズーム・パン操作、コピー・プレビュー、リオーダー |
| [image_preview_window.md](./ui/image_preview_window.md) | 画像プレビューウィンドウ、最前面表示、プロセス管理、TextPreviewWindowとの関係 |
| [grid_settings_dialog.md](./ui/grid_settings_dialog.md) | グリッド設定ダイアログ、列数設定、背景色、一括サイズ調整、Undo/Redo |

---

## アーキテクチャ (`docs/architecture/`)

| ファイル | 概要 |
|---------|------|
| [data_flow.md](./architecture/data_flow.md) | データフロー図（クリップボード保存、URLダウンロード、テキスト保存、フォルダ選択、カードリサイズ、削除、プレビュー） |
| [state_management_flow.md](./architecture/state_management_flow.md) | 状態管理フロー、Providerツリー、各Notifier/Storeの責務と連携 |
| [grid_rendering_pipeline.md](./architecture/grid_rendering_pipeline.md) | グリッドレンダリングパイプライン（7ステージ）、パフォーマンス最適化 |

---

## アーカイブ (`docs/archive/`)

過去の調査・計画ドキュメント（実装完了または廃止）

| ファイル | 概要 |
|---------|------|
| known_issue_grid_semantics.md | グリッドレイアウト問題の既知の課題（解決済み・セマンティクス機能は2025-11-28に削除） |
| known_issue_tab_switch_interaction.md | ディレクトリタブ切り替え後の操作不能バグ（解決済み 2025-11-29） |
| grid_semantics_double_buffer_plan.md | ダブルバッファ導入計画（実装完了） |
| grid_semantics_rebuild_plan.md | レイアウト再構築計画（履歴・セマンティクス機能は削除済み） |
| pinterest_grid_migration.md | PinterestSliverGrid移行計画（実装完了） |
| semantics_investigation_2025-10-26.md | レイアウト調査記録（履歴） |

---

## ドキュメント構成図

```
docs/
├── INDEX.md                              ← 本ファイル（ドキュメント一覧）
├── overview.md                           ← プロジェクト概要
├── DOCUMENTATION_UPDATE_2025-10-28.md    ← 更新履歴
│
├── data/                                 ← データレイヤー
│   ├── models.md
│   ├── json_schema.md
│   └── repositories.md
│
├── system/                               ← システムレイヤー
│   ├── clipboard_monitor.md
│   ├── clipboard_copy_service.md
│   ├── file_watcher.md
│   ├── image_saver.md
│   ├── text_saver.md
│   ├── url_download_service.md
│   ├── state_management.md
│   ├── grid_layout_layout_engine.md
│   ├── grid_layout_surface.md
│   ├── grid_layout_mutation_controller.md
│   ├── grid_layout_store_migration.md
│   ├── window_bounds_service.md
│   └── macos_cross_platform_migration.md
│
├── ui/                                   ← UIレイヤー
│   ├── main_screen.md
│   ├── grid_view.md
│   ├── image_card.md
│   ├── image_preview_window.md
│   └── grid_settings_dialog.md
│
├── architecture/                         ← アーキテクチャ
│   ├── data_flow.md
│   ├── state_management_flow.md
│   └── grid_rendering_pipeline.md
│
└── archive/                              ← アーカイブ（過去の計画・調査）
    ├── known_issue_grid_semantics.md
    ├── grid_semantics_double_buffer_plan.md
    ├── grid_semantics_rebuild_plan.md
    ├── pinterest_grid_migration.md
    └── semantics_investigation_2025-10-26.md
```

---

## クイックリファレンス

### 機能別ドキュメント

| 機能 | 関連ドキュメント |
|------|-----------------|
| クリップボード監視 | clipboard_monitor.md, clipboard_copy_service.md |
| 画像保存 | image_saver.md, file_watcher.md |
| テキスト保存 | text_saver.md, file_watcher.md |
| URL画像ダウンロード | url_download_service.md, clipboard_monitor.md |
| グリッド表示 | grid_view.md, image_card.md, grid_rendering_pipeline.md |
| ミニマップ | main_screen.md (セクション14), grid_minimap_overlay.dart |
| グリッドレイアウト計算 | grid_layout_layout_engine.md, grid_layout_surface.md |
| 設定管理 | grid_settings_dialog.md, state_management.md, repositories.md |
| プレビューウィンドウ | image_preview_window.md, main_screen.md |
| 一括削除 | main_screen.md, state_management.md |
| ウィンドウ位置保存 | window_bounds_service.md |

### 実装ファイルとドキュメントの対応

| 実装ファイル | ドキュメント |
|-------------|-------------|
| `lib/system/clipboard_monitor.dart` | clipboard_monitor.md |
| `lib/system/clipboard_copy_service.dart` | clipboard_copy_service.md |
| `lib/system/file_watcher.dart` | file_watcher.md |
| `lib/system/image_saver.dart` | image_saver.md |
| `lib/system/text_saver.dart` | text_saver.md |
| `lib/system/url_download_service.dart` | url_download_service.md |
| `lib/system/state/grid_layout_store.dart` | state_management.md, grid_layout_store_migration.md |
| `lib/system/grid_layout_layout_engine.dart` | grid_layout_layout_engine.md |
| `lib/ui/main_screen.dart` | main_screen.md |
| `lib/ui/grid_view_module.dart` | grid_view.md |
| `lib/ui/image_card.dart` | image_card.md |
| `lib/ui/image_preview_window.dart` | image_preview_window.md |
| `lib/ui/widgets/grid_layout_surface.dart` | grid_layout_surface.md |
| `lib/ui/widgets/grid_settings_dialog.dart` | grid_settings_dialog.md |
| `lib/ui/widgets/grid_minimap_overlay.dart` | main_screen.md (セクション14) |
| `lib/data/grid_card_preferences_repository.dart` | repositories.md |
