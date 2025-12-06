import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// オンボーディング状態を管理するリポジトリ
///
/// 初回起動チュートリアルの表示フラグをHiveで永続化する。
class OnboardingRepository extends ChangeNotifier {
  OnboardingRepository(this._box);

  final Box<dynamic> _box;

  static const _key = 'onboarding_completed';

  /// セッション中の完了フラグ（永続化されない）
  bool _sessionCompleted = false;

  /// オンボーディングが完了済みかどうか
  /// 永続化フラグまたはセッションフラグがtrueなら完了とみなす
  bool get hasCompletedOnboarding {
    return _sessionCompleted || (_box.get(_key, defaultValue: false) as bool);
  }

  /// セッション完了をマーク（永続化しない）
  /// 「次回から表示しない」にチェックしなかった場合に使用
  void markSessionCompleted() {
    _sessionCompleted = true;
    notifyListeners();
  }

  /// オンボーディング完了状態を設定
  Future<void> setOnboardingCompleted(bool completed) async {
    await _box.put(_key, completed);
    notifyListeners();
  }

  /// オンボーディングをリセット（設定画面から再表示する場合）
  Future<void> resetOnboarding() async {
    _sessionCompleted = false;
    await _box.put(_key, false);
    notifyListeners();
  }
}
