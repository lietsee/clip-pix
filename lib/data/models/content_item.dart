import 'package:hive/hive.dart';

import 'content_type.dart';
import 'image_source_type.dart';

/// コンテンツアイテムの基底クラス
/// 画像とテキストの共通フィールドを定義
abstract class ContentItem extends HiveObject {
  ContentItem({
    required this.id,
    required this.filePath,
    required this.contentType,
    this.sourceType = ImageSourceType.unknown,
    DateTime? savedAt,
    this.source,
    this.memo = '',
    this.favorite = 0,
  }) : savedAt = savedAt ?? DateTime.now().toUtc();

  /// 一意識別子（通常はファイルパス）
  final String id;

  /// ファイルパス
  final String filePath;

  /// コンテンツの種類（画像/テキスト）
  final ContentType contentType;

  /// ソースの種類（Web/ローカル/不明）
  final ImageSourceType sourceType;

  /// 保存日時（UTC）
  final DateTime savedAt;

  /// ソースURL（該当する場合）
  final String? source;

  /// メモ
  final String memo;

  /// お気に入りレベル（0=なし、1=緑、2=オレンジ、3=ピンク）
  final int favorite;

  /// copyWithメソッドは各サブクラスで実装
  ContentItem copyWith({
    String? id,
    String? filePath,
    ContentType? contentType,
    ImageSourceType? sourceType,
    DateTime? savedAt,
    String? source,
    String? memo,
    int? favorite,
  });
}
