# JSON出典情報スキーマ

## 概要
画像ごとに生成される `image_XXXX.json` の仕様。

```json
{
  "file": "image_20251020_123456.jpg",
  "saved_at": "2025-10-20T12:34:56+09:00",
  "source": "https://example.com/image.jpg",
  "source_type": "web"
}

## フィールド定義
| 項目          | 型                         | 必須 | 説明             |
| ----------- | ------------------------- | -- | -------------- |
| file        | string                    | ✔  | ファイル名          |
| saved_at    | string                    | ✔  | 保存日時           |
| source      | string                    | ✔  | 出典元            |
| source_type | enum(web, local, unknown) | ✔  | 出典区分           |
