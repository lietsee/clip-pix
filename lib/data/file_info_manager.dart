import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'models/content_type.dart';
import 'models/image_source_type.dart';

/// フォルダごとの画像メタデータを `.fileInfo.json` で一括管理するクラス
///
/// - メモリキャッシュ: フォルダパスをキーに、ファイル名→メタデータのマップを保持
/// - デバウンス保存: 変更後5秒経過で自動保存
/// - スレッドセーフ: 同時アクセスを考慮した実装
class FileInfoManager {
  FileInfoManager({
    Duration debounceDuration = const Duration(seconds: 5),
    Logger? logger,
  })  : _debounceDuration = debounceDuration,
        _logger = logger ?? Logger('FileInfoManager');

  static const String _fileInfoName = '.fileInfo.json';
  static const String _version = '1.0';

  final Duration _debounceDuration;
  final Logger _logger;

  // フォルダパス → (ファイル名 → メタデータ) のキャッシュ
  final Map<String, Map<String, ImageMetadataEntry>> _cache = {};

  // フォルダパスごとのデバウンスタイマー
  final Map<String, Timer> _timers = {};

  /// 画像メタデータを追加または更新
  Future<void> upsertMetadata({
    required String imageFilePath,
    required String fileName,
    required DateTime savedAt,
    required String source,
    required ImageSourceType sourceType,
    ContentType contentType = ContentType.image,
    String memo = '',
    int favorite = 0,
  }) async {
    final folderPath = p.dirname(imageFilePath);

    // キャッシュ初期化
    _cache[folderPath] ??= {};

    // メタデータ追加
    _cache[folderPath]![fileName] = ImageMetadataEntry(
      file: fileName,
      savedAt: savedAt.toUtc(),
      source: source,
      sourceType: sourceType,
      contentType: contentType,
      memo: memo,
      favorite: favorite,
    );

    _logger.info('Metadata upserted: $fileName in $folderPath');

    // デバウンス保存をスケジュール
    _scheduleFlush(folderPath);
  }

  /// メモを更新（エントリが存在しない場合は新規作成）
  Future<void> updateMemo({
    required String imageFilePath,
    required String memo,
    required DateTime savedAt,
    required String source,
    required ImageSourceType sourceType,
  }) async {
    final folderPath = p.dirname(imageFilePath);
    final fileName = p.basename(imageFilePath);

    // キャッシュにない場合は読み込み
    if (!_cache.containsKey(folderPath)) {
      await _loadFromFile(folderPath);
    }

    // キャッシュ初期化（フォルダエントリがない場合）
    _cache[folderPath] ??= {};

    final folderCache = _cache[folderPath]!;

    // エントリが存在しない場合は新規作成
    if (!folderCache.containsKey(fileName)) {
      _logger.info('Creating new metadata entry for memo: $fileName');
      folderCache[fileName] = ImageMetadataEntry(
        file: fileName,
        savedAt: savedAt.toUtc(),
        source: source,
        sourceType: sourceType,
        memo: memo,
      );
    } else {
      // 既存エントリを更新
      final current = folderCache[fileName]!;
      folderCache[fileName] = current.copyWith(memo: memo);
    }

    _logger.info('Memo updated: $fileName -> "$memo"');

    // デバウンス保存をスケジュール
    _scheduleFlush(folderPath);
  }

  /// お気に入りを更新（エントリが存在しない場合は新規作成）
  Future<void> updateFavorite({
    required String imageFilePath,
    required int favorite,
    required DateTime savedAt,
    required String source,
    required ImageSourceType sourceType,
  }) async {
    final folderPath = p.dirname(imageFilePath);
    final fileName = p.basename(imageFilePath);

    // キャッシュにない場合は読み込み
    if (!_cache.containsKey(folderPath)) {
      await _loadFromFile(folderPath);
    }

    // キャッシュ初期化（フォルダエントリがない場合）
    _cache[folderPath] ??= {};

    final folderCache = _cache[folderPath]!;

    // エントリが存在しない場合は新規作成
    if (!folderCache.containsKey(fileName)) {
      _logger.info('Creating new metadata entry for favorite: $fileName');
      folderCache[fileName] = ImageMetadataEntry(
        file: fileName,
        savedAt: savedAt.toUtc(),
        source: source,
        sourceType: sourceType,
        memo: '',
        favorite: favorite,
      );
    } else {
      // 既存エントリを更新
      final current = folderCache[fileName]!;
      folderCache[fileName] = current.copyWith(favorite: favorite);
    }

    _logger.info('Favorite updated: $fileName -> $favorite');

    // デバウンス保存をスケジュール
    _scheduleFlush(folderPath);
  }

  /// 指定フォルダの全メタデータを読み込み
  Future<Map<String, ImageMetadataEntry>> loadMetadata(
      String folderPath) async {
    // キャッシュがあればそれを返す
    if (_cache.containsKey(folderPath)) {
      return Map.unmodifiable(_cache[folderPath]!);
    }

    // ファイルから読み込み
    await _loadFromFile(folderPath);
    return Map.unmodifiable(_cache[folderPath] ?? {});
  }

