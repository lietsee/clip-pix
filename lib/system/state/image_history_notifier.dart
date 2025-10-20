import 'dart:collection';

import 'package:hive/hive.dart';
import 'package:logging/logging.dart';
import 'package:state_notifier/state_notifier.dart';

import '../../data/models/image_entry.dart';
import '../../data/models/image_source_type.dart';
import 'image_history_state.dart';

class ImageHistoryNotifier extends StateNotifier<ImageHistoryState> {
  ImageHistoryNotifier(this._box)
      : _logger = Logger('ImageHistoryNotifier'),
        super(ImageHistoryState.initial()) {
    _restore();
  }

  final Box<dynamic> _box;
  final Logger _logger;

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

  void _restore() {
    final stored = _box.get(_storageKey);
    if (stored is List) {
      try {
        final restored = ListQueue<ImageEntry>();
        for (final raw in stored) {
          if (raw is Map) {
            final map = raw.cast<String, dynamic>();
            restored.add(ImageEntry(
              filePath: map['filePath'] as String,
              metadataPath: map['metadataPath'] as String,
              sourceType: imageSourceTypeFromString(
                  map['sourceType'] as String? ?? 'unknown'),
              savedAt: DateTime.tryParse(map['savedAt'] as String? ?? '') ??
                  DateTime.now().toUtc(),
            ));
          }
        }
        state = state.copyWith(entries: restored);
      } catch (error, stackTrace) {
        _logger.warning('Failed to restore image history', error, stackTrace);
      }
    }
  }
}
