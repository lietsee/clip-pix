import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:win32/win32.dart';

import '../data/models/image_source_type.dart';
import 'clipboard/clipboard_service.dart';
import 'image_saver.dart';

typedef ImageCapturedCallback = Future<void> Function(
  Uint8List imageData, {
  String? source,
  ImageSourceType sourceType,
});

typedef UrlCapturedCallback = Future<void> Function(String url);

typedef TextCapturedCallback = Future<void> Function(String text);

enum ClipboardMonitorMode { hook, polling }

enum _ClipboardEventType { image, url, text }

const int _eventSystemClipboard = 0x00000006;
const int _wineventOutOfContext = 0x0000;
const int _wineventSkipOwnProcess = 0x0002;

class _ClipboardEvent {
  _ClipboardEvent.image({
    required this.timestamp,
    required this.imageData,
    this.source,
    required this.sourceType,
  })  : type = _ClipboardEventType.image,
        url = null,
        text = null;

  _ClipboardEvent.url({
    required this.timestamp,
    required this.url,
  })  : type = _ClipboardEventType.url,
        imageData = null,
        source = null,
        sourceType = ImageSourceType.web,
        text = null;

  _ClipboardEvent.text({
    required this.timestamp,
    required this.text,
  })  : type = _ClipboardEventType.text,
        imageData = null,
        source = null,
        sourceType = ImageSourceType.local,
        url = null;

  final DateTime timestamp;
  final _ClipboardEventType type;
  final Uint8List? imageData;
  final String? source;
  final ImageSourceType sourceType;
  final String? url;
  final String? text;
}

abstract class ClipboardMonitorGuard {
  void setGuardToken(String token, Duration ttl);
  void clearGuardToken();
}

class ClipboardMonitor extends ChangeNotifier implements ClipboardMonitorGuard {
  ClipboardMonitor({
    required Directory? Function() getSelectedFolder,
    required ImageCapturedCallback onImageCaptured,
    required UrlCapturedCallback onUrlCaptured,
    required TextCapturedCallback onTextCaptured,
    ClipboardReader? reader,
    Logger? logger,
    Duration duplicateWindow = const Duration(seconds: 2),
    Duration queueResumeDelay = const Duration(milliseconds: 150),
    int maxQueueSize = 10,
  })  : _getSelectedFolder = getSelectedFolder,
        _onImageCaptured = onImageCaptured,
        _onUrlCaptured = onUrlCaptured,
        _onTextCaptured = onTextCaptured,
        _reader = reader ?? ClipboardServiceFactory.createReader(),
        _logger = logger ?? Logger('ClipboardMonitor'),
        _duplicateWindow = duplicateWindow,
        _queueResumeDelay = queueResumeDelay,
        _maxQueueSize = maxQueueSize;

  final Directory? Function() _getSelectedFolder;
  final ImageCapturedCallback _onImageCaptured;
  final UrlCapturedCallback _onUrlCaptured;
  final TextCapturedCallback _onTextCaptured;
  final ClipboardReader _reader;
  final Logger _logger;
  final Duration _duplicateWindow;
  final Duration _queueResumeDelay;
  final int _maxQueueSize;

  ClipboardMonitorMode _mode = ClipboardMonitorMode.hook;
  bool _isRunning = false;
  bool _isProcessing = false;
  bool _isImageSaverBusy = false;
  final Queue<_ClipboardEvent> _eventQueue = Queue<_ClipboardEvent>();
  final Map<String, DateTime> _recentHashes = <String, DateTime>{};

  String? _guardToken;
  DateTime? _guardExpiry;

  Timer? _pollingTimer;
  Timer? _sequenceWatcher;
  int? _lastSequenceNumber;
  int? _baselineSequenceNumber;
  bool _hasSequenceAdvanced = false;
  bool _sequenceCheckInProgress = false;
  final Set<String> _sessionHashes = <String>{};
  _Win32ClipboardHook? _hook;

  ClipboardMonitorMode get mode => _mode;
  bool get isRunning => _isRunning;