  /// 指定画像のメタデータを取得
  Future<ImageMetadataEntry?> getMetadata(String imageFilePath) async {
    final folderPath = p.dirname(imageFilePath);
    final fileName = p.basename(imageFilePath);

    if (!_cache.containsKey(folderPath)) {
      await _loadFromFile(folderPath);
    }

    return _cache[folderPath]?[fileName];
  }

  /// 即座にディスクに保存（アプリ終了時などに使用）
  Future<void> flush() async {
    _logger.info('Flushing all cached metadata to disk...');

    for (final folderPath in _cache.keys.toList()) {
      // タイマーをキャンセル
      _timers[folderPath]?.cancel();
      _timers.remove(folderPath);

      // 即座に保存
      await _saveToFile(folderPath);
    }

    _logger.info('Flush completed.');
  }

  /// リソースのクリーンアップ
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _logger.info('FileInfoManager disposed.');
  }

  // --- 内部メソッド ---

  void _scheduleFlush(String folderPath) {
    // 既存のタイマーをキャンセル
    _timers[folderPath]?.cancel();

    // 新しいタイマーをセット
    _timers[folderPath] = Timer(_debounceDuration, () {
      _saveToFile(folderPath);
      _timers.remove(folderPath);
    });
  }

  Future<void> _loadFromFile(String folderPath) async {
    final file = File(p.join(folderPath, _fileInfoName));

    if (!await file.exists()) {
      _logger.fine('No .fileInfo.json found in $folderPath');
      _cache[folderPath] = {};
      return;
    }

    try {
      final jsonString = await file.readAsString();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      final images = json['images'] as List<dynamic>?;
      if (images == null) {
        _logger.warning('Invalid .fileInfo.json format (missing "images")');
        _cache[folderPath] = {};
        return;
      }

      final metadata = <String, ImageMetadataEntry>{};
      for (final item in images) {
        if (item is! Map<String, dynamic>) continue;

        try {
          final entry = ImageMetadataEntry.fromJson(item);
          metadata[entry.file] = entry;
        } catch (error) {
          _logger.warning('Failed to parse metadata entry: $error');
        }
      }

      _cache[folderPath] = metadata;
      _logger
          .info('Loaded ${metadata.length} metadata entries from $folderPath');
    } catch (error, stackTrace) {
      _logger.severe(
          'Failed to load .fileInfo.json from $folderPath', error, stackTrace);
      _cache[folderPath] = {};
    }
  }

  Future<void> _saveToFile(String folderPath) async {
    final folderCache = _cache[folderPath];
    if (folderCache == null || folderCache.isEmpty) {
      _logger.fine('No metadata to save for $folderPath');
      return;
    }

    final file = File(p.join(folderPath, _fileInfoName));

    try {
      final json = {
        'version': _version,
        'images': folderCache.values.map((e) => e.toJson()).toList(),
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(json);
      await file.writeAsString(jsonString, flush: true);

      _logger
          .info('Saved ${folderCache.length} metadata entries to ${file.path}');
    } catch (error, stackTrace) {
      _logger.severe(
          'Failed to save .fileInfo.json to ${file.path}', error, stackTrace);
    }
  }
}

/// 画像メタデータエントリー
class ImageMetadataEntry {
  const ImageMetadataEntry({
    required this.file,
    required this.savedAt,
    required this.source,
    required this.sourceType,
    this.contentType = ContentType.image,
    this.memo = '',
    this.favorite = 0,
  });

  final String file;
  final DateTime savedAt;
  final String source;
  final ImageSourceType sourceType;
  final ContentType contentType;
  final String memo;
  final int favorite;

  Map<String, dynamic> toJson() {
    return {
      'file': file,
      'saved_at': savedAt.toUtc().toIso8601String(),
      'source': source,
      'source_type': imageSourceTypeToString(sourceType),
      'content_type': contentTypeToString(contentType),
      'memo': memo,
      'favorite': favorite,
    };
  }

  factory ImageMetadataEntry.fromJson(Map<String, dynamic> json) {
    final savedAtString = json['saved_at'] as String?;
    final savedAt = savedAtString != null
        ? DateTime.tryParse(savedAtString)?.toUtc() ?? DateTime.now().toUtc()
        : DateTime.now().toUtc();

    return ImageMetadataEntry(
      file: json['file'] as String? ?? '',
      savedAt: savedAt,
      source: json['source'] as String? ?? 'Unknown',
      sourceType: imageSourceTypeFromString(
        json['source_type'] as String? ?? 'unknown',
      ),
      contentType: contentTypeFromString(
        json['content_type'] as String? ?? 'image',
      ),
      memo: json['memo'] as String? ?? '',
      favorite: json['favorite'] as int? ?? 0,
    );
  }

  ImageMetadataEntry copyWith({
    String? file,
    DateTime? savedAt,
    String? source,
    ImageSourceType? sourceType,
    ContentType? contentType,
    String? memo,
    int? favorite,
  }) {
    return ImageMetadataEntry(
      file: file ?? this.file,
      savedAt: savedAt ?? this.savedAt,
      source: source ?? this.source,
      sourceType: sourceType ?? this.sourceType,
      contentType: contentType ?? this.contentType,
      memo: memo ?? this.memo,
      favorite: favorite ?? this.favorite,
    );
  }
}
