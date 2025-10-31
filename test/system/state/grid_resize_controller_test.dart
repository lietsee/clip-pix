import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clip_pix/system/state/grid_layout_mutation_controller.dart';
import 'package:clip_pix/system/state/grid_resize_controller.dart';
import 'package:clip_pix/system/state/grid_layout_store.dart';
import 'package:clip_pix/system/state/grid_resize_store_binding.dart';

void main() {
  group('GridResizeController × GridLayoutStore binding', () {
    testWidgets('applyBulkSpan はストアへ委譲し undo スタックを構成する', (tester) async {
      final controller = GridResizeController();
      final store = _FakeGridLayoutStore();
      final mutationController = GridLayoutMutationController()
        ..debugLoggingEnabled = true;
      GridResizeStoreBinding(
        controller: controller,
        store: store,
        mutationController: mutationController,
      );

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
      await tester.pumpAndSettle();
      await tester.pump();

      expect(store.appliedSpans, [3]);
      expect(controller.canUndo, isTrue);
      expect(
        mutationController.debugBeginCount - mutationController.debugEndCount,
        0,
      );
      expect(mutationController.debugBeginCount, 1);
    });

    testWidgets('undo はストアのスナップショットを復元し redo 用スナップショットを積む', (tester) async {
      final controller = GridResizeController();
      final store = _FakeGridLayoutStore();
      final mutationController = GridLayoutMutationController();
      GridResizeStoreBinding(
        controller: controller,
        store: store,
        mutationController: mutationController,
      );

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
      final initialBegin = mutationController.debugBeginCount;
      final initialEnd = mutationController.debugEndCount;

      await controller.applyBulkSpan(2);
      await tester.pumpAndSettle();
      await tester.pump();

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
      await tester.pumpAndSettle();
      await tester.pump();

      expect(store.restoreCalls, hasLength(1));
      final restored = store.restoreCalls.single.values['a'];
      expect(restored?.columnSpan, 1);
      expect(restored?.width, 200);
      expect(controller.canRedo, isTrue);
      expect(mutationController.debugBeginCount - initialBegin, 2);
      expect(mutationController.debugEndCount - initialEnd, 2);
      expect(mutationController.isMutating, isFalse);
    });

    testWidgets('redo は undo で得たスナップショットを再適用する', (tester) async {
      final controller = GridResizeController();
      final store = _FakeGridLayoutStore();
      final mutationController = GridLayoutMutationController();
      GridResizeStoreBinding(
        controller: controller,
        store: store,
        mutationController: mutationController,
      );

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
      final initialBegin = mutationController.debugBeginCount;
      final initialEnd = mutationController.debugEndCount;

      await controller.applyBulkSpan(2);
      await tester.pumpAndSettle();
      await tester.pump();

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
      await tester.pumpAndSettle();
      await tester.pump();

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
      await tester.pumpAndSettle();
      await tester.pump();

      expect(store.restoreCalls, hasLength(2));
      final redoSnapshot = store.restoreCalls.last.values['a'];
      expect(redoSnapshot?.columnSpan, 2);
      expect(redoSnapshot?.width, 320);
      expect(mutationController.debugBeginCount - initialBegin, 3);
      expect(mutationController.debugEndCount - initialEnd, 3);
      expect(mutationController.isMutating, isFalse);
    });

    testWidgets('各コマンドで begin/end が 1 回ずつ呼ばれる', (tester) async {
      final controller = GridResizeController();
      final store = _FakeGridLayoutStore();
      final mutationController = GridLayoutMutationController();
      GridResizeStoreBinding(
        controller: controller,
        store: store,
        mutationController: mutationController,
      );

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

      await controller.applyBulkSpan(4);
      await tester.pump();

      expect(mutationController.debugBeginCount, 1);
      expect(mutationController.debugEndCount, 1);

      store.captureResponses.add(
        GridLayoutSnapshot(
          directoryPath: '/pictures',
          values: {
            'a': GridCardSnapshot(
              width: 280,
              height: 200,
              scale: 1.0,
              columnSpan: 4,
              customHeight: null,
            ),
          },
        ),
      );

      await controller.undo();
      await tester.pump();

      expect(mutationController.debugBeginCount, 2);
      expect(mutationController.debugEndCount, 2);

      store.captureResponses.add(
        GridLayoutSnapshot(
          directoryPath: '/pictures',
          values: {
            'a': GridCardSnapshot(
              width: 280,
              height: 200,
              scale: 1.0,
              columnSpan: 4,
              customHeight: null,
            ),
          },
        ),
      );

      await controller.redo();
      await tester.pump();

      expect(mutationController.debugBeginCount, 3);
      expect(mutationController.debugEndCount, 3);
      expect(mutationController.isMutating, isFalse);
    });
  });
}

class _FakeGridLayoutStore implements GridLayoutCommandTarget {
  final Queue<GridLayoutSnapshot> captureResponses =
      Queue<GridLayoutSnapshot>();
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
