import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
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

  late GridCardPreferencesRepository _preferences;
  bool _isInitialized = false;

  final Map<String, ValueNotifier<Size>> _sizeNotifiers = {};
  final Map<String, ValueNotifier<double>> _scaleNotifiers = {};
  final Map<String, Timer> _sizeDebounceTimers = {};
  final Map<String, Timer> _scaleDebounceTimers = {};
  final Map<String, ScrollController> _directoryControllers = {};

  List<_GridEntry> _entries = <_GridEntry>[];
  bool _loggedInitialBuild = false;

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
    for (final notifier in _sizeNotifiers.values) {
      notifier.dispose();
    }
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
          final crossAxisCount = _calculateCrossAxisCount(constraints.maxWidth);
          final controller = _resolveController(selectedState);
          return MasonryGridView.builder(
            controller: controller,
            gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
            ),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            padding: const EdgeInsets.only(
              bottom: 80,
              left: 12,
              right: 12,
              top: 12,
            ),
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              final entry = _entries[index];
              final item = entry.item;
              final sizeNotifier = _sizeNotifiers[item.id]!;
              final scaleNotifier = _scaleNotifiers[item.id]!;

              if (index >= _entries.length - 3) {
                _prefetchAhead(context, index + 1);
              }

              final key = ValueKey('${item.id}_${entry.version}');
              return AnimatedOpacity(
                key: key,
                duration: _animationDuration,
                opacity: entry.opacity,
                child: ImageCard(
                  key: key,
                  item: item,
                  sizeNotifier: sizeNotifier,
                  scaleNotifier: scaleNotifier,
                  onResize: _handleResize,
                  onZoom: _handleZoom,
                  onRetry: _handleRetry,
                  onOpenPreview: _showPreviewDialog,
                  onCopyImage: _handleCopy,
                ),
              );
            },
          );
        },
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

  void _prefetchAhead(BuildContext context, int startIndex) {
    for (var i = startIndex; i < startIndex + 3 && i < _entries.length; i++) {
      final entry = _entries[i];
      precacheImage(FileImage(File(entry.item.filePath)), context);
    }
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

  int _calculateCrossAxisCount(double width) {
    if (width <= 1200) {
      return 2;
    }
    if (width <= 1800) {
      return 3;
    }
    return 4;
  }

  _GridEntry _createEntry(ImageItem item) {
    _ensureNotifiers(item);
    return _GridEntry(item: item, opacity: 0);
  }

  void _ensureNotifiers(ImageItem item) {
    _sizeNotifiers.putIfAbsent(item.id, () {
      final pref =
          _preferences.get(item.id) ?? _preferences.getOrCreate(item.id);
      return ValueNotifier<Size>(pref.size);
    });
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
    _sizeNotifiers.remove(id)?.dispose();
    _scaleNotifiers.remove(id)?.dispose();
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

class _GridEntry {
  _GridEntry({required this.item, required this.opacity, this.version = 0});

  ImageItem item;
  double opacity;
  bool isRemoving = false;
  Timer? removalTimer;
  int version;
}