  Future<void> start() async {
    if (_isRunning) {
      return;
    }
    final folder = _getSelectedFolder();
    if (folder == null) {
      _logger.info('Clipboard monitor start skipped: no selected folder');
      return;
    }
    _isRunning = true;
    _baselineSequenceNumber = _reader.getChangeCount();
    _hasSequenceAdvanced = false;
    _startSequenceWatcher();
    await _initializeHook();
    notifyListeners();
  }

  Future<void> stop() async {
    if (!_isRunning) {
      return;
    }
    _isRunning = false;
    await _disposeHook();
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _stopSequenceWatcher();
    _eventQueue.clear();
    _lastSequenceNumber = null;
    _baselineSequenceNumber = null;
    _hasSequenceAdvanced = false;
    _sessionHashes.clear();
    notifyListeners();
  }

  Future<void> onFolderChanged(Directory? directory) async {
    if (directory == null) {
      await stop();
      return;
    }
    if (_isRunning) {
      await stop();
    }
    await start();
  }

  void onSaveCompleted(SaveResult result) {
    _isImageSaverBusy = false;
    _scheduleQueueDrain();
  }

  @override
  void setGuardToken(String token, Duration ttl) {
    _guardToken = token;
    _guardExpiry = DateTime.now().add(ttl);
  }

  @override
  void clearGuardToken() {
    _guardToken = null;
    _guardExpiry = null;
  }

  bool get _isGuardActive {
    final expiry = _guardExpiry;
    final token = _guardToken;
    if (expiry == null || token == null) {
      return false;
    }
    if (DateTime.now().isAfter(expiry)) {
      clearGuardToken();
      return false;
    }
    return true;
  }

  Future<void> handleClipboardImage(
    Uint8List imageData, {
    String? source,
    ImageSourceType sourceType = ImageSourceType.local,
  }) async {
    if (!_isRunning) {
      return;
    }
    if (_isGuardActive) {
      _logger.fine('Clipboard image ignored due to guard token $_guardToken');
      return;
    }

    final hash = _hashBytes(imageData);
    if (_isDuplicate(hash)) {
      _logger.fine('Duplicate clipboard image ignored');
      return;
    }

    if (_sessionHashes.contains(hash)) {
      _logger.fine('Clipboard image ignored due to session duplicate hash');
      return;
    }
    _recentHashes[hash] = DateTime.now();
    _sessionHashes.add(hash);
    _enqueueEvent(
      _ClipboardEvent.image(
        timestamp: DateTime.now(),
        imageData: imageData,
        source: source,
        sourceType: sourceType,
      ),
    );
  }

  Future<void> handleClipboardUrl(String url) async {
    if (!_isRunning) {
      return;
    }
    if (_isGuardActive) {
      _logger.fine('Clipboard URL ignored due to guard token $_guardToken');
      return;
    }

    final normalized = _normalizeUrl(url);
    if (normalized == null) {
      _logger.fine('Clipboard text is not a valid URL: $url');
      return;
    }

    final hash = normalized;
    if (_isDuplicate(hash)) {
      _logger.fine('Duplicate clipboard URL ignored');
      return;
    }

    _recentHashes[hash] = DateTime.now();
    _enqueueEvent(
      _ClipboardEvent.url(
        timestamp: DateTime.now(),
        url: normalized,
      ),
    );
  }

  /// クリップボードからの平文テキストを処理
  Future<void> handleClipboardText(String text) async {
    if (!_isRunning) {
      return;
    }
    if (_isGuardActive) {
      _logger.fine('Clipboard text ignored due to guard token $_guardToken');
      return;
    }

    // URLかどうかチェック
    final normalizedUrl = _normalizeUrl(text);
    if (normalizedUrl != null) {
      // URLの場合はURL処理に委譲
      await handleClipboardUrl(text);
      return;
    }

    // 平文テキストとして処理
    final hash = _hashString(text);
    if (_isDuplicate(hash)) {
      _logger.fine('Duplicate clipboard text ignored');
      return;
    }

    _recentHashes[hash] = DateTime.now();
    _enqueueEvent(
      _ClipboardEvent.text(
        timestamp: DateTime.now(),
        text: text,
      ),
    );
  }

