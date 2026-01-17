import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_state_notifier/flutter_state_notifier.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'data/file_info_manager.dart';
import 'data/grid_card_preferences_repository.dart';
import 'data/grid_layout_settings_repository.dart';
import 'data/guide_repository.dart';
import 'data/onboarding_repository.dart';
import 'ui/guide/interactive_guide_controller.dart';
import 'data/grid_order_repository.dart';
import 'data/image_repository.dart';
import 'data/metadata_writer.dart';
import 'data/models/content_type.dart';
import 'data/models/grid_card_pref.dart';
import 'data/models/grid_layout_settings.dart';
import 'data/models/image_entry.dart';
import 'data/models/image_item.dart';
import 'data/models/image_source_type.dart';
import 'data/models/image_preview_state.dart';
import 'data/models/open_preview_item.dart';
import 'data/models/pdf_content_item.dart';
import 'data/models/text_content_item.dart';
import 'data/models/text_preview_state.dart';
import 'data/models/pdf_preview_state.dart';
import 'data/image_preview_state_repository.dart';
import 'data/open_previews_repository.dart';
import 'data/text_preview_state_repository.dart';
import 'data/pdf_preview_state_repository.dart';
import 'system/pdf_thumbnail_cache_service.dart';
import 'system/app_lifecycle_service.dart';
import 'system/audio_service.dart';
import 'system/clipboard_copy_service.dart';
import 'system/clipboard_monitor.dart';
import 'system/folder_picker_service.dart';
import 'system/file_watcher.dart';
import 'system/image_saver.dart';
import 'system/screen_bounds_validator.dart';
import 'system/text_saver.dart';
import 'system/state/app_state_provider.dart';
import 'system/state/grid_layout_store.dart';
import 'system/state/grid_layout_mutation_controller.dart';
import 'system/state/grid_layout_store_adapters.dart';
import 'system/state/grid_resize_controller.dart';
import 'system/state/grid_resize_store_binding.dart';
import 'system/state/image_library_notifier.dart';
import 'system/state/image_library_state.dart';
import 'system/state/image_history_notifier.dart';
import 'system/state/selected_folder_state.dart';
import 'system/state/watcher_status_notifier.dart';
import 'system/url_download_service.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart' as win32;
import 'ui/main_screen.dart';
import 'ui/image_preview_window.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/widgets/text_preview_window.dart';
import 'ui/widgets/pdf_preview_window.dart';
import 'system/window_bounds_service.dart';

/// DEBUG: カード順序番号表示フラグ
/// trueにするとカードの中央に配列インデックスを表示
bool debugShowCardIndex = false;

/// ポータブルモードフラグ（アプリ起動時に設定）
/// trueの場合、Hiveデータとログを実行ファイルと同じディレクトリのdata/に保存
bool isPortableMode = false;

Future<void> main(List<String> args) async {
  // ポータブルモードフラグのパース（最初に行う）
  isPortableMode = args.contains('--portable');
  if (isPortableMode) {
    debugPrint('[main] Portable mode enabled');
  }

  // 親PIDを取得（プレビューウィンドウが親プロセス終了時に自動終了するため）
  final parentPidIndex = args.indexOf('--parent-pid');
  int? parentPid;
  if (parentPidIndex != -1 && parentPidIndex + 1 < args.length) {
    parentPid = int.tryParse(args[parentPidIndex + 1]);
  }

  // プレビューモード分岐（各モードは自身のrunZonedGuarded内でensureInitializedを呼ぶ）
  final previewIndex = args.indexOf('--preview');
  if (previewIndex != -1 && previewIndex + 1 < args.length) {
    await _launchPreviewMode(args[previewIndex + 1], parentPid);
    return;
  }

  final previewTextIndex = args.indexOf('--preview-text');
  if (previewTextIndex != -1 && previewTextIndex + 1 < args.length) {
    await _launchTextPreviewMode(args[previewTextIndex + 1], parentPid);
    return;
  }

  final previewPdfIndex = args.indexOf('--preview-pdf');
  if (previewPdfIndex != -1 && previewPdfIndex + 1 < args.length) {
    await _launchPdfPreviewMode(args[previewPdfIndex + 1], parentPid);
    return;
  }

  debugPrint('main start; Platform.isWindows=${Platform.isWindows}');

  // メインアプリ起動: runZonedGuarded内でensureInitializedとrunAppを同一ゾーンで呼ぶ
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // DEBUG: ヒットテスト可視化（タブ切り替え後の操作不能バグ調査用）
      debugPaintPointersEnabled = false;

      // Initialize Hive using base directory
      final baseDir = await _getHiveBaseDir();
      final hiveDir = Directory(baseDir);
      await hiveDir.create(recursive: true);
      await Hive.initFlutter(hiveDir.path);
      debugPrint('[Hive] Initialized at: ${hiveDir.path}');

      // Configure logging after base directory is determined
      final logDir = await _getLogDir();
      _configureLogging(logDir: logDir);
      _registerHiveAdapters();
      final boxes = await _openCoreBoxes();

      runApp(
        ClipPixApp(
          appStateBox: boxes.appStateBox,
          gridCardPrefBox: boxes.gridCardPrefBox,
          gridLayoutBox: boxes.gridLayoutBox,
          gridOrderBox: boxes.gridOrderBox,
          openPreviewsBox: boxes.openPreviewsBox,
          dataBasePath: baseDir,
        ),
      );
    },
    (error, stackTrace) =>
        Logger('ClipPixApp').severe('Uncaught zone error', error, stackTrace),
  );
}

void _configureLogging({Directory? logDir}) {
  Logger.root.level = Level.FINE;
  IOSink? sink;
  try {
    final logsDir = logDir ?? Directory('logs');
    logsDir.createSync(recursive: true);
    final logFile = File(p.join(logsDir.path, 'app.log'));
    sink = logFile.openWrite(mode: FileMode.append);
  } catch (error, stackTrace) {
    debugPrint('Failed to initialize log file: $error');
    Logger(
      'ClipPixLogging',
    ).warning('Failed to initialize log file', error, stackTrace);
  }
  Logger.root.onRecord.listen((record) {
    final buffer = StringBuffer();
    buffer.write(
      '[${record.level.name}] ${record.time.toIso8601String()} ${record.loggerName}: ${record.message}',
    );

    if (record.error != null) {
      buffer.write('\n  Error: ${record.error}');
    }
    if (record.stackTrace != null) {
      buffer.write('\n  StackTrace:\n${record.stackTrace}');
    }

    final line = buffer.toString();
    debugPrint(line);
    try {
      sink?.writeln(line);
    } catch (_) {}
  });
}

