import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/grid_card_preferences_repository.dart';
import '../data/models/image_item.dart';
import '../system/clipboard_copy_service.dart';
import '../system/state/folder_view_mode.dart';
import '../system/state/image_library_notifier.dart';
import '../system/state/image_library_state.dart';
import '../system/state/selected_folder_state.dart';
import 'image_card.dart';

class GridViewModule extends StatefulWidget {
  const GridViewModule({super.key, required this.state, this.controller});

  final ImageLibraryState state;
  final ScrollController? controller;

  @override
  State<GridViewModule> createState() => _GridViewModuleState();
}

class _GridViewModuleState extends State<GridViewModule> {
  static const Duration _animationDuration = Duration(milliseconds: 200);
  static const double _spacing = 12;
  static const double _minRowWidth = 200;

  late GridCardPreferencesRepository _preferences;
  bool _isInitialized = false;

  final Map<String, ValueNotifier<Size>> _sizeNotifiers = {};
  final Map<String, ValueNotifier<double>> _scaleNotifiers = {};
  final Map<String, Timer> _sizeDebounceTimers = {};
  final Map<String, Timer> _scaleDebounceTimers = {};
  final Map<String, ScrollController> _directoryControllers = {};
  final Map<String, VoidCallback> _sizeListeners = {};

  List<_GridEntry> _entries = <_GridEntry>[];
  bool _loggedInitialBuild = false;
  final Set<Object> _currentBuildKeys = <Object>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      _preferences = context.read<GridCardPreferencesRepository>();
      _entries = widget.state.images.map(_createEntry).toList(growable: true);
      for (final item in widget.state.images) {
        _ensureNotifiers(item);
      }
      setState(() {
        _isInitialized = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final entry in _entries) {
          _animateEntryVisible(entry);
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant GridViewModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isInitialized) {
      return;
    }
    if (!listEquals(oldWidget.state.images, widget.state.images)) {
      _reconcileEntries(widget.state.images);
    } else {
      for (final item in widget.state.images) {
        _ensureNotifiers(item);
      }
    }
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.removalTimer?.cancel();
    }
    for (final controller in _directoryControllers.values) {
      controller.dispose();
    }
    for (final timer in [
      ..._sizeDebounceTimers.values,
      ..._scaleDebounceTimers.values,
    ]) {
      timer.cancel();
    }
    _sizeNotifiers.forEach((key, notifier) {
      final listener = _sizeListeners[key];
      if (listener != null) {
        notifier.removeListener(listener);
      }
      notifier.dispose();
    });
    _sizeListeners.clear();
    for (final notifier in _scaleNotifiers.values) {
      notifier.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.state.isLoading && widget.state.images.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_entries.where((entry) => !entry.isRemoving).isEmpty) {
      return const Center(child: Text('フォルダ内に画像がありません'));
    }

    final libraryNotifier = context.read<ImageLibraryNotifier>();
    final selectedState = context.watch<SelectedFolderState>();

    if (!_loggedInitialBuild) {
      _loggedInitialBuild = true;
      _logEntries('build_init', _entries);
    }

