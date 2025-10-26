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

  bool get isMutating => _depth > 0;

  bool get debugLoggingEnabled => _debugLoggingEnabled;

  set debugLoggingEnabled(bool value) {
    _debugLoggingEnabled = value;
  }

  void beginMutation() {
    _depth += 1;
    debugBeginCount += 1;
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
        'phase=${SchedulerBinding.instance.schedulerPhase} transientCallbacks=${SchedulerBinding.instance.transientCallbackCount} '
        'time=${DateTime.now().toIso8601String()}',
      );
    }
    if (_depth == 1) {
      notifyListeners();
    }
  }

  void endMutation() {
    if (_depth == 0) {
      return;
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
        'phase=${SchedulerBinding.instance.schedulerPhase} transientCallbacks=${SchedulerBinding.instance.transientCallbackCount} '
        'time=${DateTime.now().toIso8601String()}',
      );
    }
    if (_depth == 0) {
      _activeFrameNumber = null;
      _concurrentFrameBegins = 0;
      notifyListeners();
    }
  }
}
