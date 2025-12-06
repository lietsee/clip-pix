import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pdfx/pdfx.dart';

/// PDFサムネイルキャッシュサービス
///
/// PDFの1ページ目を画像に変換してメモリ/ディスクにキャッシュする
class PdfThumbnailCacheService extends ChangeNotifier {
  PdfThumbnailCacheService({
    required String cacheDirectory,
    Logger? logger,
  })  : _cacheDirectory = cacheDirectory,
        _logger = logger ?? Logger('PdfThumbnailCacheService');

  final String _cacheDirectory;
  final Logger _logger;

  /// メモリキャッシュ（ファイルパス → サムネイルバイト）
  final Map<String, Uint8List> _memoryCache = {};

  /// 最大メモリキャッシュサイズ
  static const int _maxMemoryCacheSize = 50;

  /// サムネイル取得（キャッシュ優先）
  ///
  /// [pdfPath] PDFファイルのパス
  /// [width] サムネイルの幅（デフォルト300px）
  Future<Uint8List?> getThumbnail(String pdfPath, {int width = 300}) async {
    // 1. メモリキャッシュ確認
    if (_memoryCache.containsKey(pdfPath)) {
      return _memoryCache[pdfPath];
    }

    // 2. ディスクキャッシュ確認
    final cacheFile = _getCacheFile(pdfPath);
    if (await cacheFile.exists()) {
      try {
        final bytes = await cacheFile.readAsBytes();
        _addToMemoryCache(pdfPath, bytes);
        return bytes;
      } catch (e) {
        _logger.warning('Failed to read cache file: ${cacheFile.path}', e);
      }
    }

    // 3. 新規生成
    try {
      final bytes = await _generateThumbnail(pdfPath, width);
      if (bytes != null) {
        _addToMemoryCache(pdfPath, bytes);
        await _saveToDisk(cacheFile, bytes);
      }
      return bytes;
    } catch (e, stackTrace) {
      _logger.warning(
          'Failed to generate thumbnail for $pdfPath', e, stackTrace);
      return null;
    }
  }

  /// PDFのページ数を取得
  Future<int> getPageCount(String pdfPath) async {
    try {
      final document = await PdfDocument.openFile(pdfPath);
      final count = document.pagesCount;
      await document.close();
      return count;
    } catch (e) {
      _logger.warning('Failed to get page count for $pdfPath', e);
      return 1;
    }
  }

  /// サムネイル生成
  Future<Uint8List?> _generateThumbnail(String pdfPath, int width) async {
    final document = await PdfDocument.openFile(pdfPath);
    try {
      final page = await document.getPage(1);
      try {
        final aspectRatio = page.width / page.height;
        final height = (width / aspectRatio).round();

        final image = await page.render(
          width: width.toDouble(),
          height: height.toDouble(),
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        return image?.bytes;
      } finally {
        await page.close();
      }
    } finally {
      await document.close();
    }
  }

  /// キャッシュファイルのパスを取得
  File _getCacheFile(String pdfPath) {
    final hash = pdfPath.hashCode.toRadixString(16);
    final fileName = '${p.basenameWithoutExtension(pdfPath)}_$hash.png';
    return File(p.join(_cacheDirectory, fileName));
  }

  /// ディスクに保存
  Future<void> _saveToDisk(File file, Uint8List bytes) async {
    try {
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsBytes(bytes);
    } catch (e) {
      _logger.warning('Failed to save thumbnail to disk: ${file.path}', e);
    }
  }

  /// メモリキャッシュに追加（LRU制限）
  void _addToMemoryCache(String key, Uint8List value) {
    // LRU: 最大サイズを超えたら古いものを削除
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      final oldestKey = _memoryCache.keys.first;
      _memoryCache.remove(oldestKey);
    }
    _memoryCache[key] = value;
  }

  /// 特定のPDFのキャッシュをクリア
  Future<void> clearCache(String pdfPath) async {
    _memoryCache.remove(pdfPath);
    final cacheFile = _getCacheFile(pdfPath);
    if (await cacheFile.exists()) {
      await cacheFile.delete();
    }
  }

  /// メモリキャッシュをクリア
  void clearMemoryCache() {
    _memoryCache.clear();
  }

  /// 全キャッシュをクリア（メモリ + ディスク）
  Future<void> clearAllCache() async {
    _memoryCache.clear();
    final cacheDir = Directory(_cacheDirectory);
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
    }
  }

  @override
  void dispose() {
    _memoryCache.clear();
    super.dispose();
  }
}
