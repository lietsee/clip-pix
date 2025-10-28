# UrlDownloadService

**実装ファイル**: `lib/system/url_download_service.dart`
**作成日**: 2025-10-28
**ステータス**: 実装完了

## 概要

`UrlDownloadService` は、クリップボードからキャプチャされたURLから画像をダウンロードし、ローカルに保存するためのHTTPクライアントサービスです。JPEG/PNG画像のみサポートします。

## 主要機能

### サポート形式

- **JPEG**: `Content-Type: image/jpeg` → `.jpg`
- **PNG**: `Content-Type: image/png` → `.png`

### タイムアウト

- デフォルト: 10秒
- カスタマイズ可能（コンストラクタパラメータ）

### エラーハンドリング

- HTTPステータスコード != 200 → null
- サポート外のContent-Type → null
- タイムアウト → null
- ネットワークエラー → null（ログ出力）

## API

### ダウンロード

```dart
Future<UrlDownloadResult?> downloadImage(String url) async
```

#### 戻り値: UrlDownloadResult

```dart
class UrlDownloadResult {
  final Uint8List bytes;        // 画像バイトデータ
  final String contentType;     // Content-Type（例: "image/jpeg"）
  final String extension;       // 拡張子（"jpg" or "png"）
}
```

#### 処理フロー

```dart
Future<UrlDownloadResult?> downloadImage(String url) async {
  try {
    // 1. HTTP GET リクエスト
    final uri = Uri.parse(url);
    final response = await _client.get(uri).timeout(_timeout);

    // 2. ステータスコードチェック
    if (response.statusCode != 200) return null;

    // 3. Content-Type検証
    final contentType = response.headers['content-type'];
    if (!_isSupportedContentType(contentType)) return null;

    // 4. 拡張子解決
    final extension = _extensionFromContentType(contentType);
    if (extension == null) return null;

    // 5. バイトデータ取得
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) return null;

    return UrlDownloadResult(
      bytes: bytes,
      contentType: contentType,
      extension: extension,
    );
  } on TimeoutException {
    _logger.warning('download_timeout url=$url');
    return null;
  } catch (error) {
    _logger.severe('download_error url=$url', error);
    return null;
  }
}
```

### Content-Type検証

```dart
bool _isSupportedContentType(String contentType) {
  return contentType.startsWith('image/jpeg') ||
         contentType.startsWith('image/png');
}
```

**検証ルール**: `startsWith` で部分一致（`image/jpeg; charset=utf-8` なども許可）

### 拡張子解決

```dart
String? _extensionFromContentType(String contentType) {
  if (contentType.startsWith('image/jpeg')) return 'jpg';
  if (contentType.startsWith('image/png')) return 'png';
  return null;
}
```

## ClipboardMonitorとの統合

### 使用例

```dart
// ClipboardMonitor.dart より
final urlService = UrlDownloadService();

Future<void> _processClipboardUrl(String url) async {
  final result = await urlService.downloadImage(url);
  if (result == null) {
    _logger.warning('Failed to download image from $url');
    return;
  }

  // ImageSaverに渡す
  final fileName = 'clipboard_${DateTime.now().millisecondsSinceEpoch}.${result.extension}';
  await _imageSaver.save(
    bytes: result.bytes,
    fileName: fileName,
    metadata: ImageMetadata(
      source: ImageSourceType.url,
      originalUrl: url,
    ),
  );
}
```

## ログ出力

### 警告ログ（warning）

- `download_failed status=404 url=https://example.com/image.jpg`
- `unsupported_content_type type=text/html url=https://example.com`
- `extension_resolution_failed type=image/webp url=https://example.com`
- `empty_response url=https://example.com`
- `download_timeout url=https://example.com`

### エラーログ（severe）

- `download_error url=https://example.com error=SocketException`

## パフォーマンス

### タイムアウト設定

```dart
final service = UrlDownloadService(timeout: Duration(seconds: 5));  // カスタム
```

**推奨**:
- モバイルネットワーク: 15秒
- 高速ネットワーク: 5秒
- デフォルト（10秒）は汎用的

### メモリ使用

- `bodyBytes`: 画像サイズ分のメモリ（Uint8List）
- 例: 2MB画像 → 2MBメモリ使用
- ガベージコレクション後に解放

## セキュリティ考慮事項

### HTTPS推奨

```dart
final uri = Uri.parse(url);
// HTTPも許可しているが、HTTPSを推奨
```

**今後の改善**: HTTPリクエストを警告またはブロック

### Content-Type検証

```dart
if (!_isSupportedContentType(contentType)) return null;
```

**防御**: HTMLやスクリプトファイルの誤ダウンロードを防止

### サイズ制限なし

**現状**: 無制限（巨大ファイルのダウンロード可能）
**今後の改善**: Content-Lengthチェックで最大サイズ制限（例: 50MB）

## エラーハンドリング詳細

### タイムアウト

```dart
.timeout(_timeout)
```

**動作**: 指定時間内に完了しない場合、`TimeoutException` をスロー

### ネットワークエラー

- `SocketException`: 接続失敗
- `HttpException`: HTTPエラー
- `FormatException`: URL不正

**処理**: すべて`null`を返し、ログ出力

## テストガイドライン

### ユニットテスト

1. **HTTPモック**: `http.Client`をモック
2. **成功ケース**: 200 + image/jpeg → UrlDownloadResult
3. **失敗ケース**: 404, unsupported type, timeout → null
4. **Content-Type variants**: `image/jpeg; charset=utf-8` なども許可

### テスト例

```dart
test('downloadImage returns result for valid JPEG', () async {
  final mockClient = MockClient((request) async {
    return http.Response(
      Uint8List.fromList([0xFF, 0xD8, 0xFF]),  // JPEG magic bytes
      200,
      headers: {'content-type': 'image/jpeg'},
    );
  });

  final service = UrlDownloadService(httpClient: mockClient);
  final result = await service.downloadImage('https://example.com/image.jpg');

  expect(result, isNotNull);
  expect(result!.extension, 'jpg');
  expect(result.bytes.length, 3);
});
```

## 今後の拡張

### 対応フォーマット追加

- WebP: `image/webp` → `.webp`
- GIF: `image/gif` → `.gif`（アニメーション対応）
- AVIF: `image/avif` → `.avif`

### サイズ制限

```dart
final contentLength = int.tryParse(response.headers['content-length'] ?? '');
if (contentLength != null && contentLength > maxSize) {
  _logger.warning('file_too_large size=$contentLength max=$maxSize');
  return null;
}
```

### リトライロジック

```dart
for (var attempt = 0; attempt < maxRetries; attempt++) {
  try {
    final response = await _client.get(uri).timeout(_timeout);
    // ...
  } on TimeoutException {
    if (attempt == maxRetries - 1) rethrow;
    await Future.delayed(retryDelay);
  }
}
```

### プログレス通知

```dart
Stream<DownloadProgress> downloadImageWithProgress(String url)
```

## 実装履歴

- **2025-10-25**: 初期実装
- **2025-10-26**: ClipboardMonitor統合
- **2025-10-28**: ドキュメント作成

## 関連ドキュメント

- [ClipboardMonitor](./clipboard_monitor.md) - URLキャプチャとダウンロードトリガー
- [ImageSaver](./image_saver.md) - ダウンロードした画像の保存
