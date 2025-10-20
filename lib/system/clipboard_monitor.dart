import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:win32/win32.dart';

import '../data/models/image_source_type.dart';
import 'image_saver.dart';

typedef ImageCapturedCallback = Future<void> Function(
  Uint8List imageData, {
  String? source,
  ImageSourceType sourceType,
});

typedef UrlCapturedCallback = Future<void> Function(String url);

enum ClipboardMonitorMode { hook, polling }

enum _ClipboardEventType { image, url }

const int _eventSystemClipboard = 0x0000800d;
const int _wineventOutOfContext = 0x0000;
const int _wineventSkipOwnProcess = 0x0002;

class _ClipboardEvent {
  _ClipboardEvent.image({
    required this.timestamp,
    required this.imageData,
    this.source,
    required this.sourceType,
  })  : type = _ClipboardEventType.image,
        url = null;

  _ClipboardEvent.url({
    required this.timestamp,
    required this.url,
  })  : type = _ClipboardEventType.url,
        imageData = null,
        source = null,
        sourceType = ImageSourceType.web;

  final DateTime timestamp;
  final _ClipboardEventType type;
  final Uint8List? imageData;
  final String? source;
  final ImageSourceType sourceType;
  final String? url;
}

abstract class ClipboardMonitorGuard {
  void setGuardToken(String token, Duration ttl);
  void clearGuardToken();
}

class ClipboardMonitor implements ClipboardMonitorGuard {
  ClipboardMonitor({
    required Directory? Function() getSelectedFolder,
    required ImageCapturedCallback onImageCaptured,
    required UrlCapturedCallback onUrlCaptured,
    Logger? logger,
    Duration duplicateWindow = const Duration(seconds: 2),
    Duration queueResumeDelay = const Duration(milliseconds: 150),
    int maxQueueSize = 10,
  })  : _getSelectedFolder = getSelectedFolder,
        _onImageCaptured = onImageCaptured,
        _onUrlCaptured = onUrlCaptured,
        _logger = logger ?? Logger('ClipboardMonitor'),
        _duplicateWindow = duplicateWindow,
        _queueResumeDelay = queueResumeDelay,
        _maxQueueSize = maxQueueSize;

  final Directory? Function() _getSelectedFolder;
  final ImageCapturedCallback _onImageCaptured;
  final UrlCapturedCallback _onUrlCaptured;
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
  String? _lastPolledTextSignature;
  _Win32ClipboardHook? _hook;
  int? _pngClipboardFormat;

  ClipboardMonitorMode get mode => _mode;

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
    await _initializeHook();
  }

  Future<void> stop() async {
    if (!_isRunning) {
      return;
    }
    _isRunning = false;
    await _disposeHook();
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _eventQueue.clear();
    _lastPolledTextSignature = null;
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

    _recentHashes[hash] = DateTime.now();
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

  void dispose() {
    stop();
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
    if (!_isRunning) {
      return;
    }
    try {
      final snapshot = _readClipboardSnapshot();
      if (snapshot == null) {
        return;
      }
      if (snapshot.imageData != null) {
        await handleClipboardImage(snapshot.imageData!,
            sourceType: snapshot.sourceType);
        return;
      }
      if (snapshot.text != null) {
        await handleClipboardUrl(snapshot.text!);
      }
    } catch (error, stackTrace) {
      _logger.warning(
          'Failed to process clipboard hook event', error, stackTrace);
    }
  }

  _ClipboardSnapshot? _readClipboardSnapshot() {
    final open = OpenClipboard(NULL);
    if (open == 0) {
      final code = GetLastError();
      _logger.fine('OpenClipboard failed with code $code');
      return null;
    }
    try {
      final image = _readPngFromClipboardLocked();
      if (image != null) {
        return _ClipboardSnapshot(
            imageData: image, sourceType: ImageSourceType.local);
      }
      final text = _readUnicodeTextFromClipboardLocked();
      if (text != null && text.isNotEmpty) {
        return _ClipboardSnapshot(text: text);
      }
      return null;
    } finally {
      CloseClipboard();
    }
  }

  Uint8List? _readPngFromClipboardLocked() {
    final format = _ensurePngFormat();
    if (format == 0) {
      return null;
    }
    final handleValue = GetClipboardData(format);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    final size = GlobalSize(handle);
    if (size <= 0) {
      GlobalUnlock(handle);
      return null;
    }
    final pointer = rawPointer.cast<ffi.Uint8>();
    final data = pointer.asTypedList(size);
    final bytes = Uint8List.fromList(data);
    GlobalUnlock(handle);
    return bytes;
  }

  String? _readUnicodeTextFromClipboardLocked() {
    final handleValue = GetClipboardData(CF_UNICODETEXT);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    final pointer = rawPointer.cast<Utf16>();
    final text = pointer.toDartString();
    GlobalUnlock(handle);
    return text;
  }

  int _ensurePngFormat() {
    final cached = _pngClipboardFormat;
    if (cached != null) {
      return cached;
    }
    final name = 'PNG'.toNativeUtf16();
    try {
      final format = RegisterClipboardFormat(name);
      if (format == 0) {
        final code = GetLastError();
        _logger.fine('RegisterClipboardFormat failed with code $code');
      } else {
        _pngClipboardFormat = format;
      }
      return format;
    } finally {
      calloc.free(name);
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
      }
    }
    _isProcessing = false;

    if (_eventQueue.isNotEmpty && !_isImageSaverBusy) {
      await Future<void>.delayed(_queueResumeDelay);
      _processQueue();
    }
  }

  Future<void> _pollClipboard() async {
    if (!_isRunning) {
      return;
    }
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.isNotEmpty) {
        if (text != _lastPolledTextSignature) {
          _lastPolledTextSignature = text;
          await handleClipboardUrl(text);
        }
      }
    } catch (error, stackTrace) {
      _logger.fine('Clipboard poll failed', error, stackTrace);
    }
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

  String? _normalizeUrl(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    return uri.toString();
  }
}

class _ClipboardSnapshot {
  const _ClipboardSnapshot(
      {this.imageData, this.text, this.sourceType = ImageSourceType.local});

  final Uint8List? imageData;
  final String? text;
  final ImageSourceType sourceType;
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
