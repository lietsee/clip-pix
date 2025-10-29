import 'dart:io';

import '../../data/models/content_item.dart';

class ImageLibraryState {
  const ImageLibraryState({
    required this.activeDirectory,
    required this.images,
    required this.isLoading,
    required this.error,
  });

  factory ImageLibraryState.initial() => const ImageLibraryState(
        activeDirectory: null,
        images: <ContentItem>[],
        isLoading: false,
        error: null,
      );

  final Directory? activeDirectory;
  final List<ContentItem> images;
  final bool isLoading;
  final String? error;

  ImageLibraryState copyWith({
    Directory? activeDirectory,
    List<ContentItem>? images,
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
