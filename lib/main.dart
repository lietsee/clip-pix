import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'data/models/image_entry.dart';
import 'data/models/image_item.dart';
import 'data/models/image_source_type.dart';
import 'system/clipboard_copy_service.dart';
import 'system/clipboard_monitor.dart';
import 'system/file_watcher.dart';
import 'system/image_saver.dart';
import 'system/state/app_state_provider.dart';
import 'system/state/image_history_notifier.dart';
import 'system/state/selected_folder_state.dart';
import 'system/state/watcher_status_notifier.dart';
import 'ui/main_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _configureLogging();

  await Hive.initFlutter();
  _registerHiveAdapters();
  final boxes = await _openCoreBoxes();

  runZonedGuarded(
    () => runApp(
      ClipPixApp(
        appStateBox: boxes.appStateBox,
        imageHistoryBox: boxes.imageHistoryBox,
      ),
    ),
    (error, stackTrace) => Logger('ClipPixApp').severe(
      'Uncaught zone error',
      error,
      stackTrace,
    ),
  );
}

void _configureLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen(
    (record) => debugPrint(
      '[${record.level.name}] ${record.time.toIso8601String()} '
      '${record.loggerName}: ${record.message}',
    ),
  );
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
}

Future<({Box<dynamic> appStateBox, Box<dynamic> imageHistoryBox})>
    _openCoreBoxes() async {
  final appStateBox = await Hive.openBox<dynamic>('app_state');
  final imageHistoryBox = await Hive.openBox<dynamic>('image_history');
  return (appStateBox: appStateBox, imageHistoryBox: imageHistoryBox);
}

class ClipPixApp extends StatelessWidget {
  const ClipPixApp({
    super.key,
    required this.appStateBox,
    required this.imageHistoryBox,
  });

  final Box<dynamic> appStateBox;
  final Box<dynamic> imageHistoryBox;

  @override
  Widget build(BuildContext context) {
    final List<SingleChildWidget> providersList = <SingleChildWidget>[
      ...AppStateProvider.providers(
        appStateBox: appStateBox,
        imageHistoryBox: imageHistoryBox,
      ),
      Provider<ClipboardCopyService>(
        create: (_) => ClipboardCopyService(),
      ),
      Provider<ImageSaver>(
        create: (context) => ImageSaver(
          getSelectedFolder: () => context.read<SelectedFolderState>().current,
        ),
      ),
      ProxyProvider2<ImageSaver, ClipboardCopyService, ClipboardMonitor>(
        update: (context, imageSaver, copyService, previous) {
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
                Logger('ClipboardMonitorHandler')
                    .severe('Image save failed', error, stackTrace);
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
              } else {
                context
                    .read<WatcherStatusNotifier>()
                    .setError('image_save_failed');
              }
              monitor.onSaveCompleted(result);
            },
            onUrlCaptured: (url) async {
              Logger('ClipboardMonitorHandler').info('URL captured: $url');
              // TODO: implement URL download pipeline.
            },
          );
          copyService.registerMonitor(monitor);
          return monitor;
        },
        dispose: (_, monitor) => monitor.dispose(),
      ),
      ProxyProvider<WatcherStatusNotifier, FileWatcherService>(
        update: (context, watcherStatus, previous) {
          previous?.stop();
          return FileWatcherService(
            watcherStatus: watcherStatus,
            onFileAdded: (file) {
              Logger('FileWatcherHandler').info('File added: ${file.path}');
            },
            onFileDeleted: (path) {
              Logger('FileWatcherHandler').info('File deleted: $path');
            },
            onStructureChanged: () {
              Logger('FileWatcherHandler').info('Folder structure changed');
            },
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
