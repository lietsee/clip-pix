import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:state_notifier/state_notifier.dart';

import 'folder_view_mode.dart';
import 'selected_folder_state.dart';

class SelectedFolderNotifier extends StateNotifier<SelectedFolderState> {
  SelectedFolderNotifier(this._box)
      : _logger = Logger('SelectedFolderNotifier'),
        super(SelectedFolderState.initial()) {
    restoreFromHive();
  }

  final Box<dynamic> _box;
  final Logger _logger;
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
    _validateCurrentFolder();
  }

  Future<void> persist() async {
    await _box.put(_storageKey, state.toJson());
  }

  Future<void> setFolder(Directory directory) async {
    final sanitizedHistory = _buildHistory(directory);
    state = state.copyWith(
      current: directory,
      history: sanitizedHistory,
      viewMode: FolderViewMode.root,
      currentTab: null,
      rootScrollOffset: 0,
      isValid: _isDirectoryWritable(directory),
      viewDirectory: directory,
    );
    await persist();
  }

  Future<void> clearFolder() async {
    state = SelectedFolderState.initial();
    await persist();
  }

  Future<void> switchToRoot() async {
    print('[SelectedFolderNotifier] switchToRoot START');
    final current = state.current;
    print('[SelectedFolderNotifier] switchToRoot: current=$current');
    state = state.copyWith(
      viewMode: FolderViewMode.root,
      currentTab: null,
      viewDirectory: current,
    );
    print('[SelectedFolderNotifier] switchToRoot: state updated');
    await persist();
    print('[SelectedFolderNotifier] switchToRoot END');
  }

  Future<void> switchToSubfolder(String name) async {
    print('[SelectedFolderNotifier] switchToSubfolder START: $name');
    final base = state.current;
    if (base == null) {
      print('[SelectedFolderNotifier] switchToSubfolder: base is null, returning');
      return;
    }
    final subfolder = Directory(p.join(base.path, name));

    print('[SelectedFolderNotifier] switchToSubfolder: '
        'name=$name, '
        'subfolder=${subfolder.path}, '
        'oldViewMode=${state.viewMode}, '
        'newViewMode=subfolder');

    state = state.copyWith(
      viewMode: FolderViewMode.subfolder,
      currentTab: name,
      viewDirectory: subfolder,
    );
    print('[SelectedFolderNotifier] switchToSubfolder: state updated');
    await persist();

    print('[SelectedFolderNotifier] switchToSubfolder END: $name');
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
    super.dispose();
  }
}
