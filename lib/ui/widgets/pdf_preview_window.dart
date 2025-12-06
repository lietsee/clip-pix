import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pdfx/pdfx.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/models/pdf_content_item.dart';
import '../../data/pdf_preview_state_repository.dart';
import '../../system/window/always_on_top_helper.dart';

/// PDFコンテンツを別ウィンドウで表示する（ページ送り対応）
class PdfPreviewWindow extends StatefulWidget {
  const PdfPreviewWindow({
    super.key,
    required this.item,
    this.initialAlwaysOnTop = false,
    this.initialPage = 1,
    this.repository,
    this.onClose,
    this.onToggleAlwaysOnTop,
  });

  final PdfContentItem item;
  final bool initialAlwaysOnTop;
  final int initialPage;
  final PdfPreviewStateRepository? repository;
  final VoidCallback? onClose;
  final ValueChanged<bool>? onToggleAlwaysOnTop;

  @override
  State<PdfPreviewWindow> createState() => _PdfPreviewWindowState();
}

class _PdfPreviewWindowState extends State<PdfPreviewWindow>
    with WindowListener {
  final Logger _logger = Logger('PdfPreviewWindow');
  late bool _isAlwaysOnTop;
  bool _isClosing = false;
  bool _showUIElements = true;
  Timer? _autoHideTimer;

  // Window bounds saving state
  Timer? _boundsDebounceTimer;
  bool _needsSave = false;

  // PDF state
  PdfController? _pdfController;
  int _currentPage = 1;
  int _totalPages = 1;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _isAlwaysOnTop = widget.initialAlwaysOnTop;
    _currentPage = widget.initialPage;
    _loadPdf();
    if (_isAlwaysOnTop) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) {
          final success = await _applyAlwaysOnTop(true);
          if (!success && mounted) {
            setState(() {
              _isAlwaysOnTop = false;
            });
          }
        }
      });
    }
  }

  Future<void> _loadPdf() async {
    try {
      final file = File(widget.item.filePath);
      if (!await file.exists()) {
        setState(() {
          _errorMessage = 'ファイルが見つかりません';
          _isLoading = false;
        });
        return;
      }

      final document = await PdfDocument.openFile(widget.item.filePath);
      _totalPages = document.pagesCount;

      // Ensure initial page is valid
      if (_currentPage < 1) _currentPage = 1;
      if (_currentPage > _totalPages) _currentPage = _totalPages;

      _pdfController = PdfController(
        document: Future.value(document),
        initialPage: _currentPage,
      );

      setState(() {
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      _logger.warning('Failed to load PDF', error, stackTrace);
      setState(() {
        _errorMessage = 'PDFの読み込みに失敗しました: $error';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _boundsDebounceTimer?.cancel();
    windowManager.removeListener(this);
    _pdfController?.dispose();
    if (_isAlwaysOnTop) {
      // Fire-and-forget since window is closing
      unawaited(_applyAlwaysOnTop(false));
    }
    super.dispose();
  }

  /// Trigger debounced save (called on resize/move events)
  void _triggerDebouncedSave() {
    _needsSave = true;
    _boundsDebounceTimer?.cancel();
    _boundsDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _saveBounds(flush: false);
    });
  }

  /// Common method to save window bounds
  Future<void> _saveBounds({required bool flush}) async {
    if (widget.repository == null) return;

    try {
      final bounds = await windowManager.getBounds();
      await widget.repository!.save(
        widget.item.id,
        bounds,
        currentPage: _currentPage,
        alwaysOnTop: _isAlwaysOnTop,
      );

      _needsSave = false; // Clear dirty flag after successful save

      if (flush) {
        await Hive.close(); // Flush to disk on window close
      }

      _logger.fine(
          'Saved window bounds: $bounds, currentPage: $_currentPage, alwaysOnTop: $_isAlwaysOnTop, flush: $flush');
    } catch (e, stackTrace) {
      _logger.warning('Failed to save window bounds', e, stackTrace);
    }
  }

  // WindowListener implementation
  @override
  void onWindowResized() {
    debugPrint('[PdfPreviewWindow] onWindowResized triggered');
    _triggerDebouncedSave();
  }

  @override
  void onWindowMoved() {
    debugPrint('[PdfPreviewWindow] onWindowMoved triggered');
    _triggerDebouncedSave();
  }

  @override
  Future<void> onWindowClose() async {
    debugPrint('[PdfPreviewWindow] onWindowClose triggered');
    if (_isClosing) return;
    _isClosing = true;

    _boundsDebounceTimer?.cancel(); // Cancel any pending debounced save

    // Save window bounds only if there are unsaved changes or debounce timer was active
    if (_needsSave || _boundsDebounceTimer != null) {
      debugPrint(
          '[PdfPreviewWindow] Saving bounds on close (needsSave: $_needsSave, timerActive: ${_boundsDebounceTimer != null})');
      await _saveBounds(flush: true);
    } else {
      debugPrint(
          '[PdfPreviewWindow] Skipping bounds save on close (already saved)');
    }

    widget.onClose?.call();
  }

  Future<void> _handleClose() async {
    // Delegate to onWindowClose for consistent behavior
    await onWindowClose();
  }

  void _toggleAlwaysOnTop() {
    final desired = !_isAlwaysOnTop;
    unawaited(_applyAlwaysOnTopAndUpdate(desired));
  }

  Future<void> _applyAlwaysOnTopAndUpdate(bool desired) async {
    final applied = await _applyAlwaysOnTop(desired);
    if (!mounted) return;
    if (applied) {
      setState(() {
        _isAlwaysOnTop = desired;
      });
      _needsSave = true;
      widget.onToggleAlwaysOnTop?.call(desired);
    } else {
      widget.onToggleAlwaysOnTop?.call(false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最前面の切り替えに失敗しました')),
      );
    }
  }

  Future<bool> _applyAlwaysOnTop(bool enable) async {
    return applyAlwaysOnTop(enable);
  }

  void _goToPreviousPage() {
    if (_currentPage > 1) {
      _pdfController?.previousPage(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToNextPage() {
    if (_currentPage < _totalPages) {
      _pdfController?.nextPage(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToFirstPage() {
    _pdfController?.jumpToPage(1);
  }

  void _goToLastPage() {
    _pdfController?.jumpToPage(_totalPages);
  }

  void _onPageChanged(int page) {
    setState(() {
      _currentPage = page;
    });
    _needsSave = true; // Mark page change for saving
    _triggerDebouncedSave();
  }

  void _toggleUIElements() {
    setState(() {
      _showUIElements = !_showUIElements;
    });

    if (!_showUIElements) {
      _autoHideTimer?.cancel();
      _autoHideTimer = null;
    }
  }

  void _showTemporarily() {
    _autoHideTimer?.cancel();

    setState(() {
      _showUIElements = true;
    });

    _autoHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _showUIElements = false;
        });
      }
    });
  }

  void _handleMouseMove(Offset position) {
    if (!_showUIElements) {
      final size = MediaQuery.of(context).size;
      final isTopArea = position.dy < size.height * 0.1;
      final isBottomArea = position.dy > size.height * 0.9;

      if (isTopArea || isBottomArea) {
        _showTemporarily();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape): const _CloseIntent(),
      const SingleActivator(LogicalKeyboardKey.keyW, control: true):
          const _CloseIntent(),
      const SingleActivator(
        LogicalKeyboardKey.keyF,
        control: true,
        shift: true,
      ): const _ToggleAlwaysOnTopIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowLeft):
          const _PreviousPageIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowRight):
          const _NextPageIntent(),
      const SingleActivator(LogicalKeyboardKey.home): const _FirstPageIntent(),
      const SingleActivator(LogicalKeyboardKey.end): const _LastPageIntent(),
      const SingleActivator(LogicalKeyboardKey.f11):
          const _ToggleUIElementsIntent(),
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: MouseRegion(
        onHover: (event) => _handleMouseMove(event.localPosition),
        child: Shortcuts(
          shortcuts: shortcuts,
          child: Actions(
            actions: <Type, Action<Intent>>{
              _CloseIntent: CallbackAction<_CloseIntent>(onInvoke: (_) {
                _handleClose();
                return null;
              }),
              _ToggleAlwaysOnTopIntent:
                  CallbackAction<_ToggleAlwaysOnTopIntent>(onInvoke: (_) {
                _toggleAlwaysOnTop();
                return null;
              }),
              _PreviousPageIntent:
                  CallbackAction<_PreviousPageIntent>(onInvoke: (_) {
                _goToPreviousPage();
                return null;
              }),
              _NextPageIntent: CallbackAction<_NextPageIntent>(onInvoke: (_) {
                _goToNextPage();
                return null;
              }),
              _FirstPageIntent:
                  CallbackAction<_FirstPageIntent>(onInvoke: (_) {
                _goToFirstPage();
                return null;
              }),
              _LastPageIntent: CallbackAction<_LastPageIntent>(onInvoke: (_) {
                _goToLastPage();
                return null;
              }),
              _ToggleUIElementsIntent:
                  CallbackAction<_ToggleUIElementsIntent>(onInvoke: (_) {
                _toggleUIElements();
                return null;
              }),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                backgroundColor: Colors.grey.shade900,
                appBar: _buildAppBar(context),
                body: Stack(
                  children: [
                    _buildPdfView(),
                    if (!_showUIElements)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 40,
                        child: DragToMoveArea(
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                  ],
                ),
                bottomNavigationBar: _buildPageNavigation(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final title = p.basename(widget.item.filePath);

    if (!_showUIElements) {
      return PreferredSize(
        preferredSize: Size.zero,
        child: SizedBox.shrink(),
      );
    }

    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: AnimatedOpacity(
        opacity: _showUIElements ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: DragToMoveArea(
          child: AppBar(
            backgroundColor: Colors.grey.shade800,
            elevation: 2,
            title: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
            iconTheme: const IconThemeData(color: Colors.white),
            actions: [
              IconButton(
                tooltip: _isAlwaysOnTop
                    ? '最前面表示を解除 (Ctrl+Shift+F)'
                    : '最前面表示 (Ctrl+Shift+F)',
                onPressed: _toggleAlwaysOnTop,
                style: IconButton.styleFrom(
                  backgroundColor: _isAlwaysOnTop
                      ? Theme.of(context).colorScheme.primary.withOpacity(0.2)
                      : null,
                ),
                icon: Icon(
                  Icons.push_pin,
                  color: _isAlwaysOnTop
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade400,
                ),
              ),
              IconButton(
                tooltip: '閉じる (Esc)',
                onPressed: _handleClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPdfView() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_pdfController == null) {
      return const Center(
        child: Text(
          'PDFの初期化に失敗しました',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return PdfView(
      controller: _pdfController!,
      onPageChanged: _onPageChanged,
      scrollDirection: Axis.vertical,
      pageSnapping: false,
      backgroundDecoration: BoxDecoration(color: Colors.grey.shade900),
    );
  }

  Widget? _buildPageNavigation() {
    if (!_showUIElements || _totalPages <= 1) {
      return null;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      height: _showUIElements ? 56 : 0,
      child: AnimatedOpacity(
        opacity: _showUIElements ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: Container(
          color: Colors.grey.shade800,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '最初のページ (Home)',
                onPressed: _currentPage > 1 ? _goToFirstPage : null,
                icon: Icon(
                  Icons.first_page,
                  color: _currentPage > 1 ? Colors.white : Colors.grey.shade600,
                ),
              ),
              IconButton(
                tooltip: '前のページ (←)',
                onPressed: _currentPage > 1 ? _goToPreviousPage : null,
                icon: Icon(
                  Icons.chevron_left,
                  color: _currentPage > 1 ? Colors.white : Colors.grey.shade600,
                ),
              ),
              const SizedBox(width: 16),
              Text(
                '$_currentPage / $_totalPages',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 16),
              IconButton(
                tooltip: '次のページ (→)',
                onPressed: _currentPage < _totalPages ? _goToNextPage : null,
                icon: Icon(
                  Icons.chevron_right,
                  color: _currentPage < _totalPages
                      ? Colors.white
                      : Colors.grey.shade600,
                ),
              ),
              IconButton(
                tooltip: '最後のページ (End)',
                onPressed: _currentPage < _totalPages ? _goToLastPage : null,
                icon: Icon(
                  Icons.last_page,
                  color: _currentPage < _totalPages
                      ? Colors.white
                      : Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CloseIntent extends Intent {
  const _CloseIntent();
}

class _ToggleAlwaysOnTopIntent extends Intent {
  const _ToggleAlwaysOnTopIntent();
}

class _PreviousPageIntent extends Intent {
  const _PreviousPageIntent();
}

class _NextPageIntent extends Intent {
  const _NextPageIntent();
}

class _FirstPageIntent extends Intent {
  const _FirstPageIntent();
}

class _LastPageIntent extends Intent {
  const _LastPageIntent();
}

class _ToggleUIElementsIntent extends Intent {
  const _ToggleUIElementsIntent();
}