void _registerHiveAdapters() {
  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(ImageSourceTypeAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(ImageItemAdapter());
  }
  if (!Hive.isAdapterRegistered(2)) {
    Hive.registerAdapter(ImageEntryAdapter());
  }
  if (!Hive.isAdapterRegistered(3)) {
    Hive.registerAdapter(GridCardPreferenceAdapter());
  }
  if (!Hive.isAdapterRegistered(4)) {
    Hive.registerAdapter(GridLayoutSettingsAdapter());
  }
  if (!Hive.isAdapterRegistered(5)) {
    Hive.registerAdapter(GridBackgroundToneAdapter());
  }
  // 新規追加: ContentType enum (typeId: 6)
  if (!Hive.isAdapterRegistered(6)) {
    Hive.registerAdapter(ContentTypeAdapter());
  }
  // 新規追加: TextContentItem (typeId: 7)
  if (!Hive.isAdapterRegistered(7)) {
    Hive.registerAdapter(TextContentItemAdapter());
  }
  // 新規追加: TextPreviewState (typeId: 8)
  if (!Hive.isAdapterRegistered(8)) {
    Hive.registerAdapter(TextPreviewStateAdapter());
  }
  // 新規追加: OpenPreviewItem (typeId: 9)
  if (!Hive.isAdapterRegistered(9)) {
    Hive.registerAdapter(OpenPreviewItemAdapter());
  }
  // 新規追加: ImagePreviewState (typeId: 10)
  if (!Hive.isAdapterRegistered(10)) {
    Hive.registerAdapter(ImagePreviewStateAdapter());
  }
  // 新規追加: PdfContentItem (typeId: 11)
  if (!Hive.isAdapterRegistered(11)) {
    Hive.registerAdapter(PdfContentItemAdapter());
  }
  // 新規追加: PdfPreviewState (typeId: 12)
  if (!Hive.isAdapterRegistered(12)) {
    Hive.registerAdapter(PdfPreviewStateAdapter());
  }
}

Future<
    ({
      Box<dynamic> appStateBox,
      Box<GridCardPreference> gridCardPrefBox,
      Box<dynamic> gridLayoutBox,
      Box<dynamic> gridOrderBox,
      Box<TextPreviewState> textPreviewStateBox,
      Box<ImagePreviewState> imagePreviewStateBox,
      Box<OpenPreviewItem> openPreviewsBox,
    })> _openCoreBoxes() async {
  final appStateBox = await Hive.openBox<dynamic>('app_state');
  final gridCardPrefBox = await Hive.openBox<GridCardPreference>(
    'grid_card_prefs',
  );
  final gridLayoutBox = await Hive.openBox<dynamic>('grid_layout');
  final gridOrderBox = await Hive.openBox<dynamic>('grid_order');
  final textPreviewStateBox = await Hive.openBox<TextPreviewState>(
    'text_preview_state',
  );
  final imagePreviewStateBox = await Hive.openBox<ImagePreviewState>(
    'image_preview_state',
  );
  final openPreviewsBox = await Hive.openBox<OpenPreviewItem>(
    'open_previews',
  );
  return (
    appStateBox: appStateBox,
    gridCardPrefBox: gridCardPrefBox,
    gridLayoutBox: gridLayoutBox,
    gridOrderBox: gridOrderBox,
    textPreviewStateBox: textPreviewStateBox,
    imagePreviewStateBox: imagePreviewStateBox,
    openPreviewsBox: openPreviewsBox,
  );
}

/// Hive/ログのベースディレクトリを取得
/// ポータブルモード: <実行ファイルのディレクトリ>/data/
/// 通常モード: %APPDATA%\Clip-pix\ (Windows) または ~/Library/Application Support/Clip-pix/ (macOS)
Future<String> _getHiveBaseDir() async {
  if (isPortableMode) {
    final exePath = Platform.resolvedExecutable;
    final exeDir = p.dirname(exePath);
    return p.join(exeDir, 'data');
  }
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) {
      throw Exception('APPDATA environment variable not found');
    }
    return p.join(appData, 'Clip-pix');
  } else {
    final appSupportDir = await getApplicationSupportDirectory();
    return p.join(appSupportDir.path, 'Clip-pix');
  }
}

/// ログディレクトリを取得（Hiveと同じベースディレクトリ内）
Future<Directory> _getLogDir() async {
  final baseDir = await _getHiveBaseDir();
  return Directory(p.join(baseDir, 'logs'));
}

/// 親プロセスが生存しているかチェック
/// Windows: Win32 OpenProcess + GetExitCodeProcess APIで確認（高速）
/// macOS: psコマンドで確認
bool _isParentProcessAlive(int pid) {
  try {
    if (Platform.isWindows) {
      // PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
      final handle = win32.OpenProcess(
        win32.PROCESS_QUERY_LIMITED_INFORMATION,
        win32.FALSE,
        pid,
      );
      if (handle == 0) {
        // プロセスが存在しない、またはアクセス権がない
        return false;
      }

      // 終了コードを取得してプロセスが実際に生存しているか確認
      final exitCodePtr = calloc<Uint32>();
      final success = win32.GetExitCodeProcess(handle, exitCodePtr);
      final exitCode = exitCodePtr.value;
      calloc.free(exitCodePtr);
      win32.CloseHandle(handle);

      if (success == 0) {
        return true; // API失敗時は安全側（生存扱い）
      }

      // STILL_ACTIVE (259) = プロセス生存中
      return exitCode == win32.STILL_ACTIVE;
    } else if (Platform.isMacOS) {
      final result = Process.runSync('ps', ['-p', '$pid']);
      // 終了コード0ならプロセス存在
      return result.exitCode == 0;
    }
    return true; // 未対応プラットフォームでは終了しない
  } catch (error) {
    debugPrint('[ParentMonitor] Error checking parent process: $error');
    return true; // エラー時は終了しない（安全側に倒す）
  }
}

// Global key to access the preview app state for zoom persistence
GlobalKey<_ImagePreviewAppState>? _previewAppKey;