    return RefreshIndicator(
      onRefresh: () => libraryNotifier.refresh(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final controller = _resolveController(selectedState);
          final availableWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth - (_spacing * 2)
              : MediaQuery.of(context).size.width - (_spacing * 2);
          final rows = _buildRows(
            availableWidth > 0 ? availableWidth : _minRowWidth,
          );
          _currentBuildKeys.clear();

          return SingleChildScrollView(
            controller: controller,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              bottom: 80,
              left: _spacing,
              right: _spacing,
              top: _spacing,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: rowIndex == rows.length - 1 ? 0 : _spacing,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var itemIndex = 0;
                            itemIndex < rows[rowIndex].items.length;
                            itemIndex++)
                          Padding(
                            padding: EdgeInsets.only(
                              right:
                                  itemIndex == rows[rowIndex].items.length - 1
                                      ? 0
                                      : _spacing,
                            ),
                            child: _buildCard(rows[rowIndex].items[itemIndex]),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCard(_RowItem rowItem) {
    final entry = rowItem.entry;
    final item = entry.item;
    final sizeNotifier = _sizeNotifiers[item.id]!;
    final scaleNotifier = _scaleNotifiers[item.id]!;
    final animatedKey = ObjectKey(entry);
    final entryHash = identityHashCode(entry);
    debugPrint(
      '[GridViewModule] build_child key=$animatedKey entryHash=$entryHash removing=${entry.isRemoving} opacity=${entry.opacity.toStringAsFixed(2)}',
    );
    if (!_currentBuildKeys.add(animatedKey)) {
      debugPrint(
        '[GridViewModule] duplicate_detected key=$animatedKey entryHash=$entryHash',
      );
    }
    return SizedBox(
      width: rowItem.width,
      child: AnimatedOpacity(
        key: animatedKey,
        duration: _animationDuration,
        opacity: entry.opacity,
        child: ImageCard(
          item: item,
          sizeNotifier: sizeNotifier,
          scaleNotifier: scaleNotifier,
          onResize: _handleResize,
          onZoom: _handleZoom,
          onRetry: _handleRetry,
          onOpenPreview: _showPreviewDialog,
          onCopyImage: _handleCopy,
        ),
      ),
    );
  }

  void _handleCopy(ImageItem item) async {
    final copyService = context.read<ClipboardCopyService>();
    try {
      await copyService.copyImage(item);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('クリップボードにコピーしました')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('コピーに失敗しました')));
    }
  }

  void _handleRetry(String id) {
    final item = widget.state.images.firstWhere(
      (image) => image.id == id,
      orElse: () => _entries.firstWhere((entry) => entry.item.id == id).item,
    );
    final notifier = context.read<ImageLibraryNotifier>();
    unawaited(notifier.addOrUpdate(File(item.filePath)));
  }

  void _handleResize(String id, Size newSize) {
    _sizeDebounceTimers[id]?.cancel();
    _sizeDebounceTimers[id] = Timer(const Duration(milliseconds: 200), () {
      unawaited(_preferences.saveSize(id, newSize));
    });
  }

  void _handleZoom(String id, double scale) {
    _scaleDebounceTimers[id]?.cancel();
    _scaleDebounceTimers[id] = Timer(const Duration(milliseconds: 150), () {
      unawaited(_preferences.saveScale(id, scale));
    });
  }

  ScrollController _resolveController(SelectedFolderState selectedState) {
    if (selectedState.viewMode == FolderViewMode.root &&
        widget.controller != null) {
      return widget.controller!;
    }
    final directory = widget.state.activeDirectory;
    final key = directory?.path ?? '_root';
    return _directoryControllers.putIfAbsent(key, () => ScrollController());
  }

  List<_RowLayout> _buildRows(double maxWidth) {
    final List<_RowLayout> rows = <_RowLayout>[];
    if (maxWidth <= 0) {
      return rows;
    }

    List<_RowItem> currentRow = <_RowItem>[];
    double occupiedWidth = 0;

    for (final entry in _entries) {
      final size = _sizeNotifiers[entry.item.id]!.value;
      final width = math.min(size.width, maxWidth);
      final neededWidth =
          currentRow.isEmpty ? width : occupiedWidth + _spacing + width;

      if (currentRow.isNotEmpty && neededWidth > maxWidth) {
        rows.add(_RowLayout(List<_RowItem>.from(currentRow)));
        currentRow = <_RowItem>[];
        occupiedWidth = 0;
      }

      if (currentRow.isNotEmpty) {
        occupiedWidth += _spacing;
      }
      currentRow.add(_RowItem(entry: entry, width: width));
      occupiedWidth += width;
    }

    if (currentRow.isNotEmpty) {
      rows.add(_RowLayout(currentRow));
    }

    return rows;
  }

  _GridEntry _createEntry(ImageItem item) {
    _ensureNotifiers(item);
    return _GridEntry(item: item, opacity: 0);
  }

  void _ensureNotifiers(ImageItem item) {
    _sizeNotifiers.putIfAbsent(item.id, () {
      final pref =
          _preferences.get(item.id) ?? _preferences.getOrCreate(item.id);
      final notifier = ValueNotifier<Size>(pref.size);
      _attachSizeListener(item.id, notifier);
      return notifier;
    });
    if (!_sizeListeners.containsKey(item.id)) {
      _attachSizeListener(item.id, _sizeNotifiers[item.id]!);
    }
    _scaleNotifiers.putIfAbsent(item.id, () {
      final pref =
          _preferences.get(item.id) ?? _preferences.getOrCreate(item.id);
      return ValueNotifier<double>(pref.scale);
    });
  }

  void _reconcileEntries(List<ImageItem> newItems) {
    _logEntries('reconcile_before', _entries);
    final duplicateIncoming = _findDuplicateIds(
      newItems.map((item) => item.id),
    );
    if (duplicateIncoming.isNotEmpty) {
      debugPrint(
        '[GridViewModule] incoming duplicates detected: $duplicateIncoming',
      );
    }
    final newIds = newItems.map((item) => item.id).toSet();
    final existingMap = {for (final entry in _entries) entry.item.id: entry};

    for (final entry in _entries) {
      if (!newIds.contains(entry.item.id) && !entry.isRemoving) {
        entry.isRemoving = true;
        entry.opacity = 0;
        entry.removalTimer?.cancel();
        entry.removalTimer = Timer(_animationDuration, () {
          if (!mounted) return;
          setState(() {
            _entries.remove(entry);
            _disposeEntry(entry);
          });
          _logEntries('reconcile_remove', _entries);
        });
      }
    }

    final List<_GridEntry> reordered = <_GridEntry>[];
    for (final item in newItems) {
      final existing = existingMap[item.id];
      if (existing != null) {
        existing.item = item;
        if (existing.isRemoving) {
          existing.removalTimer?.cancel();
          existing.isRemoving = false;
        }
        if (existing.opacity != 1) {
          existing.opacity = 1;
        }
        existing.version += 1;
        reordered.add(existing);
      } else {
        final entry = _createEntry(item);
        reordered.add(entry);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _animateEntryVisible(entry);
          }
        });
      }
    }

    for (final entry in _entries) {
      if (entry.isRemoving && !reordered.contains(entry)) {
        reordered.add(entry);
      }
    }

    _logEntries('reconcile_after_pending', reordered);
    setState(() {
      _entries = reordered;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _logEntries('reconcile_after_post', _entries);
    });
  }

  void _animateEntryVisible(_GridEntry entry) {
    if (!mounted) {
      return;
    }
    if (entry.opacity == 1) {
      return;
    }
    setState(() {
      entry.opacity = 1;
    });
  }

  void _disposeEntry(_GridEntry entry) {
    entry.removalTimer?.cancel();
    entry.removalTimer = null;
    final id = entry.item.id;
    _sizeDebounceTimers.remove(id)?.cancel();
    _scaleDebounceTimers.remove(id)?.cancel();
    final sizeNotifier = _sizeNotifiers.remove(id);
    final sizeListener = _sizeListeners.remove(id);
    if (sizeNotifier != null && sizeListener != null) {
      sizeNotifier.removeListener(sizeListener);
    }
    sizeNotifier?.dispose();
    _scaleNotifiers.remove(id)?.dispose();
  }

  void _attachSizeListener(String id, ValueNotifier<Size> notifier) {
    final existing = _sizeListeners[id];
    if (existing != null) {
      notifier.removeListener(existing);
    }
    void listener() {
      if (mounted) {
        setState(() {});
      }
    }

    notifier.addListener(listener);
    _sizeListeners[id] = listener;
  }

  void _showPreviewDialog(ImageItem item) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: InteractiveViewer(
          child: Image.file(File(item.filePath), fit: BoxFit.contain),
        ),
      ),
    );
  }

  void _logEntries(String label, List<_GridEntry> entries) {
    final counts = <String, int>{};
    for (final entry in entries) {
      final key = '${entry.item.id}_${entry.version}';
      counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    }
    final duplicates = counts.entries
        .where((element) => element.value > 1)
        .map((e) => e.key)
        .toList();
    debugPrint(
      '[GridViewModule] $label total=${entries.length} removing=${entries.where((e) => e.isRemoving).length} duplicates=$duplicates entries=${entries.map((e) => '${e.item.id}|v${e.version}|rem=${e.isRemoving}|opacity=${e.opacity.toStringAsFixed(2)}').join(', ')}',
    );
  }

  List<String> _findDuplicateIds(Iterable<String> ids) {
    final seen = <String>{};
    final duplicates = <String>[];
    for (final id in ids) {
      if (!seen.add(id)) {
        duplicates.add(id);
      }
    }
    return duplicates;
  }
}

class _RowLayout {
  _RowLayout(this.items);

  final List<_RowItem> items;
}

class _RowItem {
  _RowItem({required this.entry, required this.width});

  final _GridEntry entry;
  final double width;
}

class _GridEntry {
  _GridEntry({required this.item, required this.opacity, this.version = 0});

  ImageItem item;
  double opacity;
  bool isRemoving = false;
  Timer? removalTimer;
  int version;
}
