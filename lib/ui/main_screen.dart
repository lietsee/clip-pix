import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../data/file_info_manager.dart';
import '../data/grid_card_preferences_repository.dart';
import '../data/grid_layout_settings_repository.dart';
import '../data/models/grid_layout_settings.dart';
import '../data/models/image_entry.dart';
import '../data/models/image_source_type.dart';
import '../system/clipboard_monitor.dart';
import '../system/delete_service.dart';
import '../system/file_watcher.dart';
import '../system/folder_picker_service.dart';
import '../system/image_preview_process_manager.dart';
import '../system/text_preview_process_manager.dart';
import '../system/state/deletion_mode_notifier.dart';
import '../system/state/deletion_mode_state.dart';
import '../system/state/grid_layout_store.dart';
import '../system/state/image_history_state.dart';
import '../system/state/image_library_notifier.dart';
import '../system/state/image_library_state.dart';
import '../system/state/selected_folder_notifier.dart';
import '../system/state/folder_view_mode.dart';
import '../system/state/selected_folder_state.dart';
import '../system/state/watcher_status_notifier.dart';
import '../system/state/watcher_status_state.dart';
import '../system/text_saver.dart';
import 'package:path/path.dart' as p;
import 'grid_view_module.dart';
import 'widgets/grid_minimap_overlay.dart';
import 'widgets/grid_settings_dialog.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WindowListener {
  late ScrollController _rootScrollController;
  late final ScrollController _subfolderScrollController;
  String? _lastLoadedPath;
  String? _lastSyncedFolder; // Track last synced folder to prevent re-entry
  bool _isSyncing = false; // Re-entry guard for _ensureDirectorySync()
  bool _isRestoringRootScroll = false;
  bool _restoreScheduled = false;
  bool _needsRootScrollRestore = false;
  double? _pendingRootScrollOffset;
  String? _restoringForPath;
  final Set<String> _restoredRootScrollPaths = <String>{};
  bool _controllerLogScheduled = false;
  bool _clipboardMonitorEnabled = false;

  // Minimap overlay service
  MinimapOverlayService? _minimapService;

  late final FocusNode _keyboardFocusNode;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _rootScrollController = ScrollController();
    _subfolderScrollController = ScrollController();
    _keyboardFocusNode = FocusNode();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Call _ensureDirectorySync() here instead of in build() to prevent infinite rebuild loop
    final selectedState = context.watch<SelectedFolderState>();
    // Track viewDirectory (actual displayed directory) instead of current (root folder)
    // This ensures sync runs when switching between root and subfolders like .trash
    final currentPath = selectedState.viewDirectory?.path;

    debugPrint('[MainScreen] didChangeDependencies: '
        'viewDirectory=$currentPath, '
        'viewMode=${selectedState.viewMode}, '
        'currentTab=${selectedState.currentTab}, '
        '_lastSyncedFolder=$_lastSyncedFolder');

    // Only sync if folder has changed
    if (_lastSyncedFolder != currentPath) {
      debugPrint('[MainScreen] didChangeDependencies triggering sync: '
          'old=$_lastSyncedFolder → new=$currentPath');
      _lastSyncedFolder = currentPath;
      _ensureDirectorySync(context, selectedState);
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);

    // NOTE: Don't kill text preview processes here
    // Each TextPreviewWindow handles its own state saving via WindowListener.onWindowClose()
    // The parent's onWindowClose() below will handle cleanup when app exits

    _minimapService?.dispose();
    _keyboardFocusNode.dispose();
    _rootScrollController.dispose();
    _subfolderScrollController.dispose();
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    debugPrint('[MainScreen] onWindowClose called');

    // Ensure scroll position is persisted before closing
    final folderNotifier = context.read<SelectedFolderNotifier>();
    await folderNotifier.persist();

    // Kill all preview processes in parallel with timeout
    try {
      await Future.wait([
        _killTextPreviews(),
        _killImagePreviews(),
      ]).timeout(const Duration(milliseconds: 800));
      debugPrint('[MainScreen] All preview processes killed successfully');
    } catch (e) {
      debugPrint('[MainScreen] Timeout or error during process cleanup: $e');
    }

    // Allow window to close
    await windowManager.destroy();
  }

  Future<void> _killTextPreviews() async {
    try {
      final manager = context.read<TextPreviewProcessManager>();
      await manager.killAll(gracePeriod: const Duration(milliseconds: 300));
      debugPrint('[MainScreen] Killed all text preview processes');
    } catch (e) {
      debugPrint('[MainScreen] Error killing text preview processes: $e');
    }
  }

  Future<void> _killImagePreviews() async {
    try {
      final manager = context.read<ImagePreviewProcessManager>();
      await manager.killAll(gracePeriod: const Duration(milliseconds: 300));
      debugPrint('[MainScreen] Killed all image preview processes');
    } catch (e) {
      debugPrint('[MainScreen] Error killing image preview processes: $e');
    }
  }

  /// GridBackgroundToneから背景色を取得（GridViewModuleと同じロジック）
  Color _backgroundForTone(GridBackgroundTone tone) {
    switch (tone) {
      case GridBackgroundTone.white:
        return Colors.white;
      case GridBackgroundTone.lightGray:
        return const Color(0xFFC0C0C0);
      case GridBackgroundTone.darkGray:
        return const Color(0xFF2E2E2E);
      case GridBackgroundTone.black:
        return Colors.black;
    }
  }

  /// 背景色の明度に応じて前景色（テキスト・アイコン）を決定
  Color _foregroundForBackground(Color backgroundColor) {
    final hsl = HSLColor.fromColor(backgroundColor);
    // Lightness < 0.5 → 暗い背景 → 白文字/アイコン
    // Lightness >= 0.5 → 明るい背景 → 黒文字/アイコン
    return hsl.lightness < 0.5 ? Colors.white : Colors.black;
  }

  @override
  Widget build(BuildContext context) {
    final selectedState = context.watch<SelectedFolderState>();
    final watcherStatus = context.watch<WatcherStatusState>();
    final historyState = context.watch<ImageHistoryState>();
    final deletionMode = context.watch<DeletionModeState>();

    // GridLayoutSettingsを取得してAppBarの色を決定
    final settingsRepo = context.watch<GridLayoutSettingsRepository>();
    final settings = settingsRepo.value;
    final appBarBgColor = _backgroundForTone(settings.background);
    final appBarFgColor = _foregroundForBackground(appBarBgColor);

    // Use Selector to avoid rebuilding MainScreen on favorite changes
    // Only watch activeDirectory and images.isEmpty, not the entire state
    final libraryInfo = context.select<ImageLibraryState,
        ({Directory? activeDirectory, bool hasImages})>(
      (state) => (
        activeDirectory: state.activeDirectory,
        hasImages: state.images.isNotEmpty
      ),
    );

    // NOTE: _ensureDirectorySync() is now called in didChangeDependencies() instead of build()
    // to prevent infinite rebuild loop when switching tabs

    // Show minimap if always-visible mode is enabled
    if (selectedState.isMinimapAlwaysVisible &&
        selectedState.viewMode == FolderViewMode.root &&
        libraryInfo.hasImages) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Re-verify visibility on every build and re-show if invalidated
        if (_minimapService == null || !_minimapService!.isVisible) {
          _showMinimap(context, selectedState);
        }
      });
    }

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyM &&
            HardwareKeyboard.instance.isControlPressed) {
          _toggleMinimapAlwaysVisible(context);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: appBarBgColor,
          foregroundColor: appBarFgColor,
          iconTheme: IconThemeData(color: appBarFgColor),
          title: _Breadcrumb(selectedState: selectedState),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Tooltip(
                message:
                    _clipboardMonitorEnabled ? 'クリップボード監視を停止' : 'クリップボード監視を開始',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.content_paste, size: 20),
                    const SizedBox(width: 4),
                    Switch(
                      value: _clipboardMonitorEnabled,
                      onChanged: (value) {
                        _toggleClipboardMonitor(context, value);
                      },
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.note_add),
              tooltip: '新規テキスト作成',
              onPressed: libraryInfo.activeDirectory == null
                  ? null
                  : () => _createNewText(context),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '再読み込み',
              onPressed: libraryInfo.activeDirectory == null
                  ? null
                  : () => context.read<ImageLibraryNotifier>().refresh(),
            ),
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'フォルダを選択',
              onPressed: () => _requestFolderSelection(context),
            ),
            // 一括削除ボタン
            if (deletionMode.isActive) ...[
              if (deletionMode.hasSelection)
                Badge(
                  label: Text('${deletionMode.selectedCount}'),
                  child: IconButton(
                    icon: const Icon(Icons.delete),
                    tooltip: '削除',
                    onPressed: () => _handleBulkDelete(context),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.delete),
                  tooltip: '削除',
                  onPressed: null, // Disabled when no selection
                ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'キャンセル',
                onPressed: () =>
                    context.read<DeletionModeNotifier>().exitDeletionMode(),
              ),
            ] else
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '一括削除モード',
                onPressed: libraryInfo.hasImages
                    ? () =>
                        context.read<DeletionModeNotifier>().enterDeletionMode()
                    : null,
              ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'グリッド設定',
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => const GridSettingsDialog(),
                );
              },
            ),
          ],
        ),
        body: _buildBody(context, selectedState, historyState),
        bottomNavigationBar: watcherStatus.lastError != null
            ? _ErrorBanner(message: watcherStatus.lastError!)
            : null,
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SelectedFolderState folderState,
    ImageHistoryState historyState,
  ) {
    // Watch ImageLibraryState here instead of in build() to prevent
    // MainScreen rebuild on favorite changes (only _buildBody rebuilds)
    final libraryState = context.watch<ImageLibraryState>();

    // GridLayoutSettingsを取得してコンテンツエリアの色を決定
    final settingsRepo = context.watch<GridLayoutSettingsRepository>();
    final settings = settingsRepo.value;
    final contentBgColor = _backgroundForTone(settings.background);
    final contentFgColor = _foregroundForBackground(contentBgColor);

    // Handle scroll to top request from bulk size adjustment
    if (folderState.scrollToTopRequested &&
        folderState.viewMode == FolderViewMode.root) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_rootScrollController.hasClients) {
          _rootScrollController.animateTo(
            0.0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        context.read<SelectedFolderNotifier>().clearScrollToTopRequest();
      });
    }

    final directory = folderState.current;
    if (directory == null || !folderState.isValid) {
      return _EmptyState(
          onSelectFolder: () => _requestFolderSelection(context));
    }

    final tabs =
        _buildTabs(context, folderState, contentFgColor, contentBgColor);
    _prepareRootScrollRestoreIfNeeded(folderState);
    _maybeRestoreRootScroll(folderState);

    final columnWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabBar(
          tabs: tabs,
          controller: _subfolderScrollController,
          backgroundColor: contentBgColor,
          foregroundColor: contentFgColor,
        ),
        if (historyState.entries.isNotEmpty)
          _HistoryStrip(
            entries: historyState.entries.toList(),
            backgroundColor: contentBgColor,
            foregroundColor: contentFgColor,
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (_isRestoringRootScroll) {
                debugPrint(
                  '[ScrollDebug] notification ignored while restoring: '
                  'type=${notification.runtimeType} '
                  'pixels=${notification.metrics.pixels.toStringAsFixed(1)}',
                );
                return false;
              }
              if (notification.metrics.axis == Axis.vertical &&
                  folderState.viewMode == FolderViewMode.root) {
                final rootPath = folderState.current?.path;
                if (rootPath != null) {
                  _cancelPendingRootRestore(rootPath);
                }
                debugPrint(
                  '[ScrollDebug] notification received: '
                  'type=${notification.runtimeType} '
                  'pixels=${notification.metrics.pixels.toStringAsFixed(1)} '
                  'max=${notification.metrics.maxScrollExtent.toStringAsFixed(1)} '
                  'min=${notification.metrics.minScrollExtent.toStringAsFixed(1)}',
                );
                _scheduleControllerSnapshot();
                context
                    .read<SelectedFolderNotifier>()
                    .updateRootScroll(notification.metrics.pixels);
              }
              return false;
            },
            child: GridViewModule(
              state: libraryState,
              controller: folderState.viewMode == FolderViewMode.root
                  ? _rootScrollController
                  : null,
              enableGridSemantics: false,
            ),
          ),
        ),
      ],
    );

    return columnWidget;
  }

  List<_FolderTab> _buildTabs(
    BuildContext context,
    SelectedFolderState state,
    Color foregroundColor,
    Color backgroundColor,
  ) {
    final directory = state.current;
    if (directory == null) {
      return const <_FolderTab>[];
    }

    final imageLibrary = context.read<ImageLibraryNotifier>();

    final tabs = <_FolderTab>[
      _FolderTab(
        label: 'ルート',
        isActive: state.viewMode == FolderViewMode.root,
        foregroundColor: foregroundColor,
        backgroundColor: backgroundColor,
        onTap: () async {
          debugPrint('[MainScreen] Root tab clicked');
          await context.read<SelectedFolderNotifier>().switchToRoot();
        },
      ),
    ];

    final subdirs = directory
        .listSync(followLinks: false)
        .whereType<Directory>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final dir in subdirs) {
      final name = p.basename(dir.path);
      tabs.add(
        _FolderTab(
          label: name,
          isActive: state.viewMode == FolderViewMode.subfolder &&
              state.currentTab == name,
          foregroundColor: foregroundColor,
          backgroundColor: backgroundColor,
          onTap: () async {
            debugPrint('[MainScreen] Tab clicked: $name');
            await context
                .read<SelectedFolderNotifier>()
                .switchToSubfolder(name);
            debugPrint('[MainScreen] switchToSubfolder complete for: $name');
          },
        ),
      );
    }

    return tabs;
  }

  void _prepareRootScrollRestoreIfNeeded(SelectedFolderState state) {
    if (!mounted || state.viewMode != FolderViewMode.root) {
      _pendingRootScrollOffset = null;
      _needsRootScrollRestore = false;
      debugPrint(
        '[ScrollDebug] prepare skipped: mounted=$mounted '
        'viewMode=${state.viewMode} needs=$_needsRootScrollRestore',
      );
      return;
    }

    final path = state.current?.path;
    if (path == null) {
      debugPrint('[ScrollDebug] prepare aborted: current path is null');
      return;
    }

    if (_restoredRootScrollPaths.contains(path) &&
        _pendingRootScrollOffset == null) {
      debugPrint('[ScrollDebug] prepare skipped: already restored for $path');
      return;
    }

    _pendingRootScrollOffset ??= state.rootScrollOffset;
    _restoringForPath ??= path;
    _needsRootScrollRestore = true;
    debugPrint(
      '[ScrollDebug] prepare pending restore: path=$path '
      'target=${_pendingRootScrollOffset?.toStringAsFixed(1)}',
    );
  }

  void _maybeRestoreRootScroll(SelectedFolderState state) {
    if (!mounted || !_needsRootScrollRestore) {
      if (!mounted) {
        debugPrint('[ScrollDebug] restore skipped: widget not mounted');
      }
      return;
    }
    if (state.viewMode != FolderViewMode.root) {
      debugPrint(
        '[ScrollDebug] restore waiting: viewMode=${state.viewMode}',
      );
      return;
    }

    if (!_rootScrollController.hasClients) {
      debugPrint('[ScrollDebug] restore waiting: controller has no clients');
      _scheduleRootScrollCheck();
      return;
    }

    final pending = _pendingRootScrollOffset;
    final targetPath = _restoringForPath ?? state.current?.path;
    if (pending == null || targetPath == null) {
      _needsRootScrollRestore = false;
      debugPrint('[ScrollDebug] restore cancelled: pending/target missing');
      return;
    }

    final position = _rootScrollController.position;
    if (!position.hasContentDimensions) {
      debugPrint('[ScrollDebug] restore waiting: dimensions unavailable yet');
      _scheduleRootScrollCheck();
      return;
    }

    final clamped =
        pending.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((position.pixels - clamped).abs() < 0.5) {
      debugPrint(
        '[ScrollDebug] restore not needed: already near '
        '${clamped.toStringAsFixed(1)} for $targetPath',
      );
      _completeRootRestore(targetPath);
      return;
    }

    _isRestoringRootScroll = true;
    debugPrint(
      '[ScrollDebug] restore jumpTo: target=${clamped.toStringAsFixed(1)} '
      'current=${position.pixels.toStringAsFixed(1)} path=$targetPath',
    );
    _rootScrollController.jumpTo(clamped);
    _isRestoringRootScroll = false;
    _completeRootRestore(targetPath);
  }

  void _scheduleRootScrollCheck() {
    if (_restoreScheduled || !mounted) {
      return;
    }
    _restoreScheduled = true;
    debugPrint('[ScrollDebug] schedule restore check');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreScheduled = false;
      if (!mounted) {
        return;
      }
      final state = context.read<SelectedFolderState>();
      _maybeRestoreRootScroll(state);
    });
  }

  void _scheduleControllerSnapshot() {
    if (_controllerLogScheduled || !mounted) {
      return;
    }
    _controllerLogScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controllerLogScheduled = false;
      if (!mounted) {
        return;
      }
      if (!_rootScrollController.hasClients) {
        debugPrint('[ScrollDebug] controller snapshot skipped: no clients');
        return;
      }
      final position = _rootScrollController.position;
      debugPrint(
        '[ScrollDebug] controller snapshot: '
        'pixels=${position.pixels.toStringAsFixed(1)} '
        'min=${position.minScrollExtent.toStringAsFixed(1)} '
        'max=${position.maxScrollExtent.toStringAsFixed(1)} '
        'viewport=${position.viewportDimension.toStringAsFixed(1)} '
        'outOfRange=${position.outOfRange}',
      );
    });
  }

  void _cancelPendingRootRestore(String path) {
    if (!_needsRootScrollRestore) {
      return;
    }
    debugPrint('[ScrollDebug] cancel pending restore due to user scroll');
    _completeRootRestore(path);
  }

  void _completeRootRestore(String path) {
    _needsRootScrollRestore = false;
    _pendingRootScrollOffset = null;
    _restoringForPath = null;
    _restoredRootScrollPaths.add(path);
    debugPrint('[ScrollDebug] restore completed for $path');
  }

  Future<void> _toggleClipboardMonitor(
      BuildContext context, bool enabled) async {
    setState(() {
      _clipboardMonitorEnabled = enabled;
    });

    final monitor = context.read<ClipboardMonitor>();
    if (enabled) {
      await monitor.start();
    } else {
      await monitor.stop();
    }
  }

  Future<void> _createNewText(BuildContext context) async {
    final textSaver = context.read<TextSaver>();
    final imageLibrary = context.read<ImageLibraryNotifier>();

    try {
      final saveResult = await textSaver.saveTextData(
        '',
        sourceType: ImageSourceType.local,
      );

      if (saveResult.isSuccess && saveResult.filePath != null) {
        await imageLibrary.addOrUpdate(File(saveResult.filePath!));

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('新しいテキストファイルを作成しました')),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('作成失敗: ${saveResult.error}')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラー: $error')),
      );
    }
  }

  Future<void> _requestFolderSelection(BuildContext context) async {
    final picker = context.read<FolderPickerService>();
    final selectedNotifier = context.read<SelectedFolderNotifier>();
    final watcherStatus = context.read<WatcherStatusNotifier>();
    final fileWatcher = context.read<FileWatcherService>();
    final monitor = context.read<ClipboardMonitor>();
    final imageLibrary = context.read<ImageLibraryNotifier>();
    final currentPath = context.read<SelectedFolderState>().current?.path;

    final directory = await picker.pickFolder(initialDirectory: currentPath);
    if (directory == null) {
      return;
    }

    await selectedNotifier.setFolder(directory);
    final updatedState = context.read<SelectedFolderState>();
    if (!updatedState.isValid) {
      watcherStatus.setError('selected_directory_not_writable');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('フォルダに書き込めませんでした')),
      );
      return;
    }

    watcherStatus.clearError();
    _lastLoadedPath = directory.path;

    await imageLibrary.loadForDirectory(directory);
    await fileWatcher.start(directory);
    if (_clipboardMonitorEnabled) {
      await monitor.onFolderChanged(directory);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('フォルダを選択しました: ${directory.path}')),
    );
  }

  void _ensureDirectorySync(
    BuildContext context,
    SelectedFolderState selectedState,
  ) {
    debugPrint('[MainScreen] _ensureDirectorySync called: '
        'viewDirectory=${selectedState.viewDirectory?.path}, '
        'current=${selectedState.current?.path}, '
        'viewMode=${selectedState.viewMode}, '
        '_isSyncing=$_isSyncing, '
        '_lastSyncedFolder=$_lastSyncedFolder, '
        '_lastLoadedPath=$_lastLoadedPath');

    // Re-entry guard: prevent concurrent executions
    if (_isSyncing) {
      debugPrint('[MainScreen] _ensureDirectorySync skipped: already syncing');
      return;
    }

    // FIX BUG 2: Use viewDirectory (actual displayed folder) instead of current (root folder)
    // This ensures proper directory sync when switching between root and subfolders like .trash
    final directory = selectedState.viewDirectory ?? selectedState.current;

    if (directory == null || !selectedState.isValid) {
      if (_lastLoadedPath != null) {
        context.read<ImageLibraryNotifier>().clear();
        context.read<FileWatcherService>().stop();
        context.read<ClipboardMonitor>().stop();
        _lastLoadedPath = null;
      }
      // FIX BUG 1: Clear flag before early return to prevent permanent blocking
      _isSyncing = false;
      debugPrint('[MainScreen] _ensureDirectorySync: directory invalid, cleared flag');
      return;
    }

    final path = directory.path;
    if (_lastLoadedPath == path) {
      // FIX BUG 1: Clear flag before early return
      _isSyncing = false;
      debugPrint('[MainScreen] _ensureDirectorySync skipped: already loaded $path');
      return;
    }

    // Set syncing flag
    _isSyncing = true;
    debugPrint('[MainScreen] _ensureDirectorySync executing for: $path');

    // Dispose and recreate scroll controller when folder changes
    // to prevent multiple ScrollPosition attachment errors
    if (_rootScrollController.hasClients) {
      _rootScrollController.dispose();
      _rootScrollController = ScrollController();
    }

    _lastLoadedPath = path;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        debugPrint('[MainScreen] _ensureDirectorySync postFrameCallback start');
        final imageLibrary = context.read<ImageLibraryNotifier>();

        // FIX BUG 3: Don't call switchToRoot when viewing subfolder
        // This prevents incorrect state transitions when user is in .trash tab
        if (selectedState.viewMode == FolderViewMode.root) {
          context.read<SelectedFolderNotifier>().switchToRoot();
        }

        await imageLibrary.loadForDirectory(directory);
        await context.read<FileWatcherService>().start(directory);
        if (_clipboardMonitorEnabled) {
          await context.read<ClipboardMonitor>().onFolderChanged(directory);
        }
        debugPrint('[MainScreen] _ensureDirectorySync postFrameCallback complete');
      } catch (e, stack) {
        debugPrint('[MainScreen] _ensureDirectorySync error: $e\n$stack');
      } finally {
        // Clear syncing flag after completion
        _isSyncing = false;
        debugPrint('[MainScreen] _ensureDirectorySync flag cleared');
      }
    });
  }

  void _showMinimap(BuildContext context, SelectedFolderState folderState) {
    if (_minimapService?.isVisible == true) {
      return; // Already showing and mounted
    }

    // Clean up stale service if it exists but is not visible
    if (_minimapService != null && !_minimapService!.isVisible) {
      _minimapService!.dispose();
      _minimapService = null;
    }

    final layoutStore = context.read<GridLayoutStore>();

    _minimapService = MinimapOverlayService();
    _minimapService!.show(
      context: context,
      scrollController: _rootScrollController,
      layoutStore: layoutStore,
    );
  }

  void _hideMinimap() {
    _minimapService?.hide();
    _minimapService = null;
  }

  void _toggleMinimapAlwaysVisible(BuildContext context) {
    final notifier = context.read<SelectedFolderNotifier>();
    notifier.toggleMinimapAlwaysVisible();

    final selectedState = context.read<SelectedFolderState>();
    if (selectedState.isMinimapAlwaysVisible) {
      _showMinimap(context, selectedState);
    } else {
      _hideMinimap();
    }
  }

  /// Handle bulk deletion
  Future<void> _handleBulkDelete(BuildContext context) async {
    final deletionNotifier = context.read<DeletionModeNotifier>();
    final selectedIds = deletionNotifier.state.selectedCardIds.toList();

    if (selectedIds.isEmpty) {
      return;
    }

    final confirmed = await _showDeleteConfirmationDialog(
      context,
      count: selectedIds.length,
    );

    if (!confirmed) return;

    await _executeDelete(context, selectedIds);

    // Exit deletion mode after successful delete
    deletionNotifier.exitDeletionMode();
  }

  /// Show delete confirmation dialog
  Future<bool> _showDeleteConfirmationDialog(
    BuildContext context, {
    required int count,
    String? itemName,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除確認'),
        content: Text(
          itemName != null
              ? '$itemNameをゴミ箱に移動しますか？'
              : '選択した${count}件のアイテムをゴミ箱に移動しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  /// Execute deletion using DeleteService
  Future<void> _executeDelete(
      BuildContext context, List<String> itemPaths) async {
    final deletionNotifier = context.read<DeletionModeNotifier>();
    final libraryNotifier = context.read<ImageLibraryNotifier>();

    // Set deleting flag
    deletionNotifier.setDeleting(true);

    try {
      // Create DeleteService with dependencies
      final fileInfoManager =
          Provider.of<FileInfoManager>(context, listen: false);
      final preferencesRepo =
          Provider.of<GridCardPreferencesRepository>(context, listen: false);

      final deleteService = DeleteService(
        fileInfoManager: fileInfoManager,
        preferencesRepository: preferencesRepo,
      );

      // Execute deletion
      final result = await deleteService.deleteItems(itemPaths);

      // Remove successfully deleted items from ImageLibrary
      // Defer state updates to avoid setState during build
      SchedulerBinding.instance.addPostFrameCallback((_) {
        for (final path in result.successfulPaths) {
          libraryNotifier.remove(path);
        }
      });

      // Show result message
      if (!mounted) return;

      final message = result.hasFailures
          ? '${result.successCount}件削除しました（${result.failureCount}件失敗）'
          : '${result.successCount}件削除しました';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('削除に失敗しました: $error'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      deletionNotifier.setDeleting(false);
    }
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.selectedState});

  final SelectedFolderState selectedState;

  @override
  Widget build(BuildContext context) {
    final directory = selectedState.viewDirectory ?? selectedState.current;
    if (directory == null) {
      return const Text('ClipPix');
    }
    final segments = directory.path.split(Platform.pathSeparator);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++)
          if (segments[i].isNotEmpty) ...[
            InkWell(
              onTap: () => _openInExplorer(directory.path),
              child: Text(segments[i]),
            ),
            if (i < segments.length - 1)
              const Icon(Icons.chevron_right, size: 16),
          ],
      ],
    );
  }

  void _openInExplorer(String path) {
    if (!Platform.isWindows) {
      return;
    }
    Process.run('explorer.exe', ['/select,', path]);
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.controller,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final List<_FolderTab> tabs;
  final ScrollController controller;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      height: 48,
      child: ListView.builder(
        controller: controller,
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        itemBuilder: (context, index) => tabs[index],
      ),
    );
  }
}

