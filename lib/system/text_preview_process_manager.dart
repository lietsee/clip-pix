import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/open_previews_repository.dart';

/// Manages text preview window processes independently of widget tree
///
/// This ensures preview processes are properly killed when the app exits,
/// even if widget dispose() methods are not called during abrupt shutdown.
class TextPreviewProcessManager extends ChangeNotifier {
  TextPreviewProcessManager({OpenPreviewsRepository? repository})
      : _repository = repository;

  final Logger _logger = Logger('TextPreviewProcessManager');
  final Map<String, Process> _processes = {};
  final Set<String> _launching = {};
  final OpenPreviewsRepository? _repository;

  /// Get all currently managed process IDs
  List<String> get processIds => _processes.keys.toList();

  /// Get open previews from repository for restoration
  List<dynamic> getOpenPreviews() {
    if (_repository == null) return [];
    return _repository!.getAll();
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
    debugPrint('[TextPreviewProcessManager] Marked $itemId as launching');
  }

  /// Register a running process
  void registerProcess(String itemId, Process process) {
    _processes[itemId] = process;
    _launching.remove(itemId);
    debugPrint(
        '[TextPreviewProcessManager] Registered process for $itemId (PID: ${process.pid})');

    // Monitor process exit
    process.exitCode.then((exitCode) {
      debugPrint(
          '[TextPreviewProcessManager] Process $itemId exited with code $exitCode');
      if (exitCode != 0) {
        _logger.warning(
            'Text preview process $itemId crashed (exit code $exitCode)');
      }
      _handleProcessExit(itemId);
    });
  }

  /// Remove a process from the manager (called when launch fails)
  void removeLaunching(String itemId) {
    _launching.remove(itemId);
    debugPrint(
        '[TextPreviewProcessManager] Removed launching flag for $itemId');
  }

  /// Handle process exit (cleanup tracking)
  void _handleProcessExit(String itemId) {
    _processes.remove(itemId);
    _repository?.remove(itemId);
    debugPrint(
        '[TextPreviewProcessManager] Cleaned up tracking for $itemId after exit');
    notifyListeners();
  }

  /// Kill a specific process
  bool killProcess(String itemId) {
    final process = _processes[itemId];
    if (process == null) {
      debugPrint('[TextPreviewProcessManager] No process found for $itemId');
      return false;
    }

    debugPrint('[TextPreviewProcessManager] Killing process $itemId');
    final killed = process.kill();
    if (killed) {
      _processes.remove(itemId);
      _repository?.remove(itemId);
      debugPrint(
          '[TextPreviewProcessManager] Removed $itemId from open previews repository');
    }
    notifyListeners();
    return killed;
  }

  /// Kill all managed processes (called on app exit)
  void killAll() {
    debugPrint(
        '[TextPreviewProcessManager] Killing all ${_processes.length} preview processes');

    for (final entry in _processes.entries) {
      debugPrint(
          '[TextPreviewProcessManager] Killing process ${entry.key} (PID: ${entry.value.pid})');
      entry.value.kill();
      // Synchronously remove from repository
      _repository?.remove(entry.key);
      debugPrint(
          '[TextPreviewProcessManager] Removed ${entry.key} from open previews repository');
    }

    _processes.clear();
    _launching.clear();
    debugPrint(
        '[TextPreviewProcessManager] All processes killed and cleaned up');
    notifyListeners();
  }

  @override
  void dispose() {
    killAll();
    super.dispose();
  }
}
