# PdfCard 実装仕様

**最終更新**: 2025-12-06

本書は `lib/ui/widgets/pdf_card.dart` に実装されているPDFカードコンポーネントの仕様を整理したものです。

## 1. 概要

PdfCard は `PdfContentItem`（`.pdf` ファイル）を表示するためのカードコンポーネント。ImageCard と同様のグリッド表示・リサイズ・リオーダー機能を持つ。

## 2. ImageCard との違い

| 操作 | ImageCard | PdfCard |
|------|-----------|---------|
| サムネイル | 画像ファイル直接表示 | PDFの1ページ目をレンダリング |
| ページ数表示 | なし | 複数ページ時にバッジ表示 |
| コンテンツコピー | 画像をクリップボードへ | なし |
| メモ編集 | あり | なし |

## 3. 表示要素

```
┌────────────────────────────────┐
│[⤢]                    [📄2] [⤡]│ ← 左上/右上リサイズハンドル、ページ数バッジ
├────────────────────────────────┤
│                                │
│   PDFサムネイル表示             │
│   （1ページ目のレンダリング）    │
│                                │
├────────────────────────────────┤
│[⤡] [♥]        [drag]     [⤢]│ ← 左下/右下リサイズハンドル、お気に入り、ドラッグ
└────────────────────────────────┘
```

## 4. サムネイル生成

### 4.1 PdfThumbnailCacheService

PDFサムネイルはキャッシュサービスで管理：

```dart
class PdfThumbnailCacheService {
  // メモリキャッシュ（LRU、最大100件）
  final Map<String, Uint8List> _cache;

  // サムネイル取得（キャッシュ優先）
  Future<Uint8List?> getThumbnail(String filePath);
}
```

### 4.2 レンダリング

- `pdfx` パッケージを使用
- 1ページ目を300dpiでレンダリング
- PNG形式でキャッシュ

### 4.3 フォールバック

サムネイル取得失敗時は灰色背景にPDFアイコンを表示。

## 5. ユーザーインタラクション

### 5.1 プレビュー

- ダブルクリックで `PdfPreviewWindow` を別プロセスで起動
- 削除モード中はダブルクリック無効

### 5.2 リサイズ

- **4つのコーナー**（topLeft, topRight, bottomLeft, bottomRight）からリサイズ可能
- 列幅にスナップ
- ImageCard と同一のロジック

### 5.3 お気に入り

- 左下のハートアイコンで切り替え
- `favorite` 値: 0（なし）, 1（緑）, 2（オレンジ）, 3（ピンク）

### 5.4 削除

- ホバー時に右上に削除ボタン表示
- 複数ページ時はページ数バッジの下に配置

## 6. コールバック

| 名称 | 型 | 説明 |
|------|-----|------|
| `onResize` | `Function(String id, Size, {ResizeCorner? corner})` | サイズ変更通知 |
| `onSpanChange` | `Function(String id, int)?` | 列スパン変更通知 |
| `onFavoriteToggle` | `Function(String id, int)` | お気に入り状態変更 |
| `onOpenPreview` | `Future<void> Function(PdfContentItem)` | プレビュー起動要求 |
| `onDelete` | `Function(PdfContentItem)?` | 削除要求 |
| `onReorder*` | 各種 | ドラッグ&ドロップ順序変更 |

## 7. 関連コンポーネント

- **PdfPreviewWindow** (`lib/ui/widgets/pdf_preview_window.dart`): 別ウィンドウプレビュー
- **PdfPreviewProcessManager** (`lib/system/pdf_preview_process_manager.dart`): プレビュープロセス管理
- **PdfThumbnailCacheService** (`lib/system/pdf_thumbnail_cache_service.dart`): サムネイルキャッシュ
- **PdfContentItem** (`lib/data/models/pdf_content_item.dart`): データモデル

## 8. プレビューウィンドウ

### 8.1 起動フロー

```
PdfCard.onOpenPreview
  → PdfPreviewProcessManager.launchPreview(pdfItem)
  → Process.start(executable, ['--preview-pdf', jsonPayload, '--parent-pid', parentPid])
  → PdfPreviewWindow (別プロセス)
```

### 8.2 プレビュー機能

- ページ送り（前へ/次へボタン、キーボード矢印キー）
- 最前面表示トグル
- ページ番号表示

## 9. 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-12-06 | 初版作成。PDF表示機能実装。 |
