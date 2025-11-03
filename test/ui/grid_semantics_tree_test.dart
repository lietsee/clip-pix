import 'package:clip_pix/system/grid_layout_layout_engine.dart' as layout;
import 'package:clip_pix/system/state/grid_layout_store.dart';
import 'package:clip_pix/ui/widgets/grid_semantics_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GridSemanticsTree', () {
    testWidgets('セマンティクスにカードIDが含まれる', (tester) async {
      final snapshot = layout.LayoutSnapshot(
        id: 'snapshot_1',
        geometry: const GridLayoutGeometry(
          columnCount: 2,
          columnWidth: 120,
          gap: 4,
        ),
        entries: [
          layout.LayoutSnapshotEntry(
            id: 'card-1',
            rect: const Rect.fromLTWH(0, 0, 120, 140),
            columnSpan: 1,
          ),
          layout.LayoutSnapshotEntry(
            id: 'card-2',
            rect: const Rect.fromLTWH(124, 0, 120, 160),
            columnSpan: 1,
          ),
        ],
      );

      final semanticsHandle = tester.ensureSemantics();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: GridSemanticsTree(
            snapshot: snapshot,
            textDirection: TextDirection.ltr,
          ),
        ),
      );

      final node = tester.getSemantics(find.byType(GridSemanticsTree));
      expect(
        node,
        matchesSemantics(
          label: '画像グリッド',
          children: <Matcher>[
            matchesSemantics(label: 'card-1', isFocusable: true),
            matchesSemantics(label: 'card-2', isFocusable: true),
          ],
        ),
      );

      semanticsHandle.dispose();
    });

    testWidgets('スナップショット更新でセマンティクスが差し替わる', (tester) async {
      final semanticsHandle = tester.ensureSemantics();

      layout.LayoutSnapshot buildSnapshot(String id, String cardLabel) {
        return layout.LayoutSnapshot(
          id: id,
          geometry: const GridLayoutGeometry(
            columnCount: 1,
            columnWidth: 120,
            gap: 4,
          ),
          entries: [
            layout.LayoutSnapshotEntry(
              id: cardLabel,
              rect: const Rect.fromLTWH(0, 0, 120, 140),
              columnSpan: 1,
            ),
          ],
        );
      }

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: GridSemanticsTree(
            snapshot: buildSnapshot('snap-1', 'card-old'),
            textDirection: TextDirection.ltr,
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byType(GridSemanticsTree)),
        matchesSemantics(
          label: '画像グリッド',
          children: <Matcher>[
            matchesSemantics(label: 'card-old', isFocusable: true),
          ],
        ),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: GridSemanticsTree(
            snapshot: buildSnapshot('snap-2', 'card-new'),
            textDirection: TextDirection.ltr,
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byType(GridSemanticsTree)),
        matchesSemantics(
          label: '画像グリッド',
          children: <Matcher>[
            matchesSemantics(label: 'card-new', isFocusable: true),
          ],
        ),
      );

      semanticsHandle.dispose();
    });
  });
}
