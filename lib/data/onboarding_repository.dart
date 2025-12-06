import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// オンボーディング状態を管理するリポジトリ
///
/// 初回起動チュートリアルの表示フラグをHiveで永続化する。
class OnboardingRepository extends ChangeNotifier {
  OnboardingRepository(this._box);

  final Box<dynamic> _box;

  static const _key = 'onboarding_completed';

  /// オンボーディングが完了済みかどうか
  bool get hasCompletedOnboarding {
    return _box.get(_key, defaultValue: false) as bool;
  }

  /// オンボーディング完了状態を設定
  Future<void> setOnboardingCompleted(bool completed) async {
    await _box.put(_key, completed);
    notifyListeners();
  }

  /// オンボーディングをリセット（設定画面から再表示する場合）
  Future<void> resetOnboarding() async {
    await _box.put(_key, false);
    notifyListeners();
  }
}
