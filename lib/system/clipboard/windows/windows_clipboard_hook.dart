/// Windows-specific clipboard hook implementation using Win32 API.
///
/// Uses SetWinEventHook to receive clipboard change notifications.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:win32/win32.dart';

const int _eventSystemClipboard = 0x00000006;
const int _wineventOutOfContext = 0x0000;
const int _wineventSkipOwnProcess = 0x0002;

/// Creates a Windows clipboard hook.
///
/// Returns a [ClipboardHook] instance for Windows platform.
ClipboardHook createClipboardHook(
  FutureOr<void> Function() onEvent,
  Logger logger,
) {
  return _Win32ClipboardHook(onEvent, logger);
}

/// Abstract interface for clipboard hooks.
abstract class ClipboardHook {
  Future<bool> start();
  Future<void> stop();
}

class _Win32ClipboardHook implements ClipboardHook {
  _Win32ClipboardHook(this._onEvent, this._logger);

  final FutureOr<void> Function() _onEvent;
  final Logger _logger;

  Isolate? _isolate;
  SendPort? _controlPort;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _stoppedCompleter;

  @override
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

  @override
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
