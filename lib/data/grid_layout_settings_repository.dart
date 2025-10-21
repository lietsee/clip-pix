import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'models/grid_layout_settings.dart';

class GridLayoutSettingsRepository extends ChangeNotifier {
  GridLayoutSettingsRepository(this._box);

  final Box<dynamic> _box;

  static const _key = 'layout_settings';

  GridLayoutSettings get value {
    final raw = _box.get(_key);
    if (raw is GridLayoutSettings) {
      return raw;
    }
    if (raw is Map) {
      // 旧形式: Map に値が保存されていた場合の互換処理
      return GridLayoutSettings(
        preferredColumns: raw['preferredColumns'] as int? ?? 6,
        maxColumns: raw['maxColumns'] as int? ?? 6,
        background: GridBackgroundTone.values[
            raw['background'] as int? ?? GridBackgroundTone.white.index],
        bulkSpan: raw['bulkSpan'] as int? ?? 1,
      );
    }
    final defaults = GridLayoutSettings.defaults();
    _box.put(_key, defaults);
    return defaults;
  }

  Future<void> update(GridLayoutSettings settings) async {
    await _box.put(_key, settings);
    notifyListeners();
  }
}
