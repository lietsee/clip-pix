import 'dart:async';

import 'grid_layout_store.dart';
import 'grid_resize_controller.dart';

class GridResizeStoreBinding {
  GridResizeStoreBinding({
    required GridResizeController controller,
    required GridLayoutCommandTarget store,
  })  : _controller = controller,
        _store = store {
    _controller.attach(_handleCommand);
  }

  final GridResizeController _controller;
  final GridLayoutCommandTarget _store;

  Future<GridResizeSnapshot?> _handleCommand(
    GridResizeCommand command,
  ) async {
    switch (command.type) {
      case GridResizeCommandType.apply:
        if (command.span == null) {
          return null;
        }
        final before = _store.captureSnapshot();
        await _store.applyBulkSpan(span: command.span!);
        return _convertSnapshot(before);
      case GridResizeCommandType.undo:
        final redoBase = _store.captureSnapshot();
        final snapshot = command.snapshot;
        if (snapshot != null) {
          await _store.restoreSnapshot(_convertToLayout(snapshot));
        }
        return _convertSnapshot(redoBase);
      case GridResizeCommandType.redo:
        final redoSnapshot = command.snapshot;
        if (redoSnapshot == null) {
          return null;
        }
        final undoBase = _store.captureSnapshot();
        await _store.restoreSnapshot(_convertToLayout(redoSnapshot));
        return _convertSnapshot(undoBase);
    }
  }

  GridResizeSnapshot _convertSnapshot(GridLayoutSnapshot snapshot) {
    return GridResizeSnapshot(
      directoryPath: snapshot.directoryPath,
      values: snapshot.values.map(
        (key, value) => MapEntry(
          key,
          GridCardSizeSnapshot(
            width: value.width,
            height: value.height,
            columnSpan: value.columnSpan,
            customHeight: value.customHeight,
            scale: value.scale,
          ),
        ),
      ),
    );
  }

  GridLayoutSnapshot _convertToLayout(GridResizeSnapshot snapshot) {
    return GridLayoutSnapshot(
      directoryPath: snapshot.directoryPath,
      values: snapshot.values.map(
        (key, value) => MapEntry(
          key,
          GridCardSnapshot(
            width: value.width,
            height: value.height,
            scale: value.scale,
            columnSpan: value.columnSpan,
            customHeight: value.customHeight,
          ),
        ),
      ),
    );
  }
}
