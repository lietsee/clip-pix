import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

class GridOrderRepository extends ChangeNotifier {
  GridOrderRepository(this._box);

  final Box<dynamic> _box;

  List<String> getOrder(String path) {
    final stored = _box.get(path);
    if (stored is List) {
      return List<String>.from(stored);
    }
    return const <String>[];
  }

  List<String> sync(String path, List<String> currentIds) {
    final stored = getOrder(path);
    final currentSet = currentIds.toSet();
    final cleaned = <String>[];
    for (final id in stored) {
      if (currentSet.contains(id)) {
        cleaned.add(id);
      }
    }
    for (final id in currentIds) {
      if (!cleaned.contains(id)) {
        cleaned.add(id);
      }
    }
    if (!_listEquals(stored, cleaned)) {
      scheduleMicrotask(() => save(path, cleaned));
    }
    return cleaned;
  }

  Future<void> save(String path, List<String> order) async {
    await _box.put(path, order);
    notifyListeners();
  }

  Future<void> remove(String path) async {
    await _box.delete(path);
    notifyListeners();
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
