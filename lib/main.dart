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
import 'package:window_manager/window_manager.dart';

import 'data/file_info_manager.dart';
import 'data/grid_card_preferences_repository.dart';
import 'data/grid_layout_settings_repository.dart';
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
import 'data/models/text_content_item.dart';
import 'data/models/text_preview_state.dart';
import 'data/image_preview_state_repository.dart';
import 'data/open_previews_repository.dart';
import 'data/text_preview_state_repository.dart';
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
import 'ui/widgets/text_preview_window.dart';
import 'system/window_bounds_service.dart';

/// DEBUG: カード順序番号表示フラグ
/// trueにするとカードの中央に配列インデックスを表示
bool debugShowCardIndex = true;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // DEBUG: ヒットテスト可視化（タブ切り替え後の操作不能バグ調査用）
  debugPaintPointersEnabled = false;

  // 親PIDを取得（プレビューウィンドウが親プロセス終了時に自動終了するため）
  final parentPidIndex = args.indexOf('--parent-pid');
  int? parentPid;
  if (parentPidIndex != -1 && parentPidIndex + 1 < args.length) {
    parentPid = int.tryParse(args[parentPidIndex + 1]);
  }

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

  debugPrint('main start; Platform.isWindows=${Platform.isWindows}');
  _configureLogging();

  // Initialize Hive in AppData\Roaming\Clip-pix
  final Directory hiveDir;
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) {
      throw Exception('APPDATA environment variable not found');
    }
    hiveDir = Directory(p.join(appData, 'Clip-pix'));
  } else {
    final appSupportDir = await getApplicationSupportDirectory();
    hiveDir = Directory(p.join(appSupportDir.path, 'Clip-pix'));
  }
  await hiveDir.create(recursive: true);
  await Hive.initFlutter(hiveDir.path);
  debugPrint('[Hive] Initialized at: ${hiveDir.path}');
  _registerHiveAdapters();
  final boxes = await _openCoreBoxes();

  runZonedGuarded(
    () => runApp(
      ClipPixApp(
        appStateBox: boxes.appStateBox,
        gridCardPrefBox: boxes.gridCardPrefBox,
        gridLayoutBox: boxes.gridLayoutBox,
        gridOrderBox: boxes.gridOrderBox,
        openPreviewsBox: boxes.openPreviewsBox,
      ),
    ),
    (error, stackTrace) =>
        Logger('ClipPixApp').severe('Uncaught zone error', error, stackTrace),
  );
}

