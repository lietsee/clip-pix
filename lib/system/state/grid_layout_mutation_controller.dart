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
