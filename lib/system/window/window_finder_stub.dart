/// Stub implementation for window finder on unsupported platforms.
library;

/// Always returns false (window finding not supported).
bool platformIsWindowOpen(String titleHash) {
  return false;
}

/// No-op on unsupported platforms.
void platformActivateWindow(String titleHash) {
  // Not supported
}