Future<void> _launchPreviewMode(String payload, int? parentPid) async {
  // 親プロセス監視タイマー（親プロセス終了時に自動終了）
  // ズーム状態を保存してから終了する
  if (parentPid != null) {
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!_isParentProcessAlive(parentPid)) {
        debugPrint(
            '[ImagePreviewMode] Parent process $parentPid not found, saving zoom state and exiting');
        timer.cancel();

        // Save zoom state before exiting
        try {
          final appState = _previewAppKey?.currentState;
          if (appState != null) {
            await appState.saveZoomState();
            debugPrint('[ImagePreviewMode] Zoom state saved');
          }
        } catch (e) {
          debugPrint('[ImagePreviewMode] Failed to save zoom state: $e');
        }

        exit(0);
      }
    });
    debugPrint(
        '[ImagePreviewMode] Started parent process monitor for PID: $parentPid');
  }

  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Configure logging with proper directory
      final logDir = await _getLogDir();
      _configureLogging(logDir: logDir);
      debugPrint(
          '[ImagePreviewMode] Starting with payload length: ${payload.length}');

      Map<String, dynamic> data;
      try {
        data = jsonDecode(payload) as Map<String, dynamic>;
        debugPrint('[ImagePreviewMode] Payload parsed successfully');
      } catch (error) {
        Logger('ImagePreviewWindow').severe('Invalid preview payload', error);
        debugPrint('[ImagePreviewMode] ERROR: Failed to parse payload');
        return;
      }

      final itemMap = (data['item'] as Map<String, dynamic>?);
      if (itemMap == null) {
        Logger('ImagePreviewWindow').warning('Preview payload missing item');
        debugPrint('[ImagePreviewMode] ERROR: Payload missing item');
        return;
      }

      final savedAtString = itemMap['savedAt'] as String?;
      DateTime? savedAt;
      if (savedAtString != null) {
        savedAt = DateTime.tryParse(savedAtString)?.toUtc();
      }

      final item = ImageItem(
        id: itemMap['id'] as String,
        filePath: itemMap['filePath'] as String,
        metadataPath: itemMap['metadataPath'] as String?,
        sourceType:
            ImageSourceType.values[(itemMap['sourceType'] as int?) ?? 0],
        savedAt: savedAt,
        source: itemMap['source'] as String?,
      );

      debugPrint(
          '[ImagePreviewMode] Item created: id=${item.id}, hashCode=${item.id.hashCode}');

      final initialTop = data['alwaysOnTop'] as bool? ?? false;

      // カスケード配置用オフセット
      final cascadeOffsetX = (data['cascadeOffsetX'] as num?)?.toDouble() ?? 0;
      final cascadeOffsetY = (data['cascadeOffsetY'] as num?)?.toDouble() ?? 0;

      // Initialize window_manager for frameless window
      debugPrint('[ImagePreviewMode] Initializing window manager...');
      await windowManager.ensureInitialized();
      debugPrint('[ImagePreviewMode] Window manager initialized');

      // Initialize Hive with SEPARATE path for this preview process
      ImagePreviewStateRepository? repository;
      Rect? restoredBounds;

      // Zoom state variables (declared outside try block for scope)
      double? initialZoomScale;
      double? initialPanOffsetX;
      double? initialPanOffsetY;

      // Generate unique Hive directory name based on item ID
      String getHiveDirectoryName(String itemId) {
        final bytes = utf8.encode(itemId);
        final digest = md5.convert(bytes);
        return 'image_preview_${digest.toString().substring(0, 8)}';
      }

      try {
        final baseHiveDir = await _getHiveBaseDir();
        final hiveDir = p.join(baseHiveDir, getHiveDirectoryName(item.id));
        debugPrint(
            '[ImagePreviewMode] Initializing Hive with directory: $hiveDir');
        await Directory(hiveDir).create(recursive: true);
        await Hive.initFlutter(hiveDir); // Unique subdirectory per item
        _registerHiveAdapters();
        await Hive.openBox<ImagePreviewState>('image_preview_state');
        debugPrint('[ImagePreviewMode] Hive initialized successfully');

        // Load saved window bounds and zoom state
        repository = ImagePreviewStateRepository();
        final validator = ScreenBoundsValidator();
        final savedState = repository.get(item.id);

        if (savedState != null) {
          // Restore zoom state if available
          initialZoomScale = savedState.zoomScale;
          initialPanOffsetX = savedState.panOffsetX;
          initialPanOffsetY = savedState.panOffsetY;

          if (savedState.x != null &&
              savedState.y != null &&
              savedState.width != null &&
              savedState.height != null) {
            final bounds = Rect.fromLTWH(
              savedState.x!,
              savedState.y!,
              savedState.width!,
              savedState.height!,
            );
            restoredBounds = await validator.adjustIfOffScreen(bounds);
            debugPrint(
                '[ImagePreviewMode] Loaded saved bounds: $restoredBounds');
          }

          if (initialZoomScale != null) {
            debugPrint(
                '[ImagePreviewMode] Loaded zoom state: scale=$initialZoomScale, panX=$initialPanOffsetX, panY=$initialPanOffsetY');
          }
        }
      } catch (error, stackTrace) {
        Logger('ImagePreviewWindow').warning(
          'Failed to initialize Hive for image preview, using default window bounds',
          error,
          stackTrace,
        );
        debugPrint(
            '[ImagePreviewMode] ERROR: Hive initialization failed: $error');
        // Continue without persistence - repository remains null
      }

      // Window options with saved or default bounds
      final windowSize = restoredBounds?.size ?? const Size(1200, 800);
      final windowOptions = WindowOptions(
        size: windowSize,
        minimumSize: const Size(600, 400),
        center: false, // 位置は手動で設定する（カスケード対応）
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden,
      );

      debugPrint('[ImagePreviewMode] Window options created');

      final copyService = ClipboardCopyService();

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        // Set unique window title for window activation (FindWindow)
        final windowTitle = 'clip_pix_image_${item.id.hashCode}';
        debugPrint('[ImagePreviewMode] Setting window title: $windowTitle');
        await windowManager.setTitle(windowTitle);
        debugPrint('[ImagePreviewMode] Window title set successfully');

        await windowManager.show();
        debugPrint('[ImagePreviewMode] Window shown');

        // 位置を設定（保存済み位置があれば復元、なければ中央+カスケードオフセット）
        if (restoredBounds != null) {
          await windowManager.setPosition(
            Offset(restoredBounds.left, restoredBounds.top),
          );
          debugPrint('[ImagePreviewMode] Position restored');
        } else {
          // 画面中央を基準にカスケードオフセットを適用
          // screen_retriever でプライマリ画面サイズを取得
          final displays = await screenRetriever.getAllDisplays();
          final primaryDisplay = displays.firstWhere(
            (d) => d.visiblePosition?.dx == 0 && d.visiblePosition?.dy == 0,
            orElse: () => displays.first,
          );
          final screenWidth = primaryDisplay.size.width;
          final screenHeight = primaryDisplay.size.height;
          final centerX = (screenWidth - windowSize.width) / 2 + cascadeOffsetX;
          final centerY = (screenHeight - windowSize.height) / 2 + cascadeOffsetY;
          await windowManager.setPosition(Offset(centerX, centerY));
          debugPrint('[ImagePreviewMode] Position set with cascade offset: ($centerX, $centerY)');
        }

        await windowManager.focus();
        debugPrint('[ImagePreviewMode] Window focused');

        // Run app AFTER window is fully initialized
        // This keeps the event loop alive and prevents early process exit
        _previewAppKey = GlobalKey<_ImagePreviewAppState>();
        runApp(
          _ImagePreviewApp(
            key: _previewAppKey,
            item: item,
            copyService: copyService,
            initialAlwaysOnTop: initialTop,
            repository: repository,
            initialZoomScale: initialZoomScale,
            initialPanOffsetX: initialPanOffsetX,
            initialPanOffsetY: initialPanOffsetY,
            onSaveZoomState: (scale, panX, panY) async {
              if (repository != null) {
                final bounds = await windowManager.getBounds();
                await repository.save(
                  item.id,
                  bounds,
                  alwaysOnTop: initialTop,
                  zoomScale: scale,
                  panOffsetX: panX,
                  panOffsetY: panY,
                );
                await Hive.close();
                debugPrint(
                    '[ImagePreviewMode] Saved zoom state: scale=$scale, panX=$panX, panY=$panY');
              }
            },
          ),
        );

        debugPrint('[ImagePreviewMode] runApp completed inside callback');
      });

      debugPrint('[ImagePreviewMode] waitUntilReadyToShow callback scheduled');
      // Event loop is now maintained by runApp, process stays alive
    },
    (error, stackTrace) {
      debugPrint('[ImagePreviewMode] FATAL ERROR: $error');
      debugPrint('[ImagePreviewMode] Stack trace:\n$stackTrace');
      Logger('ImagePreviewWindow').severe(
        'Unhandled exception in image preview mode',
        error,
        stackTrace,
      );
      exit(1);
    },
  );
}

