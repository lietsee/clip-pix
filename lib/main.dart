import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_state_notifier/flutter_state_notifier.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

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
import 'data/models/text_content_item.dart';
import 'system/app_lifecycle_service.dart';
import 'system/clipboard_copy_service.dart';
import 'system/clipboard_monitor.dart';
import 'system/folder_picker_service.dart';
import 'system/file_watcher.dart';
import 'system/image_saver.dart';
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
import 'ui/main_screen.dart';
import 'ui/image_preview_window.dart';
import 'ui/widgets/text_preview_window.dart';
import 'system/window_bounds_service.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final previewIndex = args.indexOf('--preview');
  if (previewIndex != -1 && previewIndex + 1 < args.length) {
    await _launchPreviewMode(args[previewIndex + 1]);
    return;
  }

  final previewTextIndex = args.indexOf('--preview-text');
  if (previewTextIndex != -1 && previewTextIndex + 1 < args.length) {
    await _launchTextPreviewMode(args[previewTextIndex + 1]);
    return;
  }

  debugPrint('main start; Platform.isWindows=${Platform.isWindows}');
  _configureLogging();

  await Hive.initFlutter();
  _registerHiveAdapters();
  final boxes = await _openCoreBoxes();

  runZonedGuarded(
    () => runApp(
      ClipPixApp(
        appStateBox: boxes.appStateBox,
        imageHistoryBox: boxes.imageHistoryBox,
        gridCardPrefBox: boxes.gridCardPrefBox,
        gridLayoutBox: boxes.gridLayoutBox,
        gridOrderBox: boxes.gridOrderBox,
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
    final line =
        '[${record.level.name}] ${record.time.toIso8601String()} ${record.loggerName}: ${record.message}';
    debugPrint(line);
    try {
      sink?..writeln(line);
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
}

Future<
    ({
      Box<dynamic> appStateBox,
      Box<dynamic> imageHistoryBox,
      Box<GridCardPreference> gridCardPrefBox,
      Box<dynamic> gridLayoutBox,
      Box<dynamic> gridOrderBox,
    })> _openCoreBoxes() async {
  final appStateBox = await Hive.openBox<dynamic>('app_state');
  final imageHistoryBox = await Hive.openBox<dynamic>('image_history');
  final gridCardPrefBox = await Hive.openBox<GridCardPreference>(
    'grid_card_prefs',
  );
  final gridLayoutBox = await Hive.openBox<dynamic>('grid_layout');
  final gridOrderBox = await Hive.openBox<dynamic>('grid_order');
  return (
    appStateBox: appStateBox,
    imageHistoryBox: imageHistoryBox,
    gridCardPrefBox: gridCardPrefBox,
    gridLayoutBox: gridLayoutBox,
    gridOrderBox: gridOrderBox,
  );
}

Future<void> _launchPreviewMode(String payload) async {
  _configureLogging();
  Map<String, dynamic> data;
  try {
    data = jsonDecode(payload) as Map<String, dynamic>;
  } catch (error) {
    Logger('ImagePreviewWindow').severe('Invalid preview payload', error);
    return;
  }

  final itemMap = (data['item'] as Map<String, dynamic>?);
  if (itemMap == null) {
    Logger('ImagePreviewWindow').warning('Preview payload missing item');
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
    sourceType: ImageSourceType.values[(itemMap['sourceType'] as int?) ?? 0],
    savedAt: savedAt,
    source: itemMap['source'] as String?,
  );

  final initialTop = data['alwaysOnTop'] as bool? ?? false;
  final copyService = ClipboardCopyService();

  runApp(
    _PreviewApp(
      item: item,
      copyService: copyService,
      initialAlwaysOnTop: initialTop,
    ),
  );
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp({
    required this.item,
    required this.copyService,
    required this.initialAlwaysOnTop,
  });

  final ImageItem item;
  final ClipboardCopyService copyService;
  final bool initialAlwaysOnTop;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: ImagePreviewWindow(
        item: item,
        initialAlwaysOnTop: initialAlwaysOnTop,
        onCopyImage: (image) => copyService.copyImage(image),
        onClose: () => exit(0),
        onToggleAlwaysOnTop: (_) {},
      ),
    );
  }
}

Future<void> _launchTextPreviewMode(String payload) async {
  _configureLogging();
  Map<String, dynamic> data;
  try {
    data = jsonDecode(payload) as Map<String, dynamic>;
  } catch (error) {
    Logger('TextPreviewWindow').severe('Invalid preview payload', error);
    return;
  }

  final itemMap = (data['item'] as Map<String, dynamic>?);
  if (itemMap == null) {
    Logger('TextPreviewWindow').warning('Preview payload missing item');
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
    sourceType: ImageSourceType.values[(itemMap['sourceType'] as int?) ?? 0],
    savedAt: savedAt,
    source: itemMap['source'] as String?,
    fontSize: (itemMap['fontSize'] as num?)?.toDouble() ?? 14.0,
    memo: itemMap['memo'] as String? ?? '',
    favorite: itemMap['favorite'] as int? ?? 0,
  );

  final initialTop = data['alwaysOnTop'] as bool? ?? false;

  runApp(
    _TextPreviewApp(
      item: item,
      initialAlwaysOnTop: initialTop,
    ),
  );
}

class _TextPreviewApp extends StatelessWidget {
  const _TextPreviewApp({
    required this.item,
    required this.initialAlwaysOnTop,
  });

  final TextContentItem item;
  final bool initialAlwaysOnTop;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: TextPreviewWindow(
        item: item,
        initialAlwaysOnTop: initialAlwaysOnTop,
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
    required this.imageHistoryBox,
    required this.gridCardPrefBox,
    required this.gridLayoutBox,
    required this.gridOrderBox,
  });

  final Box<dynamic> appStateBox;
  final Box<dynamic> imageHistoryBox;
  final Box<GridCardPreference> gridCardPrefBox;
  final Box<dynamic> gridLayoutBox;
  final Box<dynamic> gridOrderBox;

  @override
  Widget build(BuildContext context) {
    debugPrint('[ClipPixApp] building; isWindows=${Platform.isWindows}');
    final List<SingleChildWidget> providersList = <SingleChildWidget>[
      ...AppStateProvider.providers(
        appStateBox: appStateBox,
        imageHistoryBox: imageHistoryBox,
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
        ),
      ),
      Provider<FolderPickerService>(create: (_) => FolderPickerService()),
      Provider<UrlDownloadService>(
        create: (_) => UrlDownloadService(),
        dispose: (_, service) => service.dispose(),
      ),
      Provider<ClipboardCopyService>(create: (_) => ClipboardCopyService()),
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
      if (Platform.isWindows)
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
      ProxyProvider5<ImageSaver, TextSaver, ClipboardCopyService,
          UrlDownloadService, ImageLibraryNotifier, ClipboardMonitor>(
        update: (
          context,
          imageSaver,
          textSaver,
          copyService,
          downloadService,
          imageLibrary,
          previous,
        ) {
          previous?.dispose();
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
        dispose: (_, monitor) => monitor.dispose(),
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
