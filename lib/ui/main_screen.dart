import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models/image_entry.dart';
import '../system/clipboard_monitor.dart';
import '../system/file_watcher.dart';
import '../system/folder_picker_service.dart';
import '../system/state/image_history_state.dart';
import '../system/state/image_library_notifier.dart';
import '../system/state/image_library_state.dart';
import '../system/state/selected_folder_notifier.dart';
import '../system/state/selected_folder_state.dart';
import '../system/state/watcher_status_notifier.dart';
import '../system/state/watcher_status_state.dart';
import 'grid_view_module.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  String? _lastLoadedPath;

  @override
  Widget build(BuildContext context) {
    final selectedState = context.watch<SelectedFolderState>();
    final watcherStatus = context.watch<WatcherStatusState>();
    final historyState = context.watch<ImageHistoryState>();
    final libraryState = context.watch<ImageLibraryState>();

    _ensureDirectorySync(context, selectedState);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ClipPix'),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _requestFolderSelection(context),
        icon: const Icon(Icons.folder),
        label: const Text('フォルダを選択'),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: _buildBody(context, selectedState, libraryState, historyState),
      ),
      bottomNavigationBar: watcherStatus.lastError != null
          ? _ErrorBanner(message: watcherStatus.lastError!)
          : null,
    );
  }

  Widget _buildBody(
    BuildContext context,
    SelectedFolderState folderState,
    ImageLibraryState libraryState,
    ImageHistoryState historyState,
  ) {
    final directory = folderState.current;
    if (directory == null || !folderState.isValid) {
      return _EmptyState(
          onSelectFolder: () => _requestFolderSelection(context));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '選択フォルダ: ${directory.path}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (historyState.entries.isNotEmpty) ...[
          _HistoryStrip(entries: historyState.entries.toList()),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: GridViewModule(state: libraryState),
        ),
      ],
    );
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
      await imageLibrary.loadForDirectory(directory);
      await context.read<FileWatcherService>().start(directory);
      await context.read<ClipboardMonitor>().onFolderChanged(directory);
    });
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
