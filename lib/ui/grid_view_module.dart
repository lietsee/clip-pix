import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../data/models/image_item.dart';
import '../system/clipboard_copy_service.dart';
import '../system/state/image_library_notifier.dart';
import '../system/state/image_library_state.dart';
import 'image_card.dart';

class GridViewModule extends StatelessWidget {
  const GridViewModule({super.key, required this.state});

  final ImageLibraryState state;

  @override
  Widget build(BuildContext context) {
    if (state.isLoading && state.images.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.images.isEmpty) {
      return const Center(child: Text('フォルダ内に画像がありません'));
    }

    final copyService = context.read<ClipboardCopyService>();
    final libraryNotifier = context.read<ImageLibraryNotifier>();

    return RefreshIndicator(
      onRefresh: () => libraryNotifier.refresh(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount = _calculateCrossAxisCount(constraints.maxWidth);
          return MasonryGridView.count(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: state.images.length,
            itemBuilder: (context, index) {
              final item = state.images[index];
              return ImageCard(
                item: item,
                onCopy: () async {
                  try {
                    await copyService.copyImage(item);
                    _showSnackBar(context, 'クリップボードにコピーしました');
                  } catch (error) {
                    _showSnackBar(context, 'コピーに失敗しました');
                  }
                },
                onOpenPreview: () {
                  _showPreviewDialog(context, item);
                },
              );
            },
          );
        },
      ),
    );
  }

  int _calculateCrossAxisCount(double width) {
    if (width <= 900) {
      return 2;
    }
    if (width <= 1400) {
      return 3;
    }
    return 4;
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showPreviewDialog(BuildContext context, ImageItem item) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: InteractiveViewer(
          child: Image.file(
            File(item.filePath),
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
