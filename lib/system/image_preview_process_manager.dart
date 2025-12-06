import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/open_previews_repository.dart';

/// Manages image preview window processes independently of widget tree
///
/// This ensures preview processes are properly killed when the app exits,
/// even if widget dispose() methods are not called during abrupt shutdown.
class ImagePreviewProcessManager extends ChangeNotifier {
  ImagePreviewProcessManager({OpenPreviewsRepository? repository})
      : _repository = repository;

  final Logger _logger = Logger('ImagePreviewProcessManager');
  final Map<String, Process> _processes = {};
  final Set<String> _launching = {};
  final OpenPreviewsRepository? _repository;

  /// Get all currently managed process IDs
  List<String> get processIds => _processes.keys.toList();

  /// Get open previews from repository for restoration
  List<dynamic> getOpenPreviews() {
    return _repository?.getAll() ?? [];
  }

  /// Remove old preview entries from repository
  Future<void> removeOldPreviews(Duration duration) async {
    await _repository?.removeOlderThan(duration);
  }

  /// Remove a specific preview from repository
  Future<void> removePreview(String itemId) async {
    await _repository?.remove(itemId);
  }

  /// Check if a process is currently launching
  bool isLaunching(String itemId) => _launching.contains(itemId);

  /// Check if a process is currently running
  bool isRunning(String itemId) => _processes.containsKey(itemId);

  /// Mark a process as launching (prevents duplicate launches)
  void markLaunching(String itemId) {
    _launching.add(itemId);
    debugPrint('[ImagePreviewProcessManager] Marked $itemId as launching');
  }

  /// Register a running process
  Future<void> registerProcess(String itemId, Process process,
      {bool alwaysOnTop = false}) async {
    _processes[itemId] = process;
    _launching.remove(itemId);

    // Persist to repository for restoration on next app start
    await _repository?.add(itemId, alwaysOnTop: alwaysOnTop);

    debugPrint(
        '[ImagePreviewProcessManager] Registered process for $itemId (PID: ${process.pid}, alwaysOnTop: $alwaysOnTop)');

    // Monitor process exit
    process.exitCode.then((exitCode) {
      debugPrint(
          '[ImagePreviewProcessManager] Process $itemId exited with code $exitCode');
      if (exitCode != 0) {
        _logger.warning(
            'Image preview process $itemId crashed (exit code $exitCode)');
      }
      _handleProcessExit(itemId);
    });
  }

  /// Remove a process from the manager (called when launch fails)
  void removeLaunching(String itemId) {
    _launching.remove(itemId);
    debugPrint(
        '[ImagePreviewProcessManager] Removed launching flag for $itemId');
  }

  /// Handle process exit (cleanup tracking)
  void _handleProcessExit(String itemId) {
    _processes.remove(itemId);
    _repository?.remove(itemId);
    debugPrint(
        '[ImagePreviewProcessManager] Cleaned up tracking for $itemId after exit');
    notifyListeners();
  }

  /// Kill a specific process
  bool killProcess(String itemId) {
    final process = _processes[itemId];
    if (process == null) {
      debugPrint('[ImagePreviewProcessManager] No process found for $itemId');
      return false;
    }

    debugPrint('[ImagePreviewProcessManager] Killing process $itemId');
    final killed = process.kill();
    if (killed) {
      _processes.remove(itemId);
      _repository?.remove(itemId);
      debugPrint(
          '[ImagePreviewProcessManager] Removed $itemId from open previews repository');
    }
    notifyListeners();
    return killed;
  }

  /// Kill all managed processes (called on app exit)
  Future<void> killAll(
      {Duration gracePeriod = const Duration(milliseconds: 500)}) async {
    debugPrint(
        '[ImagePreviewProcessManager] Killing all ${_processes.length} preview processes');

    // Send kill signal and wait for exit
    final futures = <Future<void>>[];
    for (final entry in _processes.entries) {
      debugPrint(
          '[ImagePreviewProcessManager] Killing process ${entry.key} (PID: ${entry.value.pid})');
      entry.value.kill();

      // Wait for process exit with timeout
      futures.add(
        entry.value.exitCode
            .timeout(gracePeriod)
            .then((code) => debugPrint(
                '[ImagePreviewProcessManager] Process ${entry.key} exited with code $code'))
            .catchError((_) => debugPrint(
                '[ImagePreviewProcessManager] Process ${entry.key} exit timed out')),
      );
    }

    // Wait for all processes to exit
    await Future.wait(futures);

    _processes.clear();
    _launching.clear();
    // DON'T clear repository - preserve for next session restoration
    debugPrint(
        '[ImagePreviewProcessManager] All processes killed (repository preserved for restoration)');
    notifyListeners();
  }

  @override
  void dispose() {
    killAll();
    super.dispose();
  }
}
