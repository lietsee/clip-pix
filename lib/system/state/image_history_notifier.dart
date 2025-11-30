import 'dart:collection';

import 'package:state_notifier/state_notifier.dart';

import '../../data/models/image_entry.dart';
import 'image_history_state.dart';

/// 保存履歴を管理するNotifier
///
/// 最新5件の保存履歴を保持（アプリ終了でクリア、永続化なし）
class ImageHistoryNotifier extends StateNotifier<ImageHistoryState> {
  ImageHistoryNotifier() : super(ImageHistoryState.initial());

  static const _maxEntries = 5;

  void addEntry(ImageEntry entry) {
    final updated = ListQueue<ImageEntry>.from(state.entries)..addFirst(entry);
    while (updated.length > _maxEntries) {
      updated.removeLast();
    }
    state = state.copyWith(entries: updated);
  }

  void removeEntry(String filePath) {
    final updated = ListQueue<ImageEntry>.from(state.entries)
      ..removeWhere((entry) => entry.filePath == filePath);
    if (updated.length == state.entries.length) {
      return;
    }
    state = state.copyWith(entries: updated);
  }

  void clear() {
    state = ImageHistoryState.initial();
  }
}
