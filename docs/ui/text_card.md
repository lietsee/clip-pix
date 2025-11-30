# TextCard 実装仕様

**最終更新**: 2025-11-30
**対象コミット**: `2faa96e`（refactor: change edit flow to use hover button instead of single-click）

本書は `lib/ui/widgets/text_card.dart` に実装されているテキストカードコンポーネントの仕様を整理したものです。

## 1. 概要

TextCard は `TextContentItem`（`.txt` ファイル）を表示するためのカードコンポーネント。ImageCard と同様のグリッド表示・リサイズ・リオーダー機能を持ちながら、テキスト特有のインライン編集機能を提供する。

## 2. ImageCard との違い

| 操作 | ImageCard | TextCard |
|------|-----------|----------|
| シングルクリック | フォーカス | 無効（`onTap: null`） |
| ダブルクリック | プレビューウィンドウ起動 | プレビューウィンドウ起動 |
| ホバーボタン（左上） | コピーアイコン | **編集アイコン** → インライン編集 |
| メモ編集 | あり（MemoEditDialog） | **削除済み** |
| コンテンツコピー | 画像をクリップボードへ | テキストをクリップボードへ |

## 3. 表示要素

```
┌────────────────────────────────┐
│ [編集]                   [削除] │ ← ホバー時のみ表示
├────────────────────────────────┤
│                                │
│   テキストコンテンツ表示         │
│   （スクロール可能）             │
│                                │
├────────────────────────────────┤
│ [♥]                      [⤡]  │ ← お気に入り / リサイズハンドル
└────────────────────────────────┘
```

## 4. ユーザーインタラクション

### 4.1 編集フロー（2025-11-30 変更）

**変更前**: シングルクリックで即座にインライン編集モード起動
**変更後**: ホバー時に表示される編集ボタン（左上）をクリックして編集開始

```
ホバー → 編集ボタン表示 → クリック → TextInlineEditor 起動
```

この変更により、意図しない編集モード起動を防止。

### 4.2 プレビュー

- ダブルクリックで `TextPreviewWindow` を別プロセスで起動
- 編集中・削除モード中はダブルクリック無効

### 4.3 リサイズ

- 右下ハンドルをドラッグ
- 列幅にスナップ
- ImageCard と同一のロジック

### 4.4 お気に入り

- 左下のハートアイコンで切り替え
- `favorite` 値: 0（なし）, 1（赤）, 2（青）, 3（緑）

## 5. コールバック

| 名称 | 型 | 説明 |
|------|-----|------|
| `onResize` | `Function(String id, Size)` | サイズ変更通知 |
| `onSpanChange` | `Function(String id, int)?` | 列スパン変更通知 |
| `onFavoriteToggle` | `Function(String id, int)` | お気に入り状態変更 |
| `onCopyText` | `Function(TextContentItem)` | テキストコピー要求 |
| `onOpenPreview` | `Future<void> Function(TextContentItem)` | プレビュー起動要求 |
| `onSaveText` | `Function(String id, String text)` | テキスト保存要求 |
| `onDelete` | `Function(TextContentItem)?` | 削除要求 |
| `onReorder*` | 各種 | ドラッグ&ドロップ順序変更 |

## 6. 関連コンポーネント

- **TextInlineEditor** (`lib/ui/widgets/text_inline_editor.dart`): インライン編集UI
- **TextPreviewWindow** (`lib/ui/widgets/text_preview_window.dart`): 別ウィンドウプレビュー
- **TextPreviewProcessManager** (`lib/system/text_preview_process_manager.dart`): プレビュープロセス管理

## 7. 変更履歴

| 日付 | コミット | 内容 |
|------|----------|------|
| 2025-11-30 | `2faa96e` | シングルクリック編集を廃止、ホバーボタン編集に変更。メモ編集機能を削除。 |
