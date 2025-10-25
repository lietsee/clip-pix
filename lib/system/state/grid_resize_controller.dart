import 'package:flutter/foundation.dart';

enum GridResizeCommandType { apply, undo, redo }

class GridResizeCommand {
  GridResizeCommand.apply(this.span)
      : type = GridResizeCommandType.apply,
        snapshot = null;

  GridResizeCommand._(this.type, this.snapshot) : span = null;

  factory GridResizeCommand.undo(GridResizeSnapshot snapshot) {
    return GridResizeCommand._(GridResizeCommandType.undo, snapshot);
  }

  factory GridResizeCommand.redo(GridResizeSnapshot snapshot) {
    return GridResizeCommand._(GridResizeCommandType.redo, snapshot);
  }

  final GridResizeCommandType type;
  final int? span;
  final GridResizeSnapshot? snapshot;
}

class GridResizeSnapshot {
  GridResizeSnapshot({
    required this.directoryPath,
    required this.values,
  });

  final String? directoryPath;
  final Map<String, GridCardSizeSnapshot> values;
}

class GridCardSizeSnapshot {
  GridCardSizeSnapshot({
    required this.width,
    required this.height,
    required this.columnSpan,
    required this.customHeight,
    required this.scale,
  });

  final double width;
  final double height;
  final int columnSpan;
  final double? customHeight;
  final double scale;
}

typedef GridResizeListener = Future<GridResizeSnapshot?> Function(
  GridResizeCommand command,
);

class GridResizeController extends ChangeNotifier {
  GridResizeListener? _listener;
  final List<GridResizeSnapshot> _undoStack = <GridResizeSnapshot>[];
  final List<GridResizeSnapshot> _redoStack = <GridResizeSnapshot>[];

  GridResizeListener? get listener => _listener;

  void attach(GridResizeListener listener) {
    _listener = listener;
  }

  void detach(GridResizeListener listener) {
    if (_listener == listener) {
      _listener = null;
    }
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  Future<void> applyBulkSpan(int span) async {
    final listener = _listener;
    if (listener == null) {
      return;
    }
    final snapshot = await listener(GridResizeCommand.apply(span));
    if (snapshot != null) {
      _undoStack.add(snapshot);
      if (_undoStack.length > 3) {
        _undoStack.removeAt(0);
      }
      _redoStack.clear();
      notifyListeners();
    }
  }

  Future<void> undo() async {
    if (_undoStack.isEmpty) {
      return;
    }
    final listener = _listener;
    if (listener == null) {
      return;
    }
    final snapshot = _undoStack.removeLast();
    final redoSnapshot = await listener(GridResizeCommand.undo(snapshot));
    if (redoSnapshot != null) {
      _redoStack.add(redoSnapshot);
      if (_redoStack.length > 3) {
        _redoStack.removeAt(0);
      }
      notifyListeners();
    } else {
      notifyListeners();
    }
  }

  Future<void> redo() async {
    if (_redoStack.isEmpty) {
      return;
    }
    final listener = _listener;
    if (listener == null) {
      return;
    }
    final snapshot = _redoStack.removeLast();
    final undoSnapshot = await listener(GridResizeCommand.redo(snapshot));
    if (undoSnapshot != null) {
      _undoStack.add(undoSnapshot);
      if (_undoStack.length > 3) {
        _undoStack.removeAt(0);
      }
      notifyListeners();
    } else {
      notifyListeners();
    }
  }
}
