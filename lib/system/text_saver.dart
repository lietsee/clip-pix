import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../data/metadata_writer.dart';
import '../data/models/image_source_type.dart';
import 'image_saver.dart';

/// テキストファイルを保存するサービス
class TextSaver {
  TextSaver({
    required Directory? Function() getSelectedFolder,
    MetadataWriter? metadataWriter,
    Logger? logger,
    DateTime Function()? now,
  })  : _getSelectedFolder = getSelectedFolder,
        _metadataWriter = metadataWriter ?? const MetadataWriter(),
        _logger = logger ?? Logger('TextSaver'),
        _now = now ?? DateTime.now;

  final Directory? Function() _getSelectedFolder;
  final MetadataWriter _metadataWriter;
  final Logger _logger;
  final DateTime Function() _now;

  /// テキストデータの最大サイズ（1MB）
  static const _maxTextBytes = 1024 * 1024;

  /// 書き込み試行回数
  static const _maxWriteAttempts = 3;

  /// デフォルトのファイル名ベース
  static const _defaultBaseName = 'note';

  /// クリップボードからのテキストを保存
  ///
  /// [textData] 保存するテキストデータ
  /// [source] ソース情報（オプション）
  /// [sourceType] ソースの種類
  /// [fileName] ファイル名（拡張子なし、オプション）。指定しない場合は'note'
  Future<SaveResult> saveTextData(
    String textData, {
    String? source,
    ImageSourceType sourceType = ImageSourceType.local,
    String? fileName,
  }) async {
    final targetDirectory = _getSelectedFolder();
    if (targetDirectory == null) {
      _logger.warning('Save aborted: no target directory selected');
      return SaveResult.failed(error: 'no_selected_directory');
    }

    if (!await _ensureDirectoryWritable(targetDirectory)) {
      _logger.warning(
          'Save aborted: directory not writable ${targetDirectory.path}');
      return SaveResult.failed(error: 'directory_not_writable');
    }

    // テキストインジェクション保護
    final sanitizedText = _sanitizeText(textData);

    // サイズ制限チェック（空のテキストは許可）
    final textBytes = _textToBytes(sanitizedText);
    if (textBytes.length > _maxTextBytes) {
      _logger.warning(
          'Save aborted: text size ${textBytes.length} exceeds limit $_maxTextBytes');
      return SaveResult.failed(error: 'text_too_large');
    }

    // ファイル名の生成
    final baseName = fileName != null && fileName.isNotEmpty
        ? _sanitizeFileName(fileName)
        : _defaultBaseName;

    final textFile = await _createUniqueFile(
      directory: targetDirectory,
      baseName: baseName,
      extension: 'txt',
    );

    // ファイル書き込み
    final writeResult = await _writeTextWithRetry(textFile, sanitizedText);
    if (!writeResult) {
      return SaveResult.failed(error: 'write_failed');
    }

    // メタデータ保存
    final metadataRecord = ImageMetadataRecord(
      fileName: p.basename(textFile.path),
      savedAt: _now().toUtc(),
      source: source ?? 'Clipboard',
      sourceType: sourceType,
    );

    final metadataFile = await _metadataWriter.writeForImage(
      imageFile: textFile,
      record: metadataRecord,
    );

    _logger.info(
      'text_saved path=${textFile.path} metadata=${metadataFile.path} size=${textBytes.length}',
    );

    return SaveResult.completed(
      filePath: textFile.path,
      metadataPath: metadataFile.path,
    );
  }

  /// テキストのサニタイズ（インジェクション保護）
  ///
  /// - 制御文字を削除（改行、タブ、復帰を除く）
  /// - 前後の空白を削除
  String _sanitizeText(String text) {
    // 制御文字を削除（U+0000-U+001F、ただし \n, \t, \r は許可）
    final sanitized = text.replaceAllMapped(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'),
      (match) => '',
    );
    return sanitized.trim();
  }

  /// ファイル名のサニタイズ
  ///
  /// - 英数字、日本語、アンダースコア、ハイフンのみ許可
  /// - その他の文字はアンダースコアに置換
  String _sanitizeFileName(String fileName) {
    // パストラバーサル攻撃を防ぐため、スラッシュとバックスラッシュを削除
    var sanitized = fileName.replaceAll(RegExp(r'[/\\]'), '');
    // 特殊文字をアンダースコアに置換（英数字、日本語、アンダースコア、ハイフン以外）
    sanitized = sanitized.replaceAll(
      RegExp(r'[^a-zA-Z0-9\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF_\-]'),
      '_',
    );
    // 空の場合はデフォルト名
    return sanitized.isEmpty ? _defaultBaseName : sanitized;
  }

  /// テキストをバイト列に変換
  List<int> _textToBytes(String text) {
    return text.codeUnits;
  }

  /// ディレクトリが書き込み可能かチェック
  Future<bool> _ensureDirectoryWritable(Directory directory) async {
    try {
      if (!await directory.exists()) {
        return false;
      }
      final probe = File(p.join(directory.path, '.clip_pix_write_test'));
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (error, stackTrace) {
      _logger.warning(
        'Directory write validation failed for ${directory.path}',
        error,
        stackTrace,
      );
      return false;
    }
  }

  /// リトライ付きテキスト書き込み
  Future<bool> _writeTextWithRetry(File file, String text) async {
    for (var attempt = 0; attempt < _maxWriteAttempts; attempt++) {
      try {
        await file.writeAsString(text, flush: true);
        return true;
      } catch (error, stackTrace) {
        _logger.warning(
          'Failed to write text file attempt=${attempt + 1}',
          error,
          stackTrace,
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return false;
  }

  /// 一意なファイル名を生成
  Future<File> _createUniqueFile({
    required Directory directory,
    required String baseName,
    required String extension,
  }) async {
    var attempt = 0;
    while (true) {
      final suffix = attempt == 0 ? '' : '_$attempt';
      final candidateName = '$baseName$suffix.$extension';
      final candidatePath = p.join(directory.path, candidateName);
      final candidateFile = File(candidatePath);
      if (!await candidateFile.exists()) {
        return candidateFile;
      }
      attempt++;
    }
  }
}
