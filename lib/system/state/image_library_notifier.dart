import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:state_notifier/state_notifier.dart';

import '../../data/file_info_manager.dart';
import '../../data/grid_order_repository.dart';
import '../../data/image_repository.dart';
import '../../data/models/content_item.dart';
import 'image_library_state.dart';

class ImageLibraryNotifier extends StateNotifier<ImageLibraryState> {
  ImageLibraryNotifier(
    this._repository, {
    FileInfoManager? fileInfoManager,
    GridOrderRepository? orderRepository,
    Logger? logger,
  })  : _fileInfoManager = fileInfoManager,
        _orderRepository = orderRepository,
        _logger = logger ?? Logger('ImageLibraryNotifier'),
        super(ImageLibraryState.initial());

  final ImageRepository _repository;
  final FileInfoManager? _fileInfoManager;
  final GridOrderRepository? _orderRepository;
  final Logger _logger;
  Future<void>? _loadingTask;

  Future<void> loadForDirectory(Directory directory) async {
    final previousDirectory = state.activeDirectory;
    state = state.copyWith(
      activeDirectory: directory,
      isLoading: true,
      clearError: true,
    );

    final task = _repository.loadForDirectory(directory);
    _loadingTask = task;

    final images = await task;
    if (_loadingTask != task) {
      // Another load has been requested, discard this result.
      return;
    }

    // Apply Hive DB order
    final orderedImages = _applyDirectoryOrder(images, directory.path);

    state = state.copyWith(
      images: orderedImages,
      isLoading: false,
      clearError: true,
      activeDirectory: directory,
    );

    if (previousDirectory != null && previousDirectory.path != directory.path) {
      _logger.info('Image library reloaded for ${directory.path}');
    }
  }

  Future<void> refresh() async {
    final directory = state.activeDirectory;
    if (directory == null) {
      return;
    }
    await loadForDirectory(directory);
  }

  Future<void> addOrUpdate(File file) async {
    final directory = state.activeDirectory;
    if (directory == null) {
      return;
    }

    // Skip files in hidden folders (e.g., .trash, .config)
    // Check if any path segment starts with '.'
    final pathSegments = p.split(file.path);
    if (pathSegments.any((segment) => segment.startsWith('.'))) {
      _logger.fine('Skipping file in hidden folder: ${file.path}');
      return;
    }

    final item = await _repository.addOrUpdate(file);
    if (item == null) {
      return;
    }
    final updated = <ContentItem>[...state.images];
    final index =
        updated.indexWhere((existing) => existing.filePath == item.filePath);
    if (index >= 0) {
      updated[index] = item;
    } else {
      updated.insert(0, item);
    }
    // Apply Hive DB order (new item added, need to reorder)
    final orderedUpdated = _applyDirectoryOrder(updated, directory.path);
    state = state.copyWith(images: orderedUpdated, clearError: true);
  }

  void remove(String path) {
    final updated =
        state.images.where((item) => item.filePath != path).toList();
    if (updated.length == state.images.length) {
      return;
    }
    state = state.copyWith(images: updated, clearError: true);
  }

  Future<void> updateMemo(String imageId, String memo) async {
    final fileInfoManager = _fileInfoManager;
    if (fileInfoManager == null) {
      _logger.warning('FileInfoManager not available for memo update');
      return;
    }

    // Find the image item by ID
    final index = state.images.indexWhere((item) => item.id == imageId);
    if (index < 0) {
      _logger.warning('Image not found for memo update: $imageId');
      return;
    }

    final item = state.images[index];

    try {
      // Update memo in FileInfoManager
      await fileInfoManager.updateMemo(
        imageFilePath: item.filePath,
        memo: memo,
        savedAt: item.savedAt,
        source: item.source ?? 'Unknown',
        sourceType: item.sourceType,
      );

      // Update in-memory state
      final updated = <ContentItem>[...state.images];
      updated[index] = item.copyWith(memo: memo);
      state = state.copyWith(images: updated, clearError: true);

      _logger.info('Memo updated for ${item.filePath}');
    } catch (error, stackTrace) {
      _logger.severe('Failed to update memo', error, stackTrace);
      setError('メモの更新に失敗しました');
    }
  }

  Future<void> updateFavorite(String imageId, int favorite) async {
    final fileInfoManager = _fileInfoManager;
    if (fileInfoManager == null) {
      _logger.warning('FileInfoManager not available for favorite update');
      return;
    }

    // Find the image item by ID
    final index = state.images.indexWhere((item) => item.id == imageId);
    if (index < 0) {
      _logger.warning('Image not found for favorite update: $imageId');
      return;
    }

    final item = state.images[index];

    try {
      // Update favorite in FileInfoManager
      await fileInfoManager.updateFavorite(
        imageFilePath: item.filePath,
        favorite: favorite,
        savedAt: item.savedAt,
        source: item.source ?? 'Unknown',
        sourceType: item.sourceType,
      );

      // Update in-memory state
      final updated = <ContentItem>[...state.images];
      updated[index] = item.copyWith(favorite: favorite);
      state = state.copyWith(images: updated, clearError: true);

      _logger.info('Favorite updated for ${item.filePath}');
    } catch (error, stackTrace) {
      _logger.severe('Failed to update favorite', error, stackTrace);
      setError('お気に入りの更新に失敗しました');
    }
  }

  void setError(String message) {
    state = state.copyWith(error: message);
  }

  void clear() {
    state = ImageLibraryState.initial();
  }

  /// Reorder images by the given list of IDs.
  /// Called from GridViewModule after drag&drop to sync order.
  void reorderImages(List<String> orderedIds) {
    final map = {for (final item in state.images) item.id: item};
    final reordered = <ContentItem>[];
    for (final id in orderedIds) {
      final item = map[id];
      if (item != null) {
        reordered.add(item);
      }
    }
    state = state.copyWith(images: reordered);
  }

  /// Apply directory order from GridOrderRepository (Hive DB)
  List<ContentItem> _applyDirectoryOrder(
    List<ContentItem> items,
    String directoryPath,
  ) {
    final repo = _orderRepository;
    if (repo == null) {
      return items;
    }

    final stored = repo.getOrder(directoryPath);
    if (items.isEmpty) {
      return items;
    }

    final ids = items.map((item) => item.id).toList();
    final currentSet = ids.toSet();
    final orderedIds = <String>[];

    // Apply stored order
    for (final id in stored) {
      if (currentSet.contains(id)) {
        orderedIds.add(id);
      }
    }

    // Add new items not in stored order
    for (final id in ids) {
      if (!orderedIds.contains(id)) {
        orderedIds.add(id);
      }
    }

    // Save updated order if changed
    if (!listEquals(stored, orderedIds)) {
      scheduleMicrotask(() => repo.save(directoryPath, orderedIds));
    }

    // Create ordered list
    final map = {for (final item in items) item.id: item};
    final orderedItems = <ContentItem>[];
    for (final id in orderedIds) {
      final item = map[id];
      if (item != null) {
        orderedItems.add(item);
      }
    }
    return orderedItems;
  }
}
