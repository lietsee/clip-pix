import 'package:clip_pix/system/grid_layout_layout_engine.dart';
import 'package:clip_pix/system/state/grid_layout_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GridLayoutLayoutEngine', () {
    late GridLayoutLayoutEngine engine;
    late GridLayoutGeometry geometry;

    setUp(() {
      engine = GridLayoutLayoutEngine();
      geometry = const GridLayoutGeometry(
        columnCount: 3,
        columnWidth: 120,
        gap: 8,
      );
    });

    test('列幅に合わせてビュー状態を再計算し、スナップショットを生成する', () {
      final states = [
        GridCardViewState(
          id: 'a',
          width: 180,
          height: 240,
          scale: 1.0,
          columnSpan: 2,
          customHeight: 240,
        ),
        GridCardViewState(
          id: 'b',
          width: 120,
          height: 180,
          scale: 1.0,
          columnSpan: 1,
          customHeight: 180,
        ),
      ];

      final result = engine.compute(
        geometry: geometry,
        states: states,
      );

      expect(result.viewStates, hasLength(2));
      expect(result.viewStates.first.width, closeTo(248, 0.0001));
      expect(result.viewStates.first.height, closeTo(330.6666, 0.0001));
      expect(result.viewStates.first.columnSpan, 2);

      expect(result.snapshot.entries, hasLength(2));
      final firstEntry = result.snapshot.entries.first;
      expect(firstEntry.id, 'a');
      expect(firstEntry.rect.width, closeTo(248, 0.0001));
      expect(firstEntry.rect.left, 0);
      final secondEntry = result.snapshot.entries[1];
      expect(secondEntry.rect.left, closeTo(256, 0.0001));
      expect(secondEntry.rect.top, 0);
      expect(result.changed, isTrue);
    });

    test('スナップショットIDが連番で発行される', () {
      final states = [
        GridCardViewState(
          id: 'a',
          width: 120,
          height: 180,
          scale: 1.0,
          columnSpan: 1,
          customHeight: 180,
        ),
      ];

      final first = engine.compute(geometry: geometry, states: states);
      final second = engine.compute(geometry: geometry, states: states);

      expect(first.snapshot.id, isNot(equals(second.snapshot.id)));
    });
  });
}
