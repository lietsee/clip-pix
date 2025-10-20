import 'dart:collection';

import '../../data/models/image_entry.dart';

class ImageHistoryState {
  ImageHistoryState({
    required ListQueue<ImageEntry> entries,
  }) : entries = ListQueue<ImageEntry>.from(entries);

  factory ImageHistoryState.initial() => ImageHistoryState(
        entries: ListQueue<ImageEntry>(),
      );

  final ListQueue<ImageEntry> entries;

  ImageHistoryState copyWith({ListQueue<ImageEntry>? entries}) {
    return ImageHistoryState(
      entries: entries ?? ListQueue<ImageEntry>.from(this.entries),
    );
  }
}
