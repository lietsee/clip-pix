import 'dart:ui';

import 'package:flutter/semantics.dart';

import '../../system/state/grid_layout_store.dart';

/// Serializable representation of the grid semantics tree.
class GridSemanticsBundle {
  GridSemanticsBundle({
    required this.geometry,
    required this.entries,
  });

  final GridLayoutGeometry geometry;
  final List<GridSemanticsEntry> entries;
}

/// Serializable representation of a single card semantics node.
class GridSemanticsEntry {
  GridSemanticsEntry({
    required this.id,
    required this.rect,
    required this.label,
    required this.flags,
  });

  final String id;
  final Rect rect;
  final String label;
  final Set<SemanticsFlag> flags;
}

/// Utility for building [GridSemanticsBundle] from the current view state.
class GridSemanticsBuilder {
  GridSemanticsBundle build({
    required GridLayoutGeometry geometry,
    required List<GridCardViewState> states,
  }) {
    final entries = <GridSemanticsEntry>[];
    final cardWidth = geometry.columnWidth;
    final gap = geometry.gap;
    double x = 0;
    double y = 0;
    var index = 0;
    for (final state in states) {
      final rect = Rect.fromLTWH(x, y, state.width, state.height);
      entries.add(
        GridSemanticsEntry(
          id: state.id,
          rect: rect,
          label: 'カード ${index + 1}',
          flags: {SemanticsFlag.isEnabled, SemanticsFlag.isFocusable},
        ),
      );
      x += state.width + gap;
      if (x + cardWidth > geometry.columnWidth * geometry.columnCount) {
        x = 0;
        y += state.height + gap;
      }
      index += 1;
    }
    return GridSemanticsBundle(
      geometry: geometry,
      entries: entries,
    );
  }
}
