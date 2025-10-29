import 'dart:io';

import 'package:logging/logging.dart';
import 'package:state_notifier/state_notifier.dart';

import '../../data/file_info_manager.dart';
import '../../data/image_repository.dart';
import '../../data/models/content_item.dart';
import 'image_library_state.dart';

class ImageLibraryNotifier extends StateNotifier<ImageLibraryState> {
  ImageLibraryNotifier(
    this._repository, {
    FileInfoManager? fileInfoManager,
    Logger? logger,
  })  : _fileInfoManager = fileInfoManager,
        _logger = logger ?? Logger('ImageLibraryNotifier'),
        super(ImageLibraryState.initial());

  final ImageRepository _repository;
  final FileInfoManager? _fileInfoManager;
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

    state = state.copyWith(
      images: images,
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
    state = state.copyWith(images: updated, clearError: true);
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
    if (_fileInfoManager == null) {
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
      await _fileInfoManager!.updateMemo(
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
    if (_fileInfoManager == null) {
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
      await _fileInfoManager!.updateFavorite(
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
}
