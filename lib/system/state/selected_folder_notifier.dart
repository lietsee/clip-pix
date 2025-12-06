import 'dart:async';
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:state_notifier/state_notifier.dart';

import '../bookmark/bookmark_service.dart';
import '../debug_log.dart';
import 'folder_view_mode.dart';
import 'selected_folder_state.dart';

class SelectedFolderNotifier extends StateNotifier<SelectedFolderState> {
  SelectedFolderNotifier(this._box, {BookmarkService? bookmarkService})
      : _logger = Logger('SelectedFolderNotifier'),
        _bookmarkService = bookmarkService ?? BookmarkServiceFactory.create(),
        super(SelectedFolderState.initial()) {
    restoreFromHive();
  }

  final Box<dynamic> _box;
  final Logger _logger;
  final BookmarkService _bookmarkService;
  Timer? _scrollPersistTimer; // Debounce scroll position persistence

  static const _storageKey = 'selected_folder';

  Future<void> restoreFromHive() async {
    final stored = _box.get(_storageKey);
    if (stored is Map) {
      try {
        state = SelectedFolderState.fromJson(
          stored.cast<String, dynamic>(),
        );
      } catch (error, stackTrace) {
        _logger.warning('Failed to restore folder state', error, stackTrace);
      }
    }

    // On macOS, resolve security-scoped bookmark to restore folder access
    await _resolveBookmarkIfNeeded();

    _validateCurrentFolder();
  }

  /// Resolves security-scoped bookmark to restore folder access on macOS.
  Future<void> _resolveBookmarkIfNeeded() async {
    final bookmarkData = state.bookmarkData;
    if (bookmarkData == null || bookmarkData.isEmpty) {
      return;
    }

    final result = await _bookmarkService.resolveBookmark(bookmarkData);
    if (result == null) {
      _logger.warning('Failed to resolve bookmark, clearing bookmark data');
      state = state.copyWith(bookmarkData: null);
      await persist();
      return;
    }

    _logger.info('Bookmark resolved: ${result.path}, isStale=${result.isStale}');

    // If bookmark is stale, we might need to re-save it
    if (result.isStale) {
      _logger.info('Bookmark is stale, will re-save on next folder access');
      // The folder access should still work, but we should re-save the bookmark
      final newBookmark = await _bookmarkService.saveBookmark(result.path);
      if (newBookmark != null) {
        state = state.copyWith(bookmarkData: newBookmark);
        await persist();
      }
    }
  }

  Future<void> persist() async {
    await _box.put(_storageKey, state.toJson());
  }

  Future<void> setFolder(Directory directory) async {
    final sanitizedHistory = _buildHistory(directory);

    // Save security-scoped bookmark for macOS
    final bookmarkData = await _bookmarkService.saveBookmark(directory.path);
    if (bookmarkData != null) {
      _logger.info('Bookmark saved for: ${directory.path}');
    }

    state = state.copyWith(
      current: directory,
      history: sanitizedHistory,
      viewMode: FolderViewMode.root,
      currentTab: null,
      rootScrollOffset: 0,
      isValid: _isDirectoryWritable(directory),
      viewDirectory: directory,
      bookmarkData: bookmarkData,
    );
    await persist();
  }

  Future<void> clearFolder() async {
    state = SelectedFolderState.initial();
    await persist();
  }

  Future<void> switchToRoot() async {
    debugLog('[SelectedFolderNotifier] switchToRoot START');
    final current = state.current;
    debugLog('[SelectedFolderNotifier] switchToRoot: current=$current');
    state = state.copyWith(
      viewMode: FolderViewMode.root,
      currentTab: null,
      viewDirectory: current,
    );
    debugLog('[SelectedFolderNotifier] switchToRoot: state updated');
    await persist();
    debugLog('[SelectedFolderNotifier] switchToRoot END');
  }

  Future<void> switchToSubfolder(String name) async {
    debugLog('[SelectedFolderNotifier] switchToSubfolder START: $name');
    final base = state.current;
    if (base == null) {
      debugLog('[SelectedFolderNotifier] switchToSubfolder: base is null, returning');
      return;
    }
    final subfolder = Directory(p.join(base.path, name));

    debugLog('[SelectedFolderNotifier] switchToSubfolder: '
        'name=$name, '
        'subfolder=${subfolder.path}, '
        'oldViewMode=${state.viewMode}, '
        'newViewMode=subfolder');

    state = state.copyWith(
      viewMode: FolderViewMode.subfolder,
      currentTab: name,
      viewDirectory: subfolder,
    );
    debugLog('[SelectedFolderNotifier] switchToSubfolder: state updated');
    await persist();

    debugLog('[SelectedFolderNotifier] switchToSubfolder END: $name');
  }

  void updateRootScroll(double offset) {
    state = state.copyWith(rootScrollOffset: offset);

    // Debounce persistence to avoid rebuild storm
    // Only persist after 500ms of scroll inactivity
    _scrollPersistTimer?.cancel();
    _scrollPersistTimer = Timer(const Duration(milliseconds: 500), () {
      persist(); // Persist in background after debounce
    });
  }

  Future<void> toggleMinimapAlwaysVisible() async {
    state =
        state.copyWith(isMinimapAlwaysVisible: !state.isMinimapAlwaysVisible);
    await persist();
  }

  /// Request scroll to top (does not persist)
  void requestScrollToTop() {
    state = state.copyWith(scrollToTopRequested: true);
  }

  /// Clear scroll to top request (does not persist)
  void clearScrollToTopRequest() {
    state = state.copyWith(scrollToTopRequested: false);
  }

  void _validateCurrentFolder() {
    final current = state.current;
    if (current == null) {
      state = state.copyWith(isValid: false, viewDirectory: null);
      return;
    }
    final isValid = _isDirectoryWritable(current);
    final viewDirectory = state.viewDirectory ?? current;
    state = state.copyWith(isValid: isValid, viewDirectory: viewDirectory);
  }

  List<Directory> _buildHistory(Directory newDirectory) {
    final history = <Directory>[newDirectory];
    history.addAll(
      state.history.where((dir) => dir.path != newDirectory.path).take(2),
    );
    return history;
  }

  bool _isDirectoryWritable(Directory directory) {
    try {
      if (!directory.existsSync()) {
        return false;
      }
      final testFile = File(p.join(directory.path, '.clip_pix_access_test'));
      testFile.writeAsStringSync('ok');
      testFile.deleteSync();
      return true;
    } catch (error, stackTrace) {
      _logger.warning(
          'Directory validation failed: ${directory.path}', error, stackTrace);
      return false;
    }
  }

  @override
  void dispose() {
    _scrollPersistTimer?.cancel();
    _bookmarkService.dispose();
    super.dispose();
  }
}
