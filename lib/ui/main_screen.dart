import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../data/models/image_entry.dart';
import '../system/clipboard_monitor.dart';
import '../system/file_watcher.dart';
import '../system/folder_picker_service.dart';
import '../system/state/image_history_state.dart';
import '../system/state/image_library_notifier.dart';
import '../system/state/image_library_state.dart';
import '../system/state/selected_folder_notifier.dart';
import '../system/state/folder_view_mode.dart';
import '../system/state/selected_folder_state.dart';
import '../system/state/watcher_status_notifier.dart';
import '../system/state/watcher_status_state.dart';
import 'package:path/path.dart' as p;
import 'grid_view_module.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late final ScrollController _rootScrollController;
  late final ScrollController _subfolderScrollController;
  String? _lastLoadedPath;

  @override
  void initState() {
    super.initState();
    _rootScrollController = ScrollController();
    _subfolderScrollController = ScrollController();
  }

  @override
  void dispose() {
    _rootScrollController.dispose();
    _subfolderScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedState = context.watch<SelectedFolderState>();
    final watcherStatus = context.watch<WatcherStatusState>();
    final historyState = context.watch<ImageHistoryState>();
    final libraryState = context.watch<ImageLibraryState>();

    _ensureDirectorySync(context, selectedState);

    return Scaffold(
      appBar: AppBar(
        title: _Breadcrumb(selectedState: selectedState),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
            onPressed: libraryState.activeDirectory == null
                ? null
                : () => context.read<ImageLibraryNotifier>().refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'フォルダを選択',
            onPressed: () => _requestFolderSelection(context),
          ),
        ],
      ),
      body: _buildBody(context, selectedState, historyState, libraryState),
      bottomNavigationBar: watcherStatus.lastError != null
          ? _ErrorBanner(message: watcherStatus.lastError!)
          : null,
    );
  }

  Widget _buildBody(
    BuildContext context,
    SelectedFolderState folderState,
    ImageHistoryState historyState,
    ImageLibraryState libraryState,
  ) {
    final directory = folderState.current;
    if (directory == null || !folderState.isValid) {
      return _EmptyState(
          onSelectFolder: () => _requestFolderSelection(context));
    }

    final tabs = _buildTabs(context, folderState);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabBar(tabs: tabs, controller: _subfolderScrollController),
        if (historyState.entries.isNotEmpty)
          _HistoryStrip(entries: historyState.entries.toList()),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.vertical &&
                  folderState.viewMode == FolderViewMode.root) {
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
            ),
          ),
        ),
      ],
    );
  }

  List<_FolderTab> _buildTabs(
    BuildContext context,
    SelectedFolderState state,
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
        onTap: () async {
          await context.read<SelectedFolderNotifier>().switchToRoot();
          final rootDir = state.current;
          if (rootDir != null) {
            await imageLibrary.loadForDirectory(rootDir);
          }
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
          onTap: () async {
            await context
                .read<SelectedFolderNotifier>()
                .switchToSubfolder(name);
            await imageLibrary.loadForDirectory(dir);
          },
        ),
      );
    }

    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (state.viewMode == FolderViewMode.root) {
        final offset = state.rootScrollOffset;
        if (_rootScrollController.hasClients) {
          _rootScrollController.jumpTo(offset);
        }
      }
    });

    return tabs;
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
    await monitor.onFolderChanged(directory);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('フォルダを選択しました: ${directory.path}')),
    );
  }

  void _ensureDirectorySync(
    BuildContext context,
    SelectedFolderState selectedState,
  ) {
    final directory = selectedState.current;
    if (directory == null || !selectedState.isValid) {
      if (_lastLoadedPath != null) {
        context.read<ImageLibraryNotifier>().clear();
        context.read<FileWatcherService>().stop();
        context.read<ClipboardMonitor>().stop();
        _lastLoadedPath = null;
      }
      return;
    }

    final path = directory.path;
    if (_lastLoadedPath == path) {
      return;
    }
    _lastLoadedPath = path;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final imageLibrary = context.read<ImageLibraryNotifier>();
      context.read<SelectedFolderNotifier>().switchToRoot();
      await imageLibrary.loadForDirectory(directory);
      await context.read<FileWatcherService>().start(directory);
      await context.read<ClipboardMonitor>().onFolderChanged(directory);
    });
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
  const _TabBar({required this.tabs, required this.controller});

  final List<_FolderTab> tabs;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
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
  });

  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: isActive,
        onSelected: (_) => onTap(),
        selectedColor: theme.colorScheme.primaryContainer,
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
  const _HistoryStrip({required this.entries});

  final List<ImageEntry> entries;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return Chip(
            label: Text(
              File(entry.filePath).uri.pathSegments.last,
              overflow: TextOverflow.ellipsis,
            ),
            avatar: const Icon(Icons.image, size: 18),
          );
        },
      ),
    );
  }
}