  @override
  void dispose() {
    stop();
    _reader.dispose();
    super.dispose();
  }

  Future<void> _initializeHook() async {
    if (!Platform.isWindows) {
      _logger.info(
          'Clipboard hook unsupported on ${Platform.operatingSystem}; using polling');
      _activatePollingFallback();
      return;
    }

    _hook ??= _Win32ClipboardHook(_handleHookEvent, _logger);
    final success = await _hook!.start();
    if (success) {
      _pollingTimer?.cancel();
      _pollingTimer = null;
      _mode = ClipboardMonitorMode.hook;
      _logger.info('Clipboard hook initialized');
    } else {
      _logger.warning(
          'Clipboard hook initialization failed, falling back to polling');
      await _hook?.stop();
      _hook = null;
      _activatePollingFallback();
    }
  }

  Future<void> _disposeHook() async {
    await _hook?.stop();
    _hook = null;
  }

  void _activatePollingFallback() {
    _mode = ClipboardMonitorMode.polling;
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollClipboard(),
    );
  }

  Future<void> _handleHookEvent() async {
    await _processClipboardSnapshot();
  }

  Future<void> _pollClipboard() async {
    await _processClipboardSnapshot();
  }

  Future<void> _processClipboardSnapshot() async {
    if (!_isRunning) {
      return;
    }
    if (_sequenceCheckInProgress) {
      return;
    }
    _sequenceCheckInProgress = true;
    try {
      final currentSequence = _reader.getChangeCount();
      if (!_hasSequenceAdvanced) {
        if (_baselineSequenceNumber == null) {
          _baselineSequenceNumber = currentSequence;
          _logger.fine('Clipboard baseline sequence set to $currentSequence');
          return;
        }
        if (currentSequence == _baselineSequenceNumber) {
          _logger.fine('Skipping clipboard snapshot (baseline sequence)');
          return;
        }
        _hasSequenceAdvanced = true;
      }
      if (currentSequence != 0) {
        _lastSequenceNumber = currentSequence;
      }
      final content = await _reader.read();
      if (content == null) {
        return;
      }
      if (content.hasImage) {
        await handleClipboardImage(content.imageData!,
            sourceType: content.sourceType);
        return;
      }
      if (content.hasText) {
        await handleClipboardText(content.text!);
      }
    } catch (error, stackTrace) {
      _logger.warning(
          'Failed to process clipboard snapshot', error, stackTrace);
    } finally {
      _sequenceCheckInProgress = false;
    }
  }

  void _enqueueEvent(_ClipboardEvent event) {
    if (_eventQueue.length >= _maxQueueSize) {
      final dropped = _eventQueue.removeFirst();
      _logger
          .warning('queue_drop oldest=${dropped.timestamp.toIso8601String()}');
    }
    _eventQueue.add(event);
    _scheduleQueueDrain();
  }

  void _scheduleQueueDrain() {
    if (_isProcessing || _isImageSaverBusy) {
      return;
    }
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _isImageSaverBusy) {
      return;
    }
    if (_eventQueue.isEmpty) {
      return;
    }

    _isProcessing = true;
    while (_eventQueue.isNotEmpty && !_isImageSaverBusy) {
      final event = _eventQueue.removeFirst();
      switch (event.type) {
        case _ClipboardEventType.image:
          final imageData = event.imageData!;
          _isImageSaverBusy = true;
          await _onImageCaptured(
            imageData,
            source: event.source,
            sourceType: event.sourceType,
          );
          break;
        case _ClipboardEventType.url:
          final url = event.url!;
          _isImageSaverBusy = true;
          await _onUrlCaptured(url);
          if (_isImageSaverBusy) {
            _isImageSaverBusy = false;
          }
          break;
        case _ClipboardEventType.text:
          final text = event.text!;
          _isImageSaverBusy = true;
          await _onTextCaptured(text);
          if (_isImageSaverBusy) {
            _isImageSaverBusy = false;
          }
          break;
      }
    }
    _isProcessing = false;

    if (_eventQueue.isNotEmpty && !_isImageSaverBusy) {
      await Future<void>.delayed(_queueResumeDelay);
      _processQueue();
    }
  }

  void _startSequenceWatcher() {
    _sequenceWatcher ??= Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _checkClipboardSequence(),
    );
  }

  void _stopSequenceWatcher() {
    _sequenceWatcher?.cancel();
    _sequenceWatcher = null;
  }

  Future<void> _checkClipboardSequence() async {
    if (!_isRunning) {
      return;
    }
    final sequence = _reader.getChangeCount();
    if (sequence == 0) {
      return;
    }
    if (_baselineSequenceNumber != null &&
        !_hasSequenceAdvanced &&
        sequence == _baselineSequenceNumber) {
      return;
    }
    if (_lastSequenceNumber != null && _lastSequenceNumber == sequence) {
      return;
    }
    _lastSequenceNumber = sequence;
    if (_baselineSequenceNumber != null &&
        sequence != _baselineSequenceNumber) {
      _hasSequenceAdvanced = true;
    }
    _logger.fine('Clipboard sequence changed: $sequence');
    await _processClipboardSnapshot();
  }

  bool _isDuplicate(String hash) {
    final now = DateTime.now();
    _recentHashes.removeWhere(
      (key, value) => now.difference(value) > _duplicateWindow,
    );
    return _recentHashes.containsKey(hash);
  }

  String _hashBytes(Uint8List bytes) {
    final digest = sha1.convert(bytes);
    return digest.toString();
  }

  String _hashString(String text) {
    final bytes = text.codeUnits;
    final digest = sha1.convert(bytes);
    return digest.toString();
  }

  String? _normalizeUrl(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    return uri.toString();
  }
}

