class WatcherStatusState {
  const WatcherStatusState({
    required this.fileWatcherActive,
    required this.clipboardActive,
    required this.lastError,
  });

  factory WatcherStatusState.initial() => const WatcherStatusState(
        fileWatcherActive: false,
        clipboardActive: false,
        lastError: null,
      );

  final bool fileWatcherActive;
  final bool clipboardActive;
  final String? lastError;

  WatcherStatusState copyWith({
    bool? fileWatcherActive,
    bool? clipboardActive,
    String? lastError,
    bool clearError = false,
  }) {
    return WatcherStatusState(
      fileWatcherActive: fileWatcherActive ?? this.fileWatcherActive,
      clipboardActive: clipboardActive ?? this.clipboardActive,
      lastError:
          clearError ? null : (lastError == null ? this.lastError : lastError),
    );
  }
}
