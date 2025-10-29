import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../data/file_info_manager.dart';

/// アプリケーションのライフサイクルイベントを監視し、
/// 終了時にFileInfoManagerをフラッシュするサービス
class AppLifecycleService with WidgetsBindingObserver {
  AppLifecycleService(this._fileInfoManager)
      : _logger = Logger('AppLifecycleService');

  final FileInfoManager _fileInfoManager;
  final Logger _logger;

  void init() {
    WidgetsBinding.instance.addObserver(this);
    _logger.info('AppLifecycleService initialized');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _logger.info('AppLifecycleService disposed');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logger.fine('App lifecycle state changed: $state');

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // アプリが一時停止または終了する前に保存
        _logger.info('Flushing FileInfoManager due to $state');
        _fileInfoManager.flush();
        break;
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // これらの状態では何もしない
        break;
    }
  }
}
