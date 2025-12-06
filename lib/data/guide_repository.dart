import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// インタラクティブガイド状態を管理するリポジトリ
///
/// 操作ガイド（コーチマーク）の表示フラグをHiveで永続化する。
class GuideRepository extends ChangeNotifier {
  GuideRepository(this._box);

  final Box<dynamic> _box;

  static const _keyFirstGuide = 'first_guide_completed';

  /// セッション中の完了フラグ（永続化されない）
  bool _sessionCompleted = false;

  /// 初回ガイドが完了済みかどうか
  /// 永続化フラグまたはセッションフラグがtrueなら完了とみなす
  bool get hasCompletedFirstGuide {
    return _sessionCompleted || (_box.get(_keyFirstGuide, defaultValue: false) as bool);
  }

  /// セッション完了をマーク（永続化しない）
  void markSessionCompleted() {
    _sessionCompleted = true;
    notifyListeners();
  }

  /// ガイド完了状態を設定（永続化）
  Future<void> setFirstGuideCompleted(bool completed) async {
    await _box.put(_keyFirstGuide, completed);
    notifyListeners();
  }

  /// ガイドをリセット（設定画面から再表示する場合）
  Future<void> resetGuide() async {
    _sessionCompleted = false;
    await _box.put(_keyFirstGuide, false);
    notifyListeners();
  }
}