class _FolderTab extends StatelessWidget {
  const _FolderTab({
    required this.label,
    required this.isActive,
    required this.onTap,
    required this.foregroundColor,
    required this.backgroundColor,
  });

  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final Color foregroundColor;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(color: foregroundColor),
        ),
        selected: isActive,
        onSelected: (_) => onTap(),
        selectedColor: backgroundColor,
        backgroundColor: backgroundColor,
        checkmarkColor: foregroundColor,
        elevation: 0,
        side: BorderSide(color: foregroundColor, width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: foregroundColor, width: 1),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSelectFolder});

  final VoidCallback onSelectFolder;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.collections, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('クリップボード画像を保存するフォルダを選択してください'),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onSelectFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('フォルダを選択'),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        width: double.infinity,
        color: Theme.of(context).colorScheme.error,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          message,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onError),
        ),
      ),
    );
  }
}

class _HistoryStrip extends StatelessWidget {
  const _HistoryStrip({
    required this.entries,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final List<ImageEntry> entries;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      height: 80,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return Chip(
            backgroundColor: backgroundColor,
            label: Text(
              File(entry.filePath).uri.pathSegments.last,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: foregroundColor),
            ),
            avatar: Icon(Icons.image, size: 18, color: foregroundColor),
            elevation: 0,
            side: BorderSide(color: foregroundColor, width: 1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: foregroundColor, width: 1),
            ),
          );
        },
      ),
    );
  }
}
