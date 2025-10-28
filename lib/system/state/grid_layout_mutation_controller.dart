import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Tracks batched mutations that require the grid to be hidden/offstage.
class GridLayoutMutationController extends ChangeNotifier {
  GridLayoutMutationController({bool debugLoggingEnabled = false})
      : _debugLoggingEnabled = debugLoggingEnabled;

  int _depth = 0;
  bool _debugLoggingEnabled;
  int debugBeginCount = 0;
  int debugEndCount = 0;
  int? _activeFrameNumber;
  int _concurrentFrameBegins = 0;
  final List<bool> _hideStack = <bool>[];
  int _hideDepth = 0;

  bool get isMutating => _depth > 0;
  bool get shouldHideGrid => _hideDepth > 0;

  bool get debugLoggingEnabled => _debugLoggingEnabled;

  set debugLoggingEnabled(bool value) {
    _debugLoggingEnabled = value;
  }

  /// 状態が不整合になっている場合に強制的にリセットする。
  /// begin/end の呼び出し不一致が発生した場合の緊急リセット用。
  void resetIfInconsistent() {
    if (_depth > 10 || _hideDepth > 5) {
      if (_debugLoggingEnabled) {
        debugPrint(
          '[GridLayoutMutationController] INCONSISTENT STATE DETECTED: '
          'depth=$_depth hideDepth=$_hideDepth beginCount=$debugBeginCount endCount=$debugEndCount; forcing reset',
        );
      }
      _depth = 0;
      _hideDepth = 0;
      _hideStack.clear();
      _activeFrameNumber = null;
      _concurrentFrameBegins = 0;
      notifyListeners();
    }
  }

  void beginMutation({bool hideGrid = true}) {
    _depth += 1;
    debugBeginCount += 1;
    _hideStack.add(hideGrid);
    if (hideGrid) {
      _hideDepth += 1;
    }
    int? frameStamp;
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      frameStamp =
          SchedulerBinding.instance.currentFrameTimeStamp?.inMicroseconds;
    }
    if (_depth == 1) {
      _activeFrameNumber = frameStamp;
      _concurrentFrameBegins = 1;
    } else if (_activeFrameNumber == frameStamp) {
      _concurrentFrameBegins += 1;
    } else {
      _activeFrameNumber = frameStamp;
      _concurrentFrameBegins = 1;
    }
    if (_debugLoggingEnabled) {
      debugPrint(
        '[GridLayoutMutationController] begin depth=$_depth frameTime=$_activeFrameNumber concurrentBegins=$_concurrentFrameBegins '
        'hide=$hideGrid hideDepth=$_hideDepth '
        'phase=${SchedulerBinding.instance.schedulerPhase} transientCallbacks=${SchedulerBinding.instance.transientCallbackCount} '
        'time=${DateTime.now().toIso8601String()}',
      );
    }
    if (_depth == 1 || (hideGrid && _hideDepth == 1)) {
      notifyListeners();
    }
  }

  void endMutation({bool? hideGrid}) {
    // 不整合状態を検出してリセット
    resetIfInconsistent();

    if (_depth == 0) {
      return;
    }
    bool hideFlag = false;
    if (_hideStack.isNotEmpty) {
      hideFlag = _hideStack.removeLast();
    }
    if (hideGrid != null && hideFlag != hideGrid && _debugLoggingEnabled) {
      debugPrint(
        '[GridLayoutMutationController] end mismatched hide flag detected provided=$hideGrid stack=$hideFlag',
      );
    }
    if (hideFlag && _hideDepth > 0) {
      _hideDepth -= 1;
    }
    _depth -= 1;
    debugEndCount += 1;
    int? frameStamp;
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      frameStamp =
          SchedulerBinding.instance.currentFrameTimeStamp?.inMicroseconds;
    }
    if (_debugLoggingEnabled) {
      debugPrint(
        '[GridLayoutMutationController] end depth=$_depth frameTime=$frameStamp '
        'hide=$hideFlag hideDepth=$_hideDepth '
        'phase=${SchedulerBinding.instance.schedulerPhase} transientCallbacks=${SchedulerBinding.instance.transientCallbackCount} '
        'time=${DateTime.now().toIso8601String()}',
      );
    }
    if (_depth == 0 || (hideFlag && _hideDepth == 0)) {
      _activeFrameNumber = null;
      _concurrentFrameBegins = 0;
      notifyListeners();
    }
  }
}
