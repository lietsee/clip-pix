import 'package:flutter/foundation.dart';

/// Tracks batched mutations that require the grid to be hidden/offstage.
class GridLayoutMutationController extends ChangeNotifier {
  int _depth = 0;

  bool get isMutating => _depth > 0;

  void beginMutation() {
    _depth += 1;
    if (_depth == 1) {
      notifyListeners();
    }
  }

  void endMutation() {
    if (_depth == 0) {
      return;
    }
    _depth -= 1;
    if (_depth == 0) {
      notifyListeners();
    }
  }
}
