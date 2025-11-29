/// Platform-agnostic helper for always-on-top window functionality.
library;

import 'always_on_top_helper_stub.dart'
    if (dart.library.io) 'always_on_top_helper_io.dart';

/// Applies always-on-top state to the current window.
///
/// Returns true if successful, false otherwise.
Future<bool> applyAlwaysOnTop(bool enable) {
  return platformApplyAlwaysOnTop(enable);
}
