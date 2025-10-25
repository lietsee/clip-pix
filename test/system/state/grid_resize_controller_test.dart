import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';

import 'package:clip_pix/system/state/grid_resize_controller.dart';
import 'package:clip_pix/system/state/grid_layout_store.dart';
import 'package:clip_pix/system/state/grid_resize_store_binding.dart';

void main() {
  group('GridResizeController × GridLayoutStore binding', () {
    late GridResizeController controller;
    late _FakeGridLayoutStore store;
    setUp(() {
      controller = GridResizeController();
      store = _FakeGridLayoutStore();
      GridResizeStoreBinding(controller: controller, store: store);
    });

    test('applyBulkSpan はストアへ委譲し undo スタックを構成する', () async {
      store.captureResponses.add(
        GridLayoutSnapshot(
          directoryPath: '/pictures',
          values: {
            'a': GridCardSnapshot(
              width: 200,
              height: 200,
              scale: 1.0,
              columnSpan: 1,
              customHeight: null,
            ),
          },
        ),
      );

      await controller.applyBulkSpan(3);

      expect(store.appliedSpans, [3]);
      expect(controller.canUndo, isTrue);
    });

    test('undo はストアのスナップショットを復元し redo 用スナップショットを積む', () async {
      store.captureResponses.add(
        GridLayoutSnapshot(
          directoryPath: '/pictures',
          values: {
            'a': GridCardSnapshot(
              width: 200,
              height: 200,
              scale: 1.0,
              columnSpan: 1,
              customHeight: null,
            ),
          },
        ),
      );
      await controller.applyBulkSpan(2);

      store.captureResponses.add(
        GridLayoutSnapshot(
          directoryPath: '/pictures',
          values: {
            'a': GridCardSnapshot(
              width: 320,
              height: 240,
              scale: 1.0,
              columnSpan: 2,
              customHeight: 240,
            ),
          },
        ),
      );

      await controller.undo();

      expect(store.restoreCalls, hasLength(1));
      final restored = store.restoreCalls.single.values['a'];
      expect(restored?.columnSpan, 1);
      expect(restored?.width, 200);
      expect(controller.canRedo, isTrue);
    });

    test('redo は undo で得たスナップショットを再適用する', () async {
      store.captureResponses.add(
        GridLayoutSnapshot(
          directoryPath: '/pictures',
          values: {
            'a': GridCardSnapshot(
              width: 200,
              height: 200,
              scale: 1.0,
              columnSpan: 1,
              customHeight: null,
            ),
          },
        ),
      );
      await controller.applyBulkSpan(2);

      store.captureResponses.add(
        GridLayoutSnapshot(
          directoryPath: '/pictures',
          values: {
            'a': GridCardSnapshot(
              width: 320,
              height: 240,
              scale: 1.0,
              columnSpan: 2,
              customHeight: 240,
            ),
          },
        ),
      );
      await controller.undo();

      store.captureResponses.add(
        GridLayoutSnapshot(
          directoryPath: '/pictures',
          values: {
            'a': GridCardSnapshot(
              width: 200,
              height: 200,
              scale: 1.0,
              columnSpan: 1,
              customHeight: null,
            ),
          },
        ),
      );

      await controller.redo();

      expect(store.restoreCalls, hasLength(2));
      final redoSnapshot = store.restoreCalls.last.values['a'];
      expect(redoSnapshot?.columnSpan, 2);
      expect(redoSnapshot?.width, 320);
    });
  });
}

class _FakeGridLayoutStore implements GridLayoutCommandTarget {
  final Queue<GridLayoutSnapshot> captureResponses = Queue<GridLayoutSnapshot>();
  final List<int> appliedSpans = [];
  final List<GridLayoutSnapshot> restoreCalls = [];

  @override
  Future<void> applyBulkSpan({required int span}) async {
    appliedSpans.add(span);
  }

  @override
  GridLayoutSnapshot captureSnapshot() {
    if (captureResponses.isEmpty) {
      throw StateError('captureSnapshot called without prepared response');
    }
    return captureResponses.removeFirst();
  }

  @override
  Future<void> restoreSnapshot(GridLayoutSnapshot snapshot) async {
    restoreCalls.add(snapshot);
  }
}
