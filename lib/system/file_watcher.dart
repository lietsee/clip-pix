import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import 'state/watcher_status_notifier.dart';

class FileWatcherService {
  FileWatcherService({
    required WatcherStatusNotifier watcherStatus,
    required FutureOr<void> Function(File file) onFileAdded,
    required FutureOr<void> Function(String path) onFileDeleted,
    required FutureOr<void> Function() onStructureChanged,
    Duration debounceDuration = const Duration(milliseconds: 250),
    Logger? logger,
  })  : _watcherStatus = watcherStatus,
        _onFileAdded = onFileAdded,
        _onFileDeleted = onFileDeleted,
        _onStructureChanged = onStructureChanged,
        _debounceDuration = debounceDuration,
        _logger = logger ?? Logger('FileWatcherService');

  final WatcherStatusNotifier _watcherStatus;
  final FutureOr<void> Function(File file) _onFileAdded;
  final FutureOr<void> Function(String path) _onFileDeleted;
  final FutureOr<void> Function() _onStructureChanged;
  final Duration _debounceDuration;
  final Logger _logger;

  Directory? _rootDirectory;
  final Map<String, DirectoryWatcher> _watchers = <String, DirectoryWatcher>{};
  final Map<String, StreamSubscription<WatchEvent>> _subscriptions =
      <String, StreamSubscription<WatchEvent>>{};
  final Map<String, DateTime> _debounceTracker = <String, DateTime>{};
  final Map<String, bool> _watcherReady = <String, bool>{};

  bool get isActive => _watchers.isNotEmpty;

  static const Set<String> _supportedExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.txt',
  };

  Future<void> start(Directory directory) async {
    await stop();

    if (!await directory.exists()) {
      _logger.warning(
        'Watcher start aborted: directory does not exist ${directory.path}',
      );
      return;
    }

    _rootDirectory = Directory(_normalize(directory.path));

    await _attachWatcher(directory);
    await _syncSubdirectoryWatchers();

    _watcherStatus.setFileWatcherActive(true);
    _logger.info('FileWatcher started for ${directory.path}');
  }

  Future<void> stop() async {
    for (final subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _watchers.clear();
    _watcherReady.clear();
    _debounceTracker.clear();
    _rootDirectory = null;
    _watcherStatus.setFileWatcherActive(false);
    _logger.info('FileWatcher stopped');
  }

  Future<void> _attachWatcher(Directory directory) async {
    final normalizedPath = _normalize(directory.path);
    if (_watchers.containsKey(normalizedPath)) {
      return;
    }

    final watcher = DirectoryWatcher(normalizedPath);
    _watchers[normalizedPath] = watcher;
    _watcherReady[normalizedPath] = false;

    final subscription = watcher.events.listen(
      (event) => _handleEvent(event, normalizedPath),
      onError: (Object error, StackTrace stackTrace) {
        _logger.severe('Watcher error for $normalizedPath', error, stackTrace);
        _watcherStatus.setError('Watcher error: $error');
      },
      cancelOnError: false,
    );
    _subscriptions[normalizedPath] = subscription;

    try {
      await watcher.ready;
      _watcherReady[normalizedPath] = true;
    } catch (error, stackTrace) {
      _logger.warning(
          'Watcher ready failed for $normalizedPath', error, stackTrace);
    }
  }

  Future<void> _handleEvent(WatchEvent event, String originPath) async {
    if (_watcherReady[originPath] != true) {
      return;
    }

    final eventPath = _normalize(event.path);
    if (!_shouldEmit(eventPath, event.type)) {
      return;
    }

    switch (event.type) {
      case ChangeType.ADD:
      case ChangeType.MODIFY:
        await _handleAddOrModify(eventPath);
        break;
      case ChangeType.REMOVE:
        await _handleRemove(eventPath);
        break;
    }
  }

  Future<void> _handleAddOrModify(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await _onDirectoryAdded(path);
      return;
    }

    if (!_isSupportedFile(path)) {
      _logger.fine('Ignore event for unsupported file: $path');
      return;
    }

    final file = File(path);
    await Future.sync(() => _onFileAdded(file));
    _logger.fine('File event dispatched for $path');
  }

  Future<void> _handleRemove(String path) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('/.clip_pix_write_test') ||
        lower.endsWith('\\\\.clip_pix_write_test')) {
      return;
    }

    if (_watchers.containsKey(path)) {
      _cleanupWatcher(path);
      await Future.sync(_onStructureChanged);
      _logger.info('Subdirectory watcher removed for $path');
      return;
    }

    if (_isSupportedFile(path)) {
      await Future.sync(() => _onFileDeleted(path));
      _logger.fine('File deletion dispatched for $path');
    }
  }

  Future<void> _onDirectoryAdded(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      return;
    }

    await _attachWatcher(directory);
    await _syncSubdirectoryWatchers();
    await Future.sync(_onStructureChanged);
    _logger.info('Subdirectory watcher added for $path');
  }

  Future<void> _syncSubdirectoryWatchers() async {
    final root = _rootDirectory;
    if (root == null) {
      return;
    }

    final existing = Set<String>.from(_watchers.keys)..remove(root.path);
    final current = <String>{};

    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory) {
        final normalized = _normalize(entity.path);
        current.add(normalized);
        await _attachWatcher(entity);
      }
    }

    for (final stale in existing.difference(current)) {
      _cleanupWatcher(stale);
      _logger.info('Removed stale watcher for $stale');
    }
  }

  void _cleanupWatcher(String path) {
    final normalized = _normalize(path);
    final subscription = _subscriptions.remove(normalized);
    subscription?.cancel();
    _watchers.remove(normalized);
    _watcherReady.remove(normalized);
  }

  bool _isSupportedFile(String path) {
    final extension = p.extension(path).toLowerCase();
    return _supportedExtensions.contains(extension);
  }

  bool _shouldEmit(String path, ChangeType type) {
    final key = '$path-${type.toString()}';
    final now = DateTime.now();
    final last = _debounceTracker[key];
    if (last != null && now.difference(last) < _debounceDuration) {
      return false;
    }
    _debounceTracker[key] = now;
    return true;
  }

  String _normalize(String path) {
    return p.normalize(Directory(path).absolute.path);
  }
}
