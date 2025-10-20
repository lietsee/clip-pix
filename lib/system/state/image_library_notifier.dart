import 'dart:io';

import 'package:logging/logging.dart';
import 'package:state_notifier/state_notifier.dart';

import '../../data/image_repository.dart';
import '../../data/models/image_item.dart';
import 'image_library_state.dart';

class ImageLibraryNotifier extends StateNotifier<ImageLibraryState> {
  ImageLibraryNotifier(this._repository, {Logger? logger})
      : _logger = logger ?? Logger('ImageLibraryNotifier'),
        super(ImageLibraryState.initial());

  final ImageRepository _repository;
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
    final updated = <ImageItem>[...state.images];
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

  void setError(String message) {
    state = state.copyWith(error: message);
  }

  void clear() {
    state = ImageLibraryState.initial();
  }
}