class _ImagePreviewApp extends StatefulWidget {
  const _ImagePreviewApp({
    super.key,
    required this.item,
    required this.copyService,
    required this.initialAlwaysOnTop,
    this.repository,
    this.initialZoomScale,
    this.initialPanOffsetX,
    this.initialPanOffsetY,
    this.onSaveZoomState,
  });

  final ImageItem item;
  final ClipboardCopyService copyService;
  final bool initialAlwaysOnTop;
  final ImagePreviewStateRepository? repository;
  final double? initialZoomScale;
  final double? initialPanOffsetX;
  final double? initialPanOffsetY;
  final Future<void> Function(double scale, double panX, double panY)?
      onSaveZoomState;

  @override
  State<_ImagePreviewApp> createState() => _ImagePreviewAppState();
}

class _ImagePreviewAppState extends State<_ImagePreviewApp> {
  final GlobalKey<dynamic> _previewWindowKey = GlobalKey();

  /// Save zoom state (called from parent when parent process exits)
  Future<void> saveZoomState() async {
    final state = _previewWindowKey.currentState;
    if (state != null) {
      try {
        final (scale, panX, panY) = state.getZoomState();
        if (widget.onSaveZoomState != null) {
          await widget.onSaveZoomState!(scale, panX, panY);
        }
      } catch (e) {
        debugPrint('[_ImagePreviewAppState] Failed to save zoom state: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: ImagePreviewWindow(
        key: _previewWindowKey,
        item: widget.item,
        initialAlwaysOnTop: widget.initialAlwaysOnTop,
        initialZoomScale: widget.initialZoomScale,
        initialPanOffsetX: widget.initialPanOffsetX,
        initialPanOffsetY: widget.initialPanOffsetY,
        repository: widget.repository,
        onCopyImage: (image) => widget.copyService.copyImage(image),
        onClose: () => exit(0),
        onToggleAlwaysOnTop: (_) {},
      ),
    );
  }
}

Future<void> _launchTextPreviewMode(String payload, int? parentPid) async {
  // 親プロセス監視タイマー（親プロセス終了時に自動終了）
  if (parentPid != null) {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isParentProcessAlive(parentPid)) {
        debugPrint('[TextPreviewMode] Parent process $parentPid not found, exiting');
        timer.cancel();
        exit(0);
      }
    });
    debugPrint('[TextPreviewMode] Started parent process monitor for PID: $parentPid');
  }

  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Configure logging with proper directory
      final logDir = await _getLogDir();
      _configureLogging(logDir: logDir);
      debugPrint(
          '[TextPreviewMode] Starting with payload length: ${payload.length}');

      Map<String, dynamic> data;
      try {
        data = jsonDecode(payload) as Map<String, dynamic>;
        debugPrint('[TextPreviewMode] Payload parsed successfully');
      } catch (error) {
        Logger('TextPreviewWindow').severe('Invalid preview payload', error);
        debugPrint('[TextPreviewMode] ERROR: Failed to parse payload');
        return;
      }

      final itemMap = (data['item'] as Map<String, dynamic>?);
      if (itemMap == null) {
        Logger('TextPreviewWindow').warning('Preview payload missing item');
        debugPrint('[TextPreviewMode] ERROR: Payload missing item');
        return;
      }

      final savedAtString = itemMap['savedAt'] as String?;
      DateTime? savedAt;
      if (savedAtString != null) {
        savedAt = DateTime.tryParse(savedAtString)?.toUtc();
      }

      final item = TextContentItem(
        id: itemMap['id'] as String,
        filePath: itemMap['filePath'] as String,
        sourceType:
            ImageSourceType.values[(itemMap['sourceType'] as int?) ?? 0],
        savedAt: savedAt,
        source: itemMap['source'] as String?,
        fontSize: (itemMap['fontSize'] as num?)?.toDouble() ?? 14.0,
        memo: itemMap['memo'] as String? ?? '',
        favorite: itemMap['favorite'] as int? ?? 0,
      );

      debugPrint(
          '[TextPreviewMode] Item created: id=${item.id}, hashCode=${item.id.hashCode}');

      final initialTop = data['alwaysOnTop'] as bool? ?? false;

      // カスケード配置用オフセット
      final cascadeOffsetX = (data['cascadeOffsetX'] as num?)?.toDouble() ?? 0;
      final cascadeOffsetY = (data['cascadeOffsetY'] as num?)?.toDouble() ?? 0;

      // Initialize window_manager for frameless window
      debugPrint('[TextPreviewMode] Initializing window manager...');
      await windowManager.ensureInitialized();
      debugPrint('[TextPreviewMode] Window manager initialized');

      // Initialize Hive with SEPARATE path for this preview process
      TextPreviewStateRepository? repository;
      Rect? restoredBounds;

      // Generate unique Hive directory name based on item ID
      String getHiveDirectoryName(String itemId) {
        final bytes = utf8.encode(itemId);
        final digest = md5.convert(bytes);
        return 'text_preview_${digest.toString().substring(0, 8)}';
      }

      try {
        final baseHiveDir = await _getHiveBaseDir();
        final hiveDir = p.join(baseHiveDir, getHiveDirectoryName(item.id));
        debugPrint(
            '[TextPreviewMode] Initializing Hive with directory: $hiveDir');
        await Directory(hiveDir).create(recursive: true);
        await Hive.initFlutter(hiveDir); // Unique subdirectory per item
        _registerHiveAdapters();
        await Hive.openBox<TextPreviewState>('text_preview_state');
        debugPrint('[TextPreviewMode] Hive initialized successfully');

        // Load saved window bounds
        repository = TextPreviewStateRepository();
        final validator = ScreenBoundsValidator();
        final savedState = repository.get(item.id);

        if (savedState != null &&
            savedState.x != null &&
            savedState.y != null &&
            savedState.width != null &&
            savedState.height != null) {
          final bounds = Rect.fromLTWH(
            savedState.x!,
            savedState.y!,
            savedState.width!,
            savedState.height!,
          );
          restoredBounds = await validator.adjustIfOffScreen(bounds);
          debugPrint('[TextPreviewMode] Loaded saved bounds: $restoredBounds');
        }
      } catch (error, stackTrace) {
        Logger('TextPreviewWindow').warning(
          'Failed to initialize Hive for text preview, using default window bounds',
          error,
          stackTrace,
        );
        debugPrint(
            '[TextPreviewMode] ERROR: Hive initialization failed: $error');
        // Continue without persistence - repository remains null
      }

      // Window options with saved or default bounds
      final windowSize = restoredBounds?.size ?? const Size(900, 700);
      final windowOptions = WindowOptions(
        size: windowSize,
        minimumSize: const Size(400, 300),
        center: false, // 位置は手動で設定する（カスケード対応）
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden,
      );

      debugPrint('[TextPreviewMode] Window options created');

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        // Set unique window title for window activation (FindWindow)
        final windowTitle = 'clip_pix_text_${item.id.hashCode}';
        debugPrint('[TextPreviewMode] Setting window title: $windowTitle');
        await windowManager.setTitle(windowTitle);
        debugPrint('[TextPreviewMode] Window title set successfully');

        await windowManager.show();
        debugPrint('[TextPreviewMode] Window shown');

        // 位置を設定（保存済み位置があれば復元、なければ中央+カスケードオフセット）
        if (restoredBounds != null) {
          await windowManager.setPosition(
            Offset(restoredBounds.left, restoredBounds.top),
          );
          debugPrint('[TextPreviewMode] Position restored');
        } else {
          // 画面中央を基準にカスケードオフセットを適用
          // screen_retriever でプライマリ画面サイズを取得
          final displays = await screenRetriever.getAllDisplays();
          final primaryDisplay = displays.firstWhere(
            (d) => d.visiblePosition?.dx == 0 && d.visiblePosition?.dy == 0,
            orElse: () => displays.first,
          );
          final screenWidth = primaryDisplay.size.width;
          final screenHeight = primaryDisplay.size.height;
          final centerX = (screenWidth - windowSize.width) / 2 + cascadeOffsetX;
          final centerY = (screenHeight - windowSize.height) / 2 + cascadeOffsetY;
          await windowManager.setPosition(Offset(centerX, centerY));
          debugPrint('[TextPreviewMode] Position set with cascade offset: ($centerX, $centerY)');
        }

        await windowManager.focus();
        debugPrint('[TextPreviewMode] Window focused');

        // Run app AFTER window is fully initialized
        // This keeps the event loop alive and prevents early process exit
        runApp(
          _TextPreviewApp(
            item: item,
            initialAlwaysOnTop: initialTop,
            repository: repository,
          ),
        );

        debugPrint('[TextPreviewMode] runApp completed inside callback');
      });

      debugPrint('[TextPreviewMode] waitUntilReadyToShow callback scheduled');
      // Event loop is now maintained by runApp, process stays alive
    },
    (error, stackTrace) {
      debugPrint('[TextPreviewMode] FATAL ERROR: $error');
      debugPrint('[TextPreviewMode] Stack trace:\n$stackTrace');
      Logger('TextPreviewWindow').severe(
        'Unhandled exception in text preview mode',
        error,
        stackTrace,
      );
      exit(1);
    },
  );
}