void _configureLogging() {
  Logger.root.level = Level.FINE;
  IOSink? sink;
  try {
    final logsDir = Directory('logs');
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

Future<void> _launchPreviewMode(String payload, int? parentPid) async {
  // 親プロセス監視タイマー（親プロセス終了時に自動終了）
  Timer? parentMonitorTimer;
  if (parentPid != null) {
    parentMonitorTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isParentProcessAlive(parentPid)) {
        debugPrint('[ImagePreviewMode] Parent process $parentPid not found, exiting');
        timer.cancel();
        exit(0);
      }
    });
    debugPrint('[ImagePreviewMode] Started parent process monitor for PID: $parentPid');
  }

  await runZonedGuarded(
    () async {
      _configureLogging();
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

      // Initialize window_manager for frameless window
      debugPrint('[ImagePreviewMode] Initializing window manager...');
      await windowManager.ensureInitialized();
      debugPrint('[ImagePreviewMode] Window manager initialized');

      // Initialize Hive with SEPARATE path for this preview process
      ImagePreviewStateRepository? repository;
      Rect? restoredBounds;

      // Generate unique Hive directory name based on item ID
      String getHiveDirectoryName(String itemId) {
        final bytes = utf8.encode(itemId);
        final digest = md5.convert(bytes);
        return 'image_preview_${digest.toString().substring(0, 8)}';
      }

      try {
        final String baseHiveDir;
        if (Platform.isWindows) {
          final appData = Platform.environment['APPDATA'];
          if (appData == null) {
            throw Exception('APPDATA environment variable not found');
          }
          baseHiveDir = p.join(appData, 'Clip-pix');
        } else {
          final appSupportDir = await getApplicationSupportDirectory();
          baseHiveDir = p.join(appSupportDir.path, 'Clip-pix');
        }
        final hiveDir = p.join(baseHiveDir, getHiveDirectoryName(item.id));
        debugPrint(
            '[ImagePreviewMode] Initializing Hive with directory: $hiveDir');
        await Directory(hiveDir).create(recursive: true);
        await Hive.initFlutter(hiveDir); // Unique subdirectory per item
        _registerHiveAdapters();
        await Hive.openBox<ImagePreviewState>('image_preview_state');
        debugPrint('[ImagePreviewMode] Hive initialized successfully');

        // Load saved window bounds
        repository = ImagePreviewStateRepository();
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
          debugPrint('[ImagePreviewMode] Loaded saved bounds: $restoredBounds');
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
      final windowOptions = WindowOptions(
        size: restoredBounds?.size ?? const Size(1200, 800),
        minimumSize: const Size(600, 400),
        center: restoredBounds == null, // Only center if no saved position
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

        // Restore saved position if available
        if (restoredBounds != null) {
          await windowManager.setPosition(
            Offset(restoredBounds.left, restoredBounds.top),
          );
          debugPrint('[ImagePreviewMode] Position restored');
        }

        await windowManager.focus();
        debugPrint('[ImagePreviewMode] Window focused');

        // Run app AFTER window is fully initialized
        // This keeps the event loop alive and prevents early process exit
        runApp(
          _ImagePreviewApp(
            item: item,
            copyService: copyService,
            initialAlwaysOnTop: initialTop,
            repository: repository,
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

class _ImagePreviewApp extends StatelessWidget {
  const _ImagePreviewApp({
    required this.item,
    required this.copyService,
    required this.initialAlwaysOnTop,
    this.repository,
  });

  final ImageItem item;
  final ClipboardCopyService copyService;
  final bool initialAlwaysOnTop;
  final ImagePreviewStateRepository? repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: ImagePreviewWindow(
        item: item,
        initialAlwaysOnTop: initialAlwaysOnTop,
        repository: repository,
        onCopyImage: (image) => copyService.copyImage(image),
        onClose: () => exit(0),
        onToggleAlwaysOnTop: (_) {},
      ),
    );
  }
}

Future<void> _launchTextPreviewMode(String payload, int? parentPid) async {
  // 親プロセス監視タイマー（親プロセス終了時に自動終了）
  Timer? parentMonitorTimer;
  if (parentPid != null) {
    parentMonitorTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
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
      _configureLogging();
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
        final String baseHiveDir;
        if (Platform.isWindows) {
          final appData = Platform.environment['APPDATA'];
          if (appData == null) {
            throw Exception('APPDATA environment variable not found');
          }
          baseHiveDir = p.join(appData, 'Clip-pix');
        } else {
          final appSupportDir = await getApplicationSupportDirectory();
          baseHiveDir = p.join(appSupportDir.path, 'Clip-pix');
        }
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
      final windowOptions = WindowOptions(
        size: restoredBounds?.size ?? const Size(900, 700),
        minimumSize: const Size(400, 300),
        center: restoredBounds == null, // Only center if no saved position
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

        // Restore saved position if available
        if (restoredBounds != null) {
          await windowManager.setPosition(
            Offset(restoredBounds.left, restoredBounds.top),
          );
          debugPrint('[TextPreviewMode] Position restored');
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

class ClipPixApp extends StatelessWidget {
  const ClipPixApp({
    super.key,
    required this.appStateBox,
    required this.gridCardPrefBox,
    required this.gridLayoutBox,
    required this.gridOrderBox,
    required this.openPreviewsBox,
  });

  final Box<dynamic> appStateBox;
  final Box<GridCardPreference> gridCardPrefBox;
  final Box<dynamic> gridLayoutBox;
  final Box<dynamic> gridOrderBox;
  final Box<OpenPreviewItem> openPreviewsBox;

  @override
  Widget build(BuildContext context) {
    debugPrint('[ClipPixApp] building; isWindows=${Platform.isWindows}');
    final openPreviewsRepo = OpenPreviewsRepository();
    final List<SingleChildWidget> providersList = <SingleChildWidget>[
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
        home: const MainScreen(),
      ),
    );
  }
}
