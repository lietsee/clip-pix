import 'dart:ui';

import 'package:hive/hive.dart';

import 'models/grid_card_pref.dart';

class GridCardPreferencesRepository {
  GridCardPreferencesRepository(this._box);

  static const double defaultWidth = 200;
  static const double defaultHeight = 200;
  static const double defaultScale = 1.0;
  static const int defaultColumnSpan = 1;

  final Box<GridCardPreference> _box;

  GridCardPreference getOrCreate(String id) {
    final existing = _box.get(id);
    if (existing != null) {
      return existing;
    }
    final created = GridCardPreference(
      id: id,
      width: defaultWidth,
      height: defaultHeight,
      scale: defaultScale,
      columnSpan: defaultColumnSpan,
      customHeight: null,
    );
    _box.put(id, created);
    return created;
  }

  GridCardPreference? get(String id) => _box.get(id);

  Future<void> saveSize(String id, Size size) async {
    final pref = getOrCreate(
      id,
    ).copyWith(width: size.width, height: size.height, customHeight: size.height);
    await _box.put(id, pref);
  }

  Future<void> saveScale(String id, double scale) async {
    final pref = getOrCreate(id).copyWith(scale: scale);
    await _box.put(id, pref);
  }

  Future<void> saveColumnSpan(String id, int span) async {
    final pref = getOrCreate(id).copyWith(columnSpan: span);
    await _box.put(id, pref);
  }

  Future<void> saveCustomHeight(String id, double? height) async {
    final pref = getOrCreate(id).copyWith(customHeight: height);
    await _box.put(id, pref);
  }

  Future<void> remove(String id) async {
    await _box.delete(id);
  }

  Future<void> clear() async {
    await _box.clear();
  }
}