class _TextPreviewApp extends StatelessWidget {
  const _TextPreviewApp({
    required this.item,
    required this.initialAlwaysOnTop,
    this.repository,
  });

  final TextContentItem item;
  final bool initialAlwaysOnTop;
  final TextPreviewStateRepository? repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: TextPreviewWindow(
        item: item,
        initialAlwaysOnTop: initialAlwaysOnTop,
        repository: repository,
        onClose: () => exit(0),
        onToggleAlwaysOnTop: (_) {},
      ),
    );
  }
}

Future<void> _launchPdfPreviewMode(String payload, int? parentPid) async {
  // 親プロセス監視タイマー（親プロセス終了時に自動終了）
  if (parentPid != null) {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isParentProcessAlive(parentPid)) {
        debugPrint('[PdfPreviewMode] Parent process $parentPid not found, exiting');
        timer.cancel();
        exit(0);
      }
    });
    debugPrint('[PdfPreviewMode] Started parent process monitor for PID: $parentPid');
  }

  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Configure logging with proper directory
      final logDir = await _getLogDir();
      _configureLogging(logDir: logDir);
      debugPrint(
          '[PdfPreviewMode] Starting with payload length: ${payload.length}');

      Map<String, dynamic> data;
      try {
        data = jsonDecode(payload) as Map<String, dynamic>;
        debugPrint('[PdfPreviewMode] Payload parsed successfully');
      } catch (error) {
        Logger('PdfPreviewWindow').severe('Invalid preview payload', error);
        debugPrint('[PdfPreviewMode] ERROR: Failed to parse payload');
        return;
      }

      final itemMap = (data['item'] as Map<String, dynamic>?);
      if (itemMap == null) {
        Logger('PdfPreviewWindow').warning('Preview payload missing item');
        debugPrint('[PdfPreviewMode] ERROR: Payload missing item');
        return;
      }

      final savedAtString = itemMap['savedAt'] as String?;
      DateTime? savedAt;
      if (savedAtString != null) {
        savedAt = DateTime.tryParse(savedAtString)?.toUtc();
      }

      final item = PdfContentItem(
        id: itemMap['id'] as String,
        filePath: itemMap['filePath'] as String,
        sourceType:
            ImageSourceType.values[(itemMap['sourceType'] as int?) ?? 0],
        savedAt: savedAt,
        source: itemMap['source'] as String?,
        memo: itemMap['memo'] as String? ?? '',
        favorite: itemMap['favorite'] as int? ?? 0,
        pageCount: itemMap['pageCount'] as int? ?? 1,
      );

      debugPrint(
          '[PdfPreviewMode] Item created: id=${item.id}, hashCode=${item.id.hashCode}, pageCount=${item.pageCount}');

      final initialTop = data['alwaysOnTop'] as bool? ?? false;
      final initialPage = data['currentPage'] as int? ?? 1;

      // カスケード配置用オフセット
      final cascadeOffsetX = (data['cascadeOffsetX'] as num?)?.toDouble() ?? 0;
      final cascadeOffsetY = (data['cascadeOffsetY'] as num?)?.toDouble() ?? 0;

      // Initialize window_manager for frameless window
      debugPrint('[PdfPreviewMode] Initializing window manager...');
      await windowManager.ensureInitialized();
      debugPrint('[PdfPreviewMode] Window manager initialized');

      // Initialize Hive with SEPARATE path for this preview process
      PdfPreviewStateRepository? repository;
      Rect? restoredBounds;
      int restoredPage = initialPage;

      // Generate unique Hive directory name based on item ID
      String getHiveDirectoryName(String itemId) {
        final bytes = utf8.encode(itemId);
        final digest = md5.convert(bytes);
        return 'pdf_preview_${digest.toString().substring(0, 8)}';
      }

      try {
        final baseHiveDir = await _getHiveBaseDir();
        final hiveDir = p.join(baseHiveDir, getHiveDirectoryName(item.id));
        debugPrint(
            '[PdfPreviewMode] Initializing Hive with directory: $hiveDir');
        await Directory(hiveDir).create(recursive: true);
        await Hive.initFlutter(hiveDir); // Unique subdirectory per item
        _registerHiveAdapters();
        await Hive.openBox<PdfPreviewState>('pdf_preview_state');
        debugPrint('[PdfPreviewMode] Hive initialized successfully');

        // Load saved window bounds
        repository = PdfPreviewStateRepository();
        final validator = ScreenBoundsValidator();
        final savedState = repository.get(item.id);

        if (savedState != null &&
            savedState.x != null &&
            savedState.y != null &&
            savedState.width != null &&
            savedState.height != null) {
          final bounds = Rect.fromLTWH(
            savedState.x!,
            savedState.y!,
            savedState.width!,
            savedState.height!,
          );
          restoredBounds = await validator.adjustIfOffScreen(bounds);
          restoredPage = savedState.currentPage;
          debugPrint('[PdfPreviewMode] Loaded saved bounds: $restoredBounds, page: $restoredPage');
        }
      } catch (error, stackTrace) {
        Logger('PdfPreviewWindow').warning(
          'Failed to initialize Hive for PDF preview, using default window bounds',
          error,
          stackTrace,
        );
        debugPrint(
            '[PdfPreviewMode] ERROR: Hive initialization failed: $error');
        // Continue without persistence - repository remains null
      }

      // Window options with saved or default bounds
      final windowSize = restoredBounds?.size ?? const Size(900, 700);
      final windowOptions = WindowOptions(
        size: windowSize,
        minimumSize: const Size(400, 300),
        center: false, // 位置は手動で設定する（カスケード対応）
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden,
      );

      debugPrint('[PdfPreviewMode] Window options created');

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        // Set unique window title for window activation (FindWindow)
        final windowTitle = 'clip_pix_pdf_${item.id.hashCode}';
        debugPrint('[PdfPreviewMode] Setting window title: $windowTitle');
        await windowManager.setTitle(windowTitle);
        debugPrint('[PdfPreviewMode] Window title set successfully');

        await windowManager.show();
        debugPrint('[PdfPreviewMode] Window shown');

        // 位置を設定（保存済み位置があれば復元、なければ中央+カスケードオフセット）
        if (restoredBounds != null) {
          await windowManager.setPosition(
            Offset(restoredBounds.left, restoredBounds.top),
          );
          debugPrint('[PdfPreviewMode] Position restored');
        } else {
          // 画面中央を基準にカスケードオフセットを適用
          // screen_retriever でプライマリ画面サイズを取得
          final displays = await screenRetriever.getAllDisplays();
          final primaryDisplay = displays.firstWhere(
            (d) => d.visiblePosition?.dx == 0 && d.visiblePosition?.dy == 0,
            orElse: () => displays.first,
          );
          final screenWidth = primaryDisplay.size.width;
          final screenHeight = primaryDisplay.size.height;
          final centerX = (screenWidth - windowSize.width) / 2 + cascadeOffsetX;
          final centerY = (screenHeight - windowSize.height) / 2 + cascadeOffsetY;
          await windowManager.setPosition(Offset(centerX, centerY));
          debugPrint('[PdfPreviewMode] Position set with cascade offset: ($centerX, $centerY)');
        }

        await windowManager.focus();
        debugPrint('[PdfPreviewMode] Window focused');

        // Run app AFTER window is fully initialized
        // This keeps the event loop alive and prevents early process exit
        runApp(
          _PdfPreviewApp(
            item: item,
            initialAlwaysOnTop: initialTop,
            initialPage: restoredPage,
            repository: repository,
          ),
        );

        debugPrint('[PdfPreviewMode] runApp completed inside callback');
      });

      debugPrint('[PdfPreviewMode] waitUntilReadyToShow callback scheduled');
      // Event loop is now maintained by runApp, process stays alive
    },
    (error, stackTrace) {
      debugPrint('[PdfPreviewMode] FATAL ERROR: $error');
      debugPrint('[PdfPreviewMode] Stack trace:\n$stackTrace');
      Logger('PdfPreviewWindow').severe(
        'Unhandled exception in PDF preview mode',
        error,
        stackTrace,
      );
      exit(1);
    },
  );
}