class _Win32ClipboardHook {
  _Win32ClipboardHook(this._onEvent, this._logger);

  final FutureOr<void> Function() _onEvent;
  final Logger _logger;

  Isolate? _isolate;
  SendPort? _controlPort;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _stoppedCompleter;

  Future<bool> start() async {
    if (_isolate != null) {
      return true;
    }

    final readyCompleter = Completer<bool>();
    final stoppedCompleter = Completer<void>();
    _stoppedCompleter = stoppedCompleter;

    final eventPort = ReceivePort();
    _subscription = eventPort.listen((message) {
      if (message is SendPort) {
        _controlPort = message;
        return;
      }
      if (message is List && message.isNotEmpty) {
        final type = message[0];
        switch (type) {
          case 'ready':
            if (!readyCompleter.isCompleted) {
              readyCompleter
                  .complete((message.length > 1 ? message[1] : false) as bool);
            }
            break;
          case 'event':
            Future.microtask(() => _onEvent());
            break;
          case 'error':
            final code = message.length > 1 ? message[1] : null;
            _logger.warning('Clipboard hook error code=$code');
            break;
          case 'stopped':
            if (!stoppedCompleter.isCompleted) {
              stoppedCompleter.complete();
            }
            break;
        }
      }
    });

    _isolate = await Isolate.spawn<_HookInitMessage>(
      _clipboardHookIsolate,
      _HookInitMessage(eventPort.sendPort),
      debugName: 'clipboard_hook',
    );

    final success = await readyCompleter.future;
    if (!success) {
      await stop();
    }
    return success;
  }

