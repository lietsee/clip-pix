import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'image_history_notifier.dart';
import 'image_history_state.dart';
import 'selected_folder_notifier.dart';
import 'selected_folder_state.dart';
import 'watcher_status_notifier.dart';
import 'watcher_status_state.dart';

class AppStateProvider {
  static List<SingleChildWidget> providers({
    required Box<dynamic> appStateBox,
    required Box<dynamic> imageHistoryBox,
  }) {
    return <SingleChildWidget>[
      StateNotifierProvider<SelectedFolderNotifier, SelectedFolderState>(
        create: (_) => SelectedFolderNotifier(appStateBox),
      ),
      StateNotifierProvider<WatcherStatusNotifier, WatcherStatusState>(
        create: (_) => WatcherStatusNotifier(),
      ),
      StateNotifierProvider<ImageHistoryNotifier, ImageHistoryState>(
        create: (_) => ImageHistoryNotifier(imageHistoryBox),
      ),
    ];
  }
}