class _PdfPreviewApp extends StatelessWidget {
  const _PdfPreviewApp({
    required this.item,
    required this.initialAlwaysOnTop,
    required this.initialPage,
    this.repository,
  });

  final PdfContentItem item;
  final bool initialAlwaysOnTop;
  final int initialPage;
  final PdfPreviewStateRepository? repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: PdfPreviewWindow(
        item: item,
        initialAlwaysOnTop: initialAlwaysOnTop,
        initialPage: initialPage,
        repository: repository,
        onClose: () => exit(0),
        onToggleAlwaysOnTop: (_) {},
      ),
    );
  }
}

class ClipPixApp extends StatelessWidget {
  const ClipPixApp({
    super.key,
    required this.appStateBox,
    required this.gridCardPrefBox,
    required this.gridLayoutBox,
    required this.gridOrderBox,
    required this.openPreviewsBox,
    required this.dataBasePath,
  });

  final Box<dynamic> appStateBox;
  final Box<GridCardPreference> gridCardPrefBox;
  final Box<dynamic> gridLayoutBox;
  final Box<dynamic> gridOrderBox;
  final Box<OpenPreviewItem> openPreviewsBox;
  final String dataBasePath;

  @override
  Widget build(BuildContext context) {
    debugPrint('[ClipPixApp] building; isWindows=${Platform.isWindows}');
    final openPreviewsRepo = OpenPreviewsRepository();
    final onboardingRepo = OnboardingRepository(appStateBox);
    final guideRepo = GuideRepository(appStateBox);
    final List<SingleChildWidget> providersList = <SingleChildWidget>[
      ChangeNotifierProvider<OnboardingRepository>.value(
        value: onboardingRepo,
      ),
      ChangeNotifierProvider<GuideRepository>.value(
        value: guideRepo,
      ),
      ChangeNotifierProvider<InteractiveGuideController>(
        create: (_) => InteractiveGuideController(),
      ),
      ...AppStateProvider.providers(
        appStateBox: appStateBox,
        openPreviewsRepo: openPreviewsRepo,
      ),
      Provider<GridCardPreferencesRepository>(
        create: (_) => GridCardPreferencesRepository(gridCardPrefBox),
      ),
      ChangeNotifierProvider<GridLayoutSettingsRepository>(
        create: (_) => GridLayoutSettingsRepository(gridLayoutBox),
      ),
      ChangeNotifierProvider<GridOrderRepository>(
        create: (_) => GridOrderRepository(gridOrderBox),
      ),
      ChangeNotifierProvider<GridResizeController>(
        create: (_) => GridResizeController(),
      ),
      ChangeNotifierProvider<GridLayoutMutationController>(
        create: (_) => GridLayoutMutationController(
          debugLoggingEnabled: kDebugMode || kProfileMode,
        ),
      ),
      ChangeNotifierProvider<PdfThumbnailCacheService>(
        create: (_) => PdfThumbnailCacheService(
          cacheDirectory: p.join(dataBasePath, 'pdf_thumbnails'),
        ),
      ),
      ChangeNotifierProxyProvider<GridCardPreferencesRepository,
          GridLayoutStore>(
        create: (context) => GridLayoutStore(
          persistence: GridLayoutHivePersistence(
            context.read<GridCardPreferencesRepository>(),
          ),
          ratioResolver: FileImageRatioResolver(),
        ),
        update: (_, __, store) {
          assert(store != null, 'GridLayoutStore must be created');
          return store!;
        },
      ),
      Provider<GridResizeStoreBinding>(
        lazy: false,
        create: (context) => GridResizeStoreBinding(
          controller: context.read<GridResizeController>(),
          store: context.read<GridLayoutStore>(),
          mutationController: context.read<GridLayoutMutationController>(),
        ),
        dispose: (_, binding) => binding.dispose(),
      ),
      Provider<FileInfoManager>(
        create: (_) => FileInfoManager(),
        dispose: (_, manager) => manager.dispose(),
      ),
      Provider<AppLifecycleService>(
        lazy: false,
        create: (context) {
          final service = AppLifecycleService(context.read<FileInfoManager>());
          service.init();
          return service;
        },
        dispose: (_, service) => service.dispose(),
      ),
      Provider<MetadataWriter>(
        create: (context) =>
            MetadataWriter(fileInfoManager: context.read<FileInfoManager>()),
      ),
      Provider<ImageRepository>(
        create: (context) =>
            ImageRepository(fileInfoManager: context.read<FileInfoManager>()),
      ),
      StateNotifierProvider<ImageLibraryNotifier, ImageLibraryState>(
        create: (context) => ImageLibraryNotifier(
          context.read<ImageRepository>(),
          fileInfoManager: context.read<FileInfoManager>(),
          orderRepository: context.read<GridOrderRepository>(),
        ),
      ),
      Provider<FolderPickerService>(create: (_) => FolderPickerService()),
      Provider<UrlDownloadService>(
        create: (_) => UrlDownloadService(),
        dispose: (_, service) => service.dispose(),
      ),
      Provider<ClipboardCopyService>(create: (_) => ClipboardCopyService()),
      Provider<AudioService>(
        create: (_) => AudioService(),
        dispose: (_, service) => service.dispose(),
      ),
      Provider<ImageSaver>(
        create: (context) => ImageSaver(
          getSelectedFolder: () {
            final state = context.read<SelectedFolderState>();
            return state.viewDirectory ?? state.current;
          },
          metadataWriter: context.read<MetadataWriter>(),
        ),
      ),
      Provider<TextSaver>(
        create: (context) => TextSaver(
          getSelectedFolder: () {
            final state = context.read<SelectedFolderState>();
            return state.viewDirectory ?? state.current;
          },
          metadataWriter: context.read<MetadataWriter>(),
        ),
      ),
      if (Platform.isWindows || Platform.isMacOS)
        Provider<WindowBoundsService>(
          lazy: false,
          create: (_) {
            debugPrint('[ClipPixApp] Initializing WindowBoundsService');
            final service = WindowBoundsService();
            service.init();
            return service;
          },
          dispose: (_, service) => service.dispose(),
        ),
      ChangeNotifierProxyProvider5<ImageSaver, TextSaver, ClipboardCopyService,
          UrlDownloadService, ImageLibraryNotifier, ClipboardMonitor>(
        create: (context) {
          // Create dummy instance for initialization
          // Will be replaced by update callback immediately
          return ClipboardMonitor(
            getSelectedFolder: () => null,
            onImageCaptured: (_, {source, sourceType = ImageSourceType.local}) async {},
            onUrlCaptured: (_) async {},
            onTextCaptured: (_) async {},
          );
        },
        update: (
          context,
          imageSaver,
          textSaver,
          copyService,
          downloadService,
          imageLibrary,
          previous,
        ) {
          if (previous != null) {
            previous.dispose();
          }

          // Initialize AudioService with current sound settings
          final audioService = context.read<AudioService>();
          final layoutSettings =
              context.read<GridLayoutSettingsRepository>().value;
          debugPrint(
              '[AudioService] Initializing with soundEnabled=${layoutSettings.soundEnabled}');
          audioService.setSoundEnabled(layoutSettings.soundEnabled);

          late final ClipboardMonitor monitor;
          monitor = ClipboardMonitor(
            getSelectedFolder: () =>
                context.read<SelectedFolderState>().current,
            onImageCaptured: (
              imageData, {
              String? source,
              ImageSourceType sourceType = ImageSourceType.local,
            }) async {
              SaveResult result;
              try {
                result = await imageSaver.saveImageData(
                  imageData,
                  source: source,
                  sourceType: sourceType,
                );
              } catch (error, stackTrace) {
                Logger(
                  'ClipboardMonitorHandler',
                ).severe('Image save failed', error, stackTrace);
                result = SaveResult.failed(error: error);
              }
              if (result.isSuccess) {
                context.read<AudioService>().playSaveSuccess();
                final historyNotifier = context.read<ImageHistoryNotifier>();
                historyNotifier.addEntry(
                  ImageEntry(
                    filePath: result.filePath!,
                    metadataPath: result.metadataPath!,
                    sourceType: sourceType,
                    savedAt: DateTime.now().toUtc(),
                  ),
                );
                await imageLibrary.addOrUpdate(File(result.filePath!));
              } else {
                context.read<WatcherStatusNotifier>().setError(
                      'image_save_failed',
                    );
              }
              monitor.onSaveCompleted(result);
            },
            onUrlCaptured: (url) async {
              final historyNotifier = context.read<ImageHistoryNotifier>();
              final watcherStatus = context.read<WatcherStatusNotifier>();
              final downloadResult = await downloadService.downloadImage(
                url,
              );
              if (downloadResult == null) {
                watcherStatus.setError('download_failed');
                monitor.onSaveCompleted(
                  SaveResult.failed(error: 'download_failed'),
                );
                return;
              }
              SaveResult saveResult;
              try {
                saveResult = await imageSaver.saveImageData(
                  downloadResult.bytes,
                  source: url,
                  sourceType: ImageSourceType.web,
                );
              } catch (error, stackTrace) {
                Logger(
                  'ClipboardMonitorHandler',
                ).severe('URL save failed', error, stackTrace);
                saveResult = SaveResult.failed(error: error);
              }
              if (saveResult.isSuccess) {
                context.read<AudioService>().playSaveSuccess();
                historyNotifier.addEntry(
                  ImageEntry(
                    filePath: saveResult.filePath!,
                    metadataPath: saveResult.metadataPath!,
                    sourceType: ImageSourceType.web,
                    savedAt: DateTime.now().toUtc(),
                  ),
                );
                await imageLibrary.addOrUpdate(File(saveResult.filePath!));
              } else {
                watcherStatus.setError('image_save_failed');
              }
              monitor.onSaveCompleted(saveResult);
            },
            onTextCaptured: (text) async {
              SaveResult saveResult;
              try {
                saveResult = await textSaver.saveTextData(
                  text,
                  sourceType: ImageSourceType.local,
                );
              } catch (error, stackTrace) {
                Logger(
                  'ClipboardMonitorHandler',
                ).severe('Text save failed', error, stackTrace);
                saveResult = SaveResult.failed(error: error);
              }
              if (saveResult.isSuccess) {
                context.read<AudioService>().playSaveSuccess();
                final historyNotifier = context.read<ImageHistoryNotifier>();
                historyNotifier.addEntry(
                  ImageEntry(
                    filePath: saveResult.filePath!,
                    metadataPath: saveResult.metadataPath!,
                    sourceType: ImageSourceType.local,
                    savedAt: DateTime.now().toUtc(),
                  ),
                );
                await imageLibrary.addOrUpdate(File(saveResult.filePath!));
              }
              monitor.onSaveCompleted(saveResult);
            },
          );
          copyService.registerMonitor(monitor);
          return monitor;
        },
      ),
      ProxyProvider2<WatcherStatusNotifier, ImageLibraryNotifier,
          FileWatcherService>(
        update: (context, watcherStatus, imageLibrary, previous) {
          previous?.stop();
          final historyNotifier = context.read<ImageHistoryNotifier>();
          return FileWatcherService(
            watcherStatus: watcherStatus,
            onFileAdded: (file) => imageLibrary.addOrUpdate(file),
            onFileDeleted: (path) {
              imageLibrary.remove(path);
              historyNotifier.removeEntry(path);
            },
            onStructureChanged: () => imageLibrary.refresh(),
          );
        },
        dispose: (_, service) => service.stop(),
      ),
    ];

    return MultiProvider(
      providers: providersList,
      child: MaterialApp(
        title: 'ClipPix',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: Consumer2<OnboardingRepository, GuideRepository>(
          builder: (context, onboardingRepo, guideRepo, _) {
            if (!onboardingRepo.hasCompletedOnboarding) {
              return OnboardingScreen(
                onComplete: () {
                  onboardingRepo.markSessionCompleted();
                  guideRepo.resetGuide(); // チュートリアル後にガイドも表示（永続化フラグもリセット）
                },
              );
            }
            return MainScreen(
              showGuide: !guideRepo.hasCompletedFirstGuide,
            );
          },
        ),
      ),
    );
  }
}
