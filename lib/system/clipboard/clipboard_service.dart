/// クリップボード抽象化レイヤー
///
/// Windows/macOS両対応のためのプラットフォーム抽象化インターフェース。
/// 各プラットフォームの実装は `windows/` または `macos/` サブディレクトリに配置。
library;

import 'dart:typed_data';

import '../../data/models/image_source_type.dart';

// Conditional imports for platform-specific factory
import 'clipboard_service_stub.dart'
    if (dart.library.io) 'clipboard_service_io.dart' as platform;

/// クリップボード読み取り結果
class ClipboardContent {
  const ClipboardContent({
    this.imageData,
    this.text,
    this.sourceType = ImageSourceType.local,
  });

  /// 画像データ（PNG形式）
  final Uint8List? imageData;

  /// テキストデータ
  final String? text;

  /// 画像のソース種別
  final ImageSourceType sourceType;

  /// 画像データを含むか
  bool get hasImage => imageData != null;

  /// テキストデータを含むか
  bool get hasText => text != null;

  /// 空か（画像もテキストもない）
  bool get isEmpty => !hasImage && !hasText;
}

/// クリップボード読み取りインターフェース
///
/// プラットフォーム固有の実装:
/// - Windows: `WindowsClipboardReader` (win32 API)
/// - macOS: `MacOSClipboardReader` (MethodChannel + Swift)
abstract class ClipboardReader {
  /// クリップボードの変更番号を取得（ポーリング用）
  ///
  /// Windows: GetClipboardSequenceNumber()
  /// macOS: NSPasteboard.changeCount
  int getChangeCount();

  /// クリップボードの内容を読み取り
  ///
  /// 画像優先で読み取り、なければテキストを読み取る。
  /// 読み取り不可または空の場合は null を返す。
  Future<ClipboardContent?> read();

  /// リソース解放
  void dispose();
}

/// クリップボード書き込みインターフェース
///
/// プラットフォーム固有の実装:
/// - Windows: `WindowsClipboardWriter` (win32 API)
/// - macOS: `MacOSClipboardWriter` (MethodChannel + Swift)
abstract class ClipboardWriter {
  /// 画像をクリップボードにコピー
  ///
  /// [imageData] はPNG形式のバイト列。
  /// ガードトークンの管理は呼び出し側（ClipboardCopyService）で行う。
  Future<void> writeImage(Uint8List imageData);

  /// テキストをクリップボードにコピー
  Future<void> writeText(String text);

  /// リソース解放
  void dispose();
}

/// プラットフォーム別ファクトリ
///
/// 実行時のプラットフォームに応じた実装を生成する。
/// 非対応プラットフォームでは UnsupportedError をスローする。
class ClipboardServiceFactory {
  /// ClipboardReader のインスタンスを生成
  static ClipboardReader createReader() => platform.createReader();

  /// ClipboardWriter のインスタンスを生成
  static ClipboardWriter createWriter() => platform.createWriter();
}
