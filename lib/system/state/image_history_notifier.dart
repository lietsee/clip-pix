import 'dart:collection';

import 'package:hive/hive.dart';
import 'package:state_notifier/state_notifier.dart';

import '../../data/models/image_entry.dart';
import '../../data/models/image_source_type.dart';
import 'image_history_state.dart';

class ImageHistoryNotifier extends StateNotifier<ImageHistoryState> {
  ImageHistoryNotifier(this._box) : super(ImageHistoryState.initial());

  final Box<dynamic> _box;
  static const _storageKey = 'image_history';
  static const _maxEntries = 20;

  void addEntry(ImageEntry entry) {
    final updated = ListQueue<ImageEntry>.from(state.entries)..addFirst(entry);
    while (updated.length > _maxEntries) {
      updated.removeLast();
    }
    state = state.copyWith(entries: updated);
    _persist();
  }

  void removeEntry(String filePath) {
    final updated = ListQueue<ImageEntry>.from(state.entries)
      ..removeWhere((entry) => entry.filePath == filePath);
    if (updated.length == state.entries.length) {
      return;
    }
    state = state.copyWith(entries: updated);
    _persist();
  }

  void clear() {
    state = ImageHistoryState.initial();
    _persist();
  }

  void _persist() {
    final serialized = state.entries
        .map(
          (entry) => <String, dynamic>{
            'filePath': entry.filePath,
            'metadataPath': entry.metadataPath,
            'sourceType': imageSourceTypeToString(entry.sourceType),
            'savedAt': entry.savedAt.toUtc().toIso8601String(),
          },
        )
        .toList(growable: false);
    _box.put(_storageKey, serialized);
  }
}