  Future<void> stop() async {
    final control = _controlPort;
    _controlPort = null;
    final stopped = _stoppedCompleter;

    if (control != null) {
      control.send('stop');
      if (stopped != null && !stopped.isCompleted) {
        try {
          await stopped.future.timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }

    await _subscription?.cancel();
    _subscription = null;
    _stoppedCompleter = null;

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

class _HookInitMessage {
  const _HookInitMessage(this.mainPort);

  final SendPort mainPort;
}

class _HookState {
  _HookState({
    required this.mainPort,
    required this.unhook,
  });

  final SendPort mainPort;
  final _UnhookWinEventDart unhook;
  ffi.Pointer<ffi.Void> hookHandle = ffi.Pointer.fromAddress(0);

  static _HookState? instance;
}

typedef _SetWinEventHookNative = ffi.Pointer<ffi.Void> Function(
  ffi.Uint32 eventMin,
  ffi.Uint32 eventMax,
  ffi.Pointer<ffi.Void> hmodWinEventProc,
  ffi.Pointer<ffi.NativeFunction<_WinEventProcNative>> lpfnWinEventProc,
  ffi.Uint32 idProcess,
  ffi.Uint32 idThread,
  ffi.Uint32 dwFlags,
);

typedef _SetWinEventHookDart = ffi.Pointer<ffi.Void> Function(
  int eventMin,
  int eventMax,
  ffi.Pointer<ffi.Void> hmodWinEventProc,
  ffi.Pointer<ffi.NativeFunction<_WinEventProcNative>> lpfnWinEventProc,
  int idProcess,
  int idThread,
  int dwFlags,
);

typedef _UnhookWinEventNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> hWinEventHook);
typedef _UnhookWinEventDart = int Function(ffi.Pointer<ffi.Void> hWinEventHook);

typedef _WinEventProcNative = ffi.Void Function(
  ffi.Pointer<ffi.Void> hWinEventHook,
  ffi.Uint32 event,
  ffi.Pointer<ffi.Void> hwnd,
  ffi.Int32 idObject,
  ffi.Int32 idChild,
  ffi.Uint32 dwEventThread,
  ffi.Uint32 dwmsEventTime,
);

final ffi.Pointer<ffi.NativeFunction<_WinEventProcNative>> _callbackPointer =
    ffi.Pointer.fromFunction<_WinEventProcNative>(_winEventProc);

void _clipboardHookIsolate(_HookInitMessage message) {
  final mainPort = message.mainPort;
  final controlPort = ReceivePort();
  mainPort.send(controlPort.sendPort);

  final user32 = ffi.DynamicLibrary.open('user32.dll');
  final setWinEventHook =
      user32.lookupFunction<_SetWinEventHookNative, _SetWinEventHookDart>(
    'SetWinEventHook',
  );
  final unhookWinEvent =
      user32.lookupFunction<_UnhookWinEventNative, _UnhookWinEventDart>(
    'UnhookWinEvent',
  );

  _HookState.instance = _HookState(mainPort: mainPort, unhook: unhookWinEvent);

  final hookHandle = setWinEventHook(
    _eventSystemClipboard,
    _eventSystemClipboard,
    ffi.Pointer.fromAddress(0),
    _callbackPointer,
    0,
    0,
    _wineventOutOfContext | _wineventSkipOwnProcess,
  );

  if (hookHandle.address == 0) {
    final error = GetLastError();
    mainPort.send(['ready', false, error]);
    controlPort.close();
    _HookState.instance = null;
    return;
  }

  _HookState.instance!.hookHandle = hookHandle;
  mainPort.send(['ready', true]);

  controlPort.listen((message) {
    if (message == 'stop') {
      try {
        final handle = _HookState.instance?.hookHandle;
        if (handle != null && handle.address != 0) {
          _HookState.instance?.unhook(handle);
        }
      } finally {
        mainPort.send(['stopped']);
        controlPort.close();
        _HookState.instance = null;
      }
    }
  });
}

void _winEventProc(
  ffi.Pointer<ffi.Void> hWinEventHook,
  int event,
  ffi.Pointer<ffi.Void> hwnd,
  int idObject,
  int idChild,
  int dwEventThread,
  int dwmsEventTime,
) {
  if (event == _eventSystemClipboard) {
    _HookState.instance?.mainPort.send(['event']);
  }
}
