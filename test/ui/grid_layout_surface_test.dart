import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clip_pix/system/grid_layout_layout_engine.dart' as layout;
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
                childBuilder: (context, geometry, states, snapshot,
                    {bool isStaging = false}) {
                  return Text('items=${states.length}');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 10));
      await tester.idle();
      await tester.pump();

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
              childBuilder: (context, geometry, states, snapshot,
                  {bool isStaging = false}) {
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
      await tester.pumpAndSettle(const Duration(milliseconds: 10));

      expect(buildCount, greaterThanOrEqualTo(2));
    });
  });
}

class _WidgetFakeGridLayoutStore extends ChangeNotifier
    implements GridLayoutSurfaceStore {
  int updateGeometryCalls = 0;
  GridLayoutGeometry? lastGeometry;
  final List<GridLayoutGeometry> geometryHistory = <GridLayoutGeometry>[];
  List<GridCardViewState> _states = const [];
  layout.LayoutSnapshot? _latestSnapshot;

  void trigger(List<GridCardViewState> newStates) {
    _states = List<GridCardViewState>.unmodifiable(newStates);
    _latestSnapshot = null;
    notifyListeners();
  }

  @override
  List<GridCardViewState> get viewStates =>
      List<GridCardViewState>.unmodifiable(_states);

  @override
  layout.LayoutSnapshot? get latestSnapshot => _latestSnapshot;

  @override
  void updateGeometry(GridLayoutGeometry geometry, {bool notify = true}) {
    updateGeometryCalls += 1;
    lastGeometry = geometry;
    geometryHistory.add(geometry);
    final entries = <layout.LayoutSnapshotEntry>[];
    double offsetY = 0;
    for (final state in _states) {
      final rect = Rect.fromLTWH(0, offsetY, state.width, state.height);
      entries.add(
        layout.LayoutSnapshotEntry(
          id: state.id,
          rect: rect,
          columnSpan: state.columnSpan,
        ),
      );
      offsetY += state.height;
    }
    _latestSnapshot = layout.LayoutSnapshot(
      id: 'fake_${updateGeometryCalls}',
      geometry: geometry,
      entries: entries,
    );
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
