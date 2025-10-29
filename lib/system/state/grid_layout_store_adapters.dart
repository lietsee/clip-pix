import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import '../../data/grid_card_preferences_repository.dart';
import '../../data/models/content_item.dart';
import '../../data/models/grid_card_pref.dart';
import '../../data/models/image_item.dart';
import 'grid_layout_store.dart';

class GridLayoutHivePersistence implements GridLayoutPersistence {
  GridLayoutHivePersistence(this._repository);

  final GridCardPreferencesRepository _repository;

  @override
  GridLayoutPreferenceRecord read(String id) {
    final pref = _repository.getOrCreate(id);
    return GridLayoutPreferenceRecord(
      id: pref.id,
      width: pref.width,
      height: pref.height,
      scale: pref.scale,
      columnSpan: pref.columnSpan,
      customHeight: pref.customHeight,
    );
  }

  @override
  Future<void> saveBatch(List<GridLayoutPreferenceRecord> mutations) async {
    if (mutations.isEmpty) {
      return;
    }
    final prefs = mutations.map(
      (mutation) => GridCardPreference(
        id: mutation.id,
        width: mutation.width,
        height: mutation.height,
        scale: mutation.scale,
        columnSpan: mutation.columnSpan,
        customHeight: mutation.customHeight,
      ),
    );
    await _repository.saveAll(prefs);
  }
}

class FileImageRatioResolver implements GridIntrinsicRatioResolver {
  final Map<String, ui.Size> _cache = {};
  final Map<String, Future<double?>> _pending = {};

  @override
  Future<double?> resolve(String id, ContentItem? item) {
    final cached = _cache[id];
    if (cached != null && cached.width > 0 && cached.height > 0) {
      return Future.value(cached.height / cached.width);
    }
    if (item == null || item.filePath.isEmpty) {
      return Future.value(null);
    }
    // Only process ImageItem (not TextContentItem)
    if (item is! ImageItem) {
      return Future.value(null);
    }
    return _pending[id] ??= _loadRatio(id, item);
  }

  Future<double?> _loadRatio(String id, ImageItem item) async {
    ui.Codec? codec;
    try {
      final file = File(item.filePath);
      if (!await file.exists()) {
        return null;
      }
      final bytes = await file.readAsBytes();
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final size = ui.Size(
        image.width.toDouble(),
        image.height.toDouble(),
      );
      image.dispose();
      _cache[id] = size;
      if (size.width <= 0 || size.height <= 0) {
        return null;
      }
      return size.height / size.width;
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
      _pending.remove(id);
    }
  }
}
