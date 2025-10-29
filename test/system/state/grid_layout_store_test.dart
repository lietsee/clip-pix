import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:clip_pix/data/models/content_item.dart';
import 'package:clip_pix/data/models/image_item.dart';

/// テスト対象予定の GridLayoutStore を事前に import。
import 'package:clip_pix/system/state/grid_layout_store.dart';

class _FakeGridLayoutPersistence implements GridLayoutPersistence {
  _FakeGridLayoutPersistence({
    Map<String, GridLayoutPreferenceRecord>? seed,
  }) : _store = {...?seed};

  final Map<String, GridLayoutPreferenceRecord> _store;
  final List<List<GridLayoutPreferenceRecord>> recordedBatches = [];

  @override
  GridLayoutPreferenceRecord read(String id) {
    return _store.putIfAbsent(
      id,
      () => GridLayoutPreferenceRecord(
        id: id,
        width: GridLayoutPreferenceRecord.defaultWidth,
        height: GridLayoutPreferenceRecord.defaultHeight,
        scale: GridLayoutPreferenceRecord.defaultScale,
        columnSpan: GridLayoutPreferenceRecord.defaultColumnSpan,
        customHeight: null,
      ),
    );
  }

  @override
  Future<void> saveBatch(List<GridLayoutPreferenceRecord> mutations) async {
    recordedBatches.add(List.of(mutations));
    for (final mutation in mutations) {
      _store[mutation.id] = mutation;
    }
  }
}

class _FakeAspectRatioResolver implements GridIntrinsicRatioResolver {
  _FakeAspectRatioResolver(this.ratios);

  final Map<String, double> ratios;

  @override
  Future<double?> resolve(String id, ContentItem? item) async => ratios[id];
}

void main() {
  group('GridLayoutStore', () {
    late _FakeGridLayoutPersistence persistence;
    late GridLayoutStore store;
    late List<ContentItem> library;

    setUp(() {
      persistence = _FakeGridLayoutPersistence(seed: {
        'a': GridLayoutPreferenceRecord(
          id: 'a',
          width: 220,
          height: 320,
          scale: 1.1,
          columnSpan: 2,
          customHeight: 320,
        ),
      });
      store = GridLayoutStore(
        persistence: persistence,
        ratioResolver: _FakeAspectRatioResolver({
          'a': 1.45,
          'b': 1.0,
          'c': 0.75,
        }),
      );
      library = [
        ImageItem(id: 'a', filePath: 'a.png'),
        ImageItem(id: 'b', filePath: 'b.png'),
        ImageItem(id: 'c', filePath: 'c.png'),
      ];
      store.syncLibrary(library, directoryPath: '/pictures');
    });

    test('初期同期で preferences をもとにビュー状態を生成する', () {
      final a = store.viewStateFor('a');
      expect(a.width, 220);
      expect(a.height, 320);
      expect(a.columnSpan, 2);
      expect(a.scale, 1.1);

      final b = store.viewStateFor('b');
      expect(b.width, GridLayoutPreferenceRecord.defaultWidth);
      expect(b.height, GridLayoutPreferenceRecord.defaultHeight);
      expect(b.columnSpan, GridLayoutPreferenceRecord.defaultColumnSpan);
      expect(b.scale, GridLayoutPreferenceRecord.defaultScale);
    });

    test('applyBulkSpan は単一通知で完了し、永続化バッチも 1 回で済む', () async {
      store.updateGeometry(
        const GridLayoutGeometry(
          columnCount: 6,
          columnWidth: 180,
          gap: 3,
        ),
        notify: false,
      );
      var notifications = 0;
      store.addListener(() {
        notifications += 1;
      });

      await store.applyBulkSpan(span: 3);

      expect(notifications, 1);
      expect(store.viewStateFor('b').columnSpan, 3);
      expect(store.viewStateFor('b').width, 180 * 3 + 3 * 2);
      expect(persistence.recordedBatches, hasLength(1));
      expect(persistence.recordedBatches.single, hasLength(3));
      final recordIds = persistence.recordedBatches.single.map((r) => r.id);
      expect(recordIds, containsAll(['a', 'b', 'c']));
    });

    test('スナップショットを round trip で適用できる', () async {
      final snapshot = store.captureSnapshot();

      store.updateGeometry(
        const GridLayoutGeometry(
          columnCount: 6,
          columnWidth: 180,
          gap: 3,
        ),
        notify: false,
      );
      await store.applyBulkSpan(span: 4);
      expect(store.viewStateFor('a').columnSpan, 4);

      var notifications = 0;
      store.addListener(() {
        notifications += 1;
      });

      await store.restoreSnapshot(snapshot);

      expect(store.viewStateFor('a').columnSpan, 2);
      expect(store.viewStateFor('a').width, 220);
      expect(store.viewStateFor('a').height, 320);
      expect(notifications, 1);
    });

    test('カード単位更新でもバッチ永続化される', () async {
      await store.updateCard(
        id: 'b',
        customSize: const Size(400, 260),
        scale: 0.9,
      );

      expect(store.viewStateFor('b').width, 400);
      expect(store.viewStateFor('b').height, 260);
      expect(store.viewStateFor('b').scale, 0.9);
      expect(persistence.recordedBatches, hasLength(1));
      expect(persistence.recordedBatches.single.single.id, 'b');
    });

    test('updateGeometry で列数変化に追従する', () async {
      store.updateGeometry(
        const GridLayoutGeometry(columnCount: 3, columnWidth: 120, gap: 3),
        notify: false,
      );
      store.updateGeometry(
        const GridLayoutGeometry(columnCount: 1, columnWidth: 90, gap: 3),
        notify: true,
      );

      final updated = store.viewStateFor('a');
      expect(updated.columnSpan, 1);
      expect(updated.width, closeTo(90, 0.0001));
      expect(updated.height, closeTo(90 * (320 / 220), 0.5));
    });

    test('updateGeometry 実行で最新スナップショットが生成される', () {
      expect(store.latestSnapshot, isNull);

      store.updateGeometry(
        const GridLayoutGeometry(columnCount: 3, columnWidth: 120, gap: 4),
        notify: true,
      );

      final snapshot = store.latestSnapshot;
      expect(snapshot, isNotNull);
      expect(snapshot!.geometry.columnCount, 3);
      expect(snapshot.entries, hasLength(3));
      final firstEntry = snapshot.entries.firstWhere((e) => e.id == 'a');
      expect(firstEntry.columnSpan, store.viewStateFor('a').columnSpan);
    });

    test('カード更新後はスナップショットが無効化される', () async {
      store.updateGeometry(
        const GridLayoutGeometry(columnCount: 3, columnWidth: 120, gap: 4),
        notify: true,
      );
      expect(store.latestSnapshot, isNotNull);

      await store.updateCard(
        id: 'b',
        customSize: const Size(320, 200),
      );

      expect(store.latestSnapshot, isNull);
    });
  });
}
