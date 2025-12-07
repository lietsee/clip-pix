/// Debug logging utility that only outputs in debug/profile mode.
///
/// Usage:
/// ```dart
/// debugLog('[MyClass] some message');
/// ```
library;

import 'package:flutter/foundation.dart';

/// Prints a debug message only in debug or profile mode.
///
/// In release builds, this function does nothing and the message
/// is completely optimized out by the compiler.
void debugLog(String message) {
  if (kDebugMode || kProfileMode) {
    // ignore: avoid_print
    print(message);
  }
}
