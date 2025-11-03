import 'package:hive/hive.dart';

part 'open_preview_item.g.dart';

/// 現在開いているTextPreviewWindowの追跡情報
/// アプリ再起動時にプレビューウィンドウを復元するために使用
@HiveType(typeId: 9)
class OpenPreviewItem extends HiveObject {
  OpenPreviewItem({
    required this.itemId,
    required this.alwaysOnTop,
    required this.openedAt,
  });

  /// TextContentItemのID（ファイルパス）
  @HiveField(0)
  final String itemId;

  /// 最前面表示状態
  @HiveField(1)
  final bool alwaysOnTop;

  /// 開いた日時（クリーンアップ用）
  @HiveField(2)
  final DateTime openedAt;

  OpenPreviewItem copyWith({
    String? itemId,
    bool? alwaysOnTop,
    DateTime? openedAt,
  }) {
    return OpenPreviewItem(
      itemId: itemId ?? this.itemId,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      openedAt: openedAt ?? this.openedAt,
    );
  }

  @override
  String toString() {
    return 'OpenPreviewItem(itemId: $itemId, alwaysOnTop: $alwaysOnTop, openedAt: $openedAt)';
  }
}
