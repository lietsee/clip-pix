import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../system/grid_layout_layout_engine.dart' as layout;

class GridSemanticsTree extends LeafRenderObjectWidget {
  const GridSemanticsTree({
    super.key,
    required this.snapshot,
    required this.textDirection,
  });

  final layout.LayoutSnapshot snapshot;
  final TextDirection textDirection;

  @override
  RenderGridSemantics createRenderObject(BuildContext context) {
    return RenderGridSemantics(
      snapshot: snapshot,
      textDirection: textDirection,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderGridSemantics renderObject,
  ) {
    renderObject
      ..snapshot = snapshot
      ..textDirection = textDirection;
  }
}

class RenderGridSemantics extends RenderBox {
  RenderGridSemantics({
    required layout.LayoutSnapshot snapshot,
    required TextDirection textDirection,
  })  : _snapshot = snapshot,
        _textDirection = textDirection;

  layout.LayoutSnapshot _snapshot;
  TextDirection _textDirection;

  set snapshot(layout.LayoutSnapshot value) {
    if (identical(value, _snapshot)) {
      return;
    }
    _snapshot = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  set textDirection(TextDirection value) {
    if (_textDirection == value) {
      return;
    }
    _textDirection = value;
    markNeedsSemanticsUpdate();
  }

  @override
  bool get sizedByParent => false;

  @override
  void performLayout() {
    final geometry = _snapshot.geometry;
    final width = geometry.columnWidth * geometry.columnCount +
        geometry.gap * math.max(0, geometry.columnCount - 1);
    final height = _computeSnapshotHeight(_snapshot);
    size = constraints.constrain(Size(width, height));
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..textDirection = _textDirection
      ..label = '画像グリッド';
  }

  @override
  void assembleSemanticsNode(
    SemanticsNode node,
    SemanticsConfiguration config,
    Iterable<SemanticsNode> children,
  ) {
    final List<SemanticsNode> assembled = <SemanticsNode>[];
    for (final entry in _snapshot.entries) {
      final childConfig = SemanticsConfiguration()
        ..textDirection = _textDirection
        ..isFocusable = true
        ..label = entry.id;
      final childNode = SemanticsNode();
      childNode.updateWith(
        config: childConfig,
        childrenInInversePaintOrder: const <SemanticsNode>[],
      );
      childNode.rect = entry.rect;
      assembled.add(childNode);
    }

    node.rect = Offset.zero & size;
    node.updateWith(
      config: config,
      childrenInInversePaintOrder: assembled,
    );
  }

  double _computeSnapshotHeight(layout.LayoutSnapshot snapshot) {
    var maxBottom = 0.0;
    for (final entry in snapshot.entries) {
      maxBottom = math.max(maxBottom, entry.rect.bottom);
    }
    if (snapshot.entries.isEmpty) {
      return snapshot.geometry.columnWidth;
    }
    return maxBottom;
  }
}
