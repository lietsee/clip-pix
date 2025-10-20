import 'dart:io';

import '../../data/models/image_item.dart';

class ImageLibraryState {
  const ImageLibraryState({
    required this.activeDirectory,
    required this.images,
    required this.isLoading,
    required this.error,
  });

  factory ImageLibraryState.initial() => const ImageLibraryState(
        activeDirectory: null,
        images: <ImageItem>[],
        isLoading: false,
        error: null,
      );

  final Directory? activeDirectory;
  final List<ImageItem> images;
  final bool isLoading;
  final String? error;

  ImageLibraryState copyWith({
    Directory? activeDirectory,
    List<ImageItem>? images,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return ImageLibraryState(
      activeDirectory: activeDirectory ?? this.activeDirectory,
      images: images ?? this.images,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
