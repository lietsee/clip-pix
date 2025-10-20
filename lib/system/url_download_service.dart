import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class UrlDownloadResult {
  UrlDownloadResult({
    required this.bytes,
    required this.contentType,
    required this.extension,
  });

  final Uint8List bytes;
  final String contentType;
  final String extension;
}

class UrlDownloadService {
  UrlDownloadService({
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 10),
    Logger? logger,
  })  : _client = httpClient ?? http.Client(),
        _timeout = timeout,
        _logger = logger ?? Logger('UrlDownloadService');

  final http.Client _client;
  final Duration _timeout;
  final Logger _logger;

  Future<UrlDownloadResult?> downloadImage(String url) async {
    try {
      final uri = Uri.parse(url);
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        _logger
            .warning('download_failed status=${response.statusCode} url=$url');
        return null;
      }
      final contentType = response.headers['content-type'];
      if (contentType == null || !_isSupportedContentType(contentType)) {
        _logger.warning('unsupported_content_type type=$contentType url=$url');
        return null;
      }
      final extension = _extensionFromContentType(contentType);
      if (extension == null) {
        _logger
            .warning('extension_resolution_failed type=$contentType url=$url');
        return null;
      }
      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        _logger.warning('empty_response url=$url');
        return null;
      }
      return UrlDownloadResult(
        bytes: bytes,
        contentType: contentType,
        extension: extension,
      );
    } on TimeoutException {
      _logger.warning('download_timeout url=$url');
      return null;
    } catch (error, stackTrace) {
      _logger.severe('download_error url=$url', error, stackTrace);
      return null;
    }
  }

  bool _isSupportedContentType(String contentType) {
    return contentType.startsWith('image/jpeg') ||
        contentType.startsWith('image/png');
  }

  String? _extensionFromContentType(String contentType) {
    if (contentType.startsWith('image/jpeg')) {
      return 'jpg';
    }
    if (contentType.startsWith('image/png')) {
      return 'png';
    }
    return null;
  }

  void dispose() {
    _client.close();
  }
}
