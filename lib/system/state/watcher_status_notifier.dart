import 'package:logging/logging.dart';
import 'package:state_notifier/state_notifier.dart';

import 'watcher_status_state.dart';

class WatcherStatusNotifier extends StateNotifier<WatcherStatusState> {
  WatcherStatusNotifier()
      : _logger = Logger('WatcherStatusNotifier'),
        super(WatcherStatusState.initial());

  final Logger _logger;

  void setFileWatcherActive(bool isActive) {
    state = state.copyWith(fileWatcherActive: isActive);
  }

  void setClipboardActive(bool isActive) {
    state = state.copyWith(clipboardActive: isActive);
  }

  void setError(String message) {
    _logger.warning('Watcher status error: $message');
    state = state.copyWith(lastError: message);
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}
