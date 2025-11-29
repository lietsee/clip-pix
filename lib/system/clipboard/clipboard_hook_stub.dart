/// Stub implementation for clipboard hooks on unsupported platforms.
///
/// Returns null to indicate hook is not available.
library;

import 'dart:async';

import 'package:logging/logging.dart';

/// Creates a clipboard hook stub that always returns null.
///
/// Used on platforms where native clipboard hooks are not supported.
ClipboardHook? createClipboardHook(
  FutureOr<void> Function() onEvent,
  Logger logger,
) {
  return null;
}

/// Abstract interface for clipboard hooks.
///
/// Duplicated here to avoid circular imports.
abstract class ClipboardHook {
  Future<bool> start();
  Future<void> stop();
}
