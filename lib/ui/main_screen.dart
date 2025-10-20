import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../system/state/selected_folder_state.dart';
import '../system/state/watcher_status_state.dart';
import 'grid_view_module.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final selectedState = context.watch<SelectedFolderState>();
    final watcherStatus = context.watch<WatcherStatusState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('ClipPix'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: () => _requestFolderSelection(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _requestFolderSelection(context),
        icon: const Icon(Icons.folder),
        label: const Text('フォルダを選択'),
      ),
      body: _buildBody(context, selectedState),
      bottomNavigationBar: watcherStatus.lastError != null
          ? _ErrorBanner(message: watcherStatus.lastError!)
          : null,
    );
  }

  Widget _buildBody(BuildContext context, SelectedFolderState state) {
    if (state.current == null || !state.isValid) {
      return _EmptyState(
          onSelectFolder: () => _requestFolderSelection(context));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '選択フォルダ: ${state.current!.path}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const Expanded(
          child: GridViewModule(),
        ),
      ],
    );
  }

  void _requestFolderSelection(BuildContext context) {
    // TODO: integrate folder picker service.
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('フォルダ選択ダイアログは未実装です')),
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
