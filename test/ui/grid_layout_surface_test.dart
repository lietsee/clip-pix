import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clip_pix/system/state/grid_layout_store.dart';
import 'package:clip_pix/ui/widgets/grid_layout_surface.dart';

void main() {
  group('GridLayoutSurface', () {
    testWidgets('レイアウト制約に応じて store.updateGeometry を呼び出す', (tester) async {
      final store = _WidgetFakeGridLayoutStore();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: GridLayoutSurface(
                store: store,
                columnGap: 3,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                resolveColumnCount: (_) => 2,
                childBuilder: (context, geometry, states) {
                  return Text('items=${states.length}');
                },
              ),
            ),
          ),
        ),
      );

      expect(store.updateGeometryCalls, greaterThanOrEqualTo(1));
      final geometry = store.lastGeometry;
      expect(geometry, isNotNull);
      expect(geometry!.gap, equals(3));
      expect(geometry.columnCount, greaterThanOrEqualTo(1));
      expect(geometry.columnWidth, greaterThanOrEqualTo(0));
  });

  testWidgets('store の通知で childBuilder が再評価される', (tester) async {
    final store = _WidgetFakeGridLayoutStore();
    var buildCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GridLayoutSurface(
              store: store,
              columnGap: 4,
              padding: EdgeInsets.zero,
              resolveColumnCount: (_) => 1,
              childBuilder: (context, geometry, states) {
                buildCount += 1;
                return Text('build=$buildCount');
              },
            ),
          ),
        ),
      );

      expect(buildCount, 1);

      store.trigger([
        GridCardViewState(
          id: 'a',
          width: 200,
          height: 200,
          scale: 1,
          columnSpan: 1,
          customHeight: null,
        ),
      ]);
      await tester.pump();

      expect(buildCount, 2);
    });

    testWidgets('列数が変化したときだけ mutate コールバックが呼ばれる',
        (tester) async {
      final store = _WidgetFakeGridLayoutStore();
      store.trigger([
        GridCardViewState(
          id: 'a',
          width: 200,
          height: 200,
          scale: 1,
          columnSpan: 1,
          customHeight: null,
        ),
      ]);

      final width = ValueNotifier<double>(600);
      int mutateStartCount = 0;
      int mutateEndCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<double>(
            valueListenable: width,
            builder: (context, currentWidth, _) {
              return Scaffold(
                body: Center(
                  child: SizedBox(
                    width: currentWidth,
                    child: GridLayoutSurface(
                      store: store,
                      columnGap: 4,
                      padding: EdgeInsets.zero,
                      resolveColumnCount: (available) =>
                          available >= 400 ? 3 : 1,
                      onMutateStart: () => mutateStartCount += 1,
                      onMutateEnd: () => mutateEndCount += 1,
                      childBuilder: (context, geometry, states) {
                        return Text(
                          'cols=${geometry.columnCount}',
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(store.lastGeometry?.columnCount, 3);
      final initialStart = mutateStartCount;
      final initialEnd = mutateEndCount;

      width.value = 500; // 列数は依然 3
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mutateStartCount, 1);
      expect(mutateEndCount, 1);

      width.value = 200; // 列数が 1 に変化
      await tester.pumpAndSettle();
      final lastColumnCount = store.lastGeometry?.columnCount;
      expect(lastColumnCount, 1);
      expect(mutateStartCount, greaterThan(initialStart));
      expect(mutateEndCount, greaterThanOrEqualTo(initialEnd));
    });
  });
}

class _WidgetFakeGridLayoutStore extends ChangeNotifier
    implements GridLayoutSurfaceStore {
  int updateGeometryCalls = 0;
  GridLayoutGeometry? lastGeometry;
  List<GridCardViewState> _states = const [];

  void trigger(List<GridCardViewState> newStates) {
    _states = List<GridCardViewState>.unmodifiable(newStates);
    notifyListeners();
  }

  @override
  List<GridCardViewState> get viewStates =>
      List<GridCardViewState>.unmodifiable(_states);

  @override
  void updateGeometry(GridLayoutGeometry geometry, {bool notify = true}) {
    updateGeometryCalls += 1;
    lastGeometry = geometry;
  }

  @override
  Future<void> applyBulkSpan({required int span}) async {
    throw UnimplementedError();
  }

  @override
  GridLayoutSnapshot captureSnapshot() {
    throw UnimplementedError();
  }

  @override
  Future<void> restoreSnapshot(GridLayoutSnapshot snapshot) async {
    throw UnimplementedError();
  }
}
