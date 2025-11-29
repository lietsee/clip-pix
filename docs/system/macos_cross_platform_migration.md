# macOS クロスプラットフォーム対応 移行計画

## 概要

ClipPixをWindows専用アプリからWindows/macOS両対応アプリに改修するための技術ドキュメント。

### 現状
- Windows専用（`win32`パッケージに依存）
- クリップボード監視・コピーがWindows APIに直接依存
- ウィンドウ管理がWindows APIに依存

### 目標
- macOSでも同等の機能を提供
- コードベースの保守性を維持
- 将来的なLinux対応も視野に入れた設計

---

## 1. 影響範囲の分析

### 1.1 Windows固有実装の一覧

| ファイル | 機能 | Windows依存度 | 優先度 |
|---------|------|--------------|--------|
| `lib/system/clipboard_monitor.dart` | クリップボード監視 | **高** | P0 |
| `lib/system/clipboard_copy_service.dart` | クリップボードへコピー | **高** | P0 |
| `lib/system/window_bounds_service.dart` | ウィンドウ位置保存/復元 | 中 | P1 |
| `lib/system/screen_bounds_validator.dart` | マルチモニタ検証 | 中 | P1 |
| `lib/ui/image_preview_window.dart` | プレビューウィンドウ | 低 | P2 |
| `lib/ui/widgets/text_preview_window.dart` | テキストプレビュー | 低 | P2 |
| `lib/ui/grid_view_module.dart` | プレビュー復元 | 低 | P2 |
| `lib/ui/main_screen.dart` | プラットフォームチェック | 低 | P2 |

### 1.2 使用中のWindows API

```dart
// clipboard_monitor.dart
import 'package:win32/win32.dart';

// 使用API
GetClipboardSequenceNumber()  // クリップボード変更検出
OpenClipboard() / CloseClipboard()
GetClipboardData(CF_DIBV5 / CF_DIB / CF_UNICODETEXT / PNG)
GlobalLock() / GlobalUnlock() / GlobalSize()
SetWinEventHook() / UnhookWinEvent()  // クリップボードイベントフック
RegisterClipboardFormat()

// clipboard_copy_service.dart
EmptyClipboard()
SetClipboardData()
GlobalAlloc() / GlobalFree()

// window_bounds_service.dart
GetWindowRect() / SetWindowPos()
FindWindow() / GetForegroundWindow()

// screen_bounds_validator.dart
GetSystemMetrics(SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN / SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN)
```

---

## 2. アーキテクチャ設計

### 2.1 抽象化レイヤーの導入

```
┌─────────────────────────────────────────────────────────────┐
│                      Application Layer                       │
│   (main_screen.dart, grid_view_module.dart, etc.)           │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                   Platform Abstraction Layer                 │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────┐│
│  │ClipboardService  │  │WindowService     │  │ScreenService││
│  │(abstract)        │  │(abstract)        │  │(abstract)   ││
│  └────────┬─────────┘  └────────┬─────────┘  └──────┬──────┘│
└───────────┼─────────────────────┼───────────────────┼───────┘
            │                     │                   │
    ┌───────┴───────┐     ┌───────┴───────┐   ┌───────┴───────┐
    │               │     │               │   │               │
┌───▼───┐     ┌─────▼───┐ │               │   │               │
│Windows│     │ macOS   │ │  window_      │   │  screen_      │
│Impl   │     │ Impl    │ │  manager      │   │  retriever    │
│(win32)│     │(Swift)  │ │  (既存pkg)    │   │  (既存pkg)    │
└───────┘     └─────────┘ └───────────────┘   └───────────────┘
```

### 2.2 ディレクトリ構造

```
lib/
├── system/
│   ├── clipboard/
│   │   ├── clipboard_service.dart          # 抽象インターフェース
│   │   ├── clipboard_monitor.dart          # 監視ロジック（共通部分）
│   │   ├── clipboard_copy_service.dart     # コピーロジック（共通部分）
│   │   ├── windows/
│   │   │   ├── windows_clipboard_reader.dart
│   │   │   └── windows_clipboard_writer.dart
│   │   └── macos/
│   │       ├── macos_clipboard_reader.dart
│   │       └── macos_clipboard_writer.dart
│   ├── window/
│   │   ├── window_service.dart             # 抽象インターフェース
│   │   └── window_bounds_service.dart      # window_manager使用に統一
│   └── screen/
│       └── screen_bounds_validator.dart    # クロスプラットフォーム化
```

---

## 3. 実装計画

### Phase 1: クリップボード抽象化 (P0)

#### 3.1.1 抽象インターフェースの定義

**新規作成**: `lib/system/clipboard/clipboard_service.dart`

```dart
import 'dart:typed_data';

import '../data/models/image_source_type.dart';

/// クリップボード読み取り結果
class ClipboardContent {
  const ClipboardContent({
    this.imageData,
    this.text,
    this.sourceType = ImageSourceType.local,
  });

  final Uint8List? imageData;
  final String? text;
  final ImageSourceType sourceType;

  bool get hasImage => imageData != null;
  bool get hasText => text != null;
  bool get isEmpty => !hasImage && !hasText;
}

/// クリップボード読み取りインターフェース
abstract class ClipboardReader {
  /// クリップボードの変更番号を取得（ポーリング用）
  int getChangeCount();

  /// クリップボードの内容を読み取り
  Future<ClipboardContent?> read();

  /// リソース解放
  void dispose();
}

/// クリップボード書き込みインターフェース
abstract class ClipboardWriter {
  /// 画像をクリップボードにコピー
  Future<void> writeImage(Uint8List imageData);

  /// テキストをクリップボードにコピー
  Future<void> writeText(String text);

  /// リソース解放
  void dispose();
}

/// プラットフォーム別ファクトリ
class ClipboardServiceFactory {
  static ClipboardReader createReader() {
    if (Platform.isWindows) {
      return WindowsClipboardReader();
    } else if (Platform.isMacOS) {
      return MacOSClipboardReader();
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  static ClipboardWriter createWriter() {
    if (Platform.isWindows) {
      return WindowsClipboardWriter();
    } else if (Platform.isMacOS) {
      return MacOSClipboardWriter();
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }
}
```

#### 3.1.2 Windows実装の移行

**新規作成**: `lib/system/clipboard/windows/windows_clipboard_reader.dart`

現在の`clipboard_monitor.dart`から以下を抽出:
- `_readClipboardSnapshot()`
- `_readDibV5FromClipboardLocked()`
- `_readPngFromClipboardLocked()`
- `_readDibFromClipboardLocked()`
- `_readUnicodeTextFromClipboardLocked()`
- `_convertDibV5ToPng()` / `_convertDibToPng()`

**新規作成**: `lib/system/clipboard/windows/windows_clipboard_writer.dart`

現在の`clipboard_copy_service.dart`から以下を抽出:
- `_setClipboardImage()`
- `_setClipboardText()`
- `_bytesToGlobal()` / `_stringToGlobal()`

#### 3.1.3 macOS実装の新規作成

**新規作成**: `macos/Runner/ClipboardPlugin.swift`

```swift
import Cocoa
import FlutterMacOS

public class ClipboardPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.clip_pix/clipboard",
            binaryMessenger: registrar.messenger
        )
        let instance = ClipboardPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getChangeCount":
            result(NSPasteboard.general.changeCount)

        case "readImage":
            readImage(result: result)

        case "readText":
            readText(result: result)

        case "writeImage":
            if let args = call.arguments as? [String: Any],
               let data = args["data"] as? FlutterStandardTypedData {
                writeImage(data: data.data, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
            }

        case "writeText":
            if let args = call.arguments as? [String: Any],
               let text = args["text"] as? String {
                writeText(text: text, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func readImage(result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general

        // PNG優先
        if let data = pasteboard.data(forType: .png) {
            result(FlutterStandardTypedData(bytes: data))
            return
        }

        // TIFF
        if let data = pasteboard.data(forType: .tiff),
           let image = NSImage(data: data),
           let pngData = image.pngData() {
            result(FlutterStandardTypedData(bytes: pngData))
            return
        }

        result(nil)
    }

    private func readText(result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string) {
            result(text)
        } else {
            result(nil)
        }
    }

    private func writeImage(data: Data, result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        result(true)
    }

    private func writeText(text: String, result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        result(true)
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
```

**新規作成**: `lib/system/clipboard/macos/macos_clipboard_reader.dart`

```dart
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../clipboard_service.dart';

class MacOSClipboardReader implements ClipboardReader {
  static const _channel = MethodChannel('com.clip_pix/clipboard');

  @override
  int getChangeCount() {
    // 同期呼び出しが必要なため、キャッシュを使用
    return _cachedChangeCount;
  }

  int _cachedChangeCount = 0;

  Future<void> updateChangeCount() async {
    final count = await _channel.invokeMethod<int>('getChangeCount');
    _cachedChangeCount = count ?? 0;
  }

  @override
  Future<ClipboardContent?> read() async {
    // まずchangeCountを更新
    await updateChangeCount();

    // 画像を試す
    final imageData = await _channel.invokeMethod<Uint8List>('readImage');
    if (imageData != null) {
      return ClipboardContent(imageData: imageData);
    }

    // テキストを試す
    final text = await _channel.invokeMethod<String>('readText');
    if (text != null && text.isNotEmpty) {
      return ClipboardContent(text: text);
    }

    return null;
  }

  @override
  void dispose() {
    // リソース解放（必要に応じて）
  }
}
```

#### 3.1.4 ClipboardMonitor の改修

**変更**: `lib/system/clipboard/clipboard_monitor.dart`

```dart
// Before: Windows API直接使用
import 'package:win32/win32.dart';

// After: 抽象化レイヤー使用
import 'clipboard_service.dart';

class ClipboardMonitor extends ChangeNotifier implements ClipboardMonitorGuard {
  ClipboardMonitor({
    required Directory? Function() getSelectedFolder,
    required ImageCapturedCallback onImageCaptured,
    required UrlCapturedCallback onUrlCaptured,
    required TextCapturedCallback onTextCaptured,
    ClipboardReader? reader,  // 依存性注入
    Logger? logger,
    // ...
  }) : _reader = reader ?? ClipboardServiceFactory.createReader(),
       // ...

  final ClipboardReader _reader;

  // _processClipboardSnapshot を改修
  Future<void> _processClipboardSnapshot() async {
    if (!_isRunning) return;

    final currentSequence = _reader.getChangeCount();
    // 以下、既存ロジックを維持...

    final content = await _reader.read();
    if (content == null) return;

    if (content.hasImage) {
      await handleClipboardImage(content.imageData!, sourceType: content.sourceType);
      return;
    }
    if (content.hasText) {
      await handleClipboardText(content.text!);
    }
  }

  // Windows Hook関連コードを条件付きで保持
  Future<void> _initializeHook() async {
    if (Platform.isWindows) {
      // Windows Hook実装（既存コード）
    } else {
      // macOS/他: ポーリングのみ
      _activatePollingFallback();
    }
  }
}
```

### Phase 2: ウィンドウサービス統一 (P1)

#### 3.2.1 window_manager パッケージへの移行

`window_manager`パッケージは既にmacOS対応済み。

**変更**: `lib/system/window_bounds_service.dart`

```dart
// Before
import 'package:win32/win32.dart';

bool get _isSupported => Platform.isWindows;

Rect? _readWindowRect() {
  final hwnd = _resolveWindowHandle();
  // win32 API使用...
}

bool _applyBounds(Rect rect) {
  // SetWindowPos使用...
}

// After
import 'package:window_manager/window_manager.dart';

bool get _isSupported => Platform.isWindows || Platform.isMacOS;

Future<Rect?> _readWindowRect() async {
  final bounds = await windowManager.getBounds();
  return bounds;
}

Future<bool> _applyBounds(Rect rect) async {
  await windowManager.setBounds(rect);
  return true;
}
```

#### 3.2.2 screen_bounds_validator の改修

**変更**: `lib/system/screen_bounds_validator.dart`

```dart
// Before: GetSystemMetrics使用
import 'package:win32/win32.dart';

// After: screen_retrieverまたはwindow_managerを使用
import 'package:screen_retriever/screen_retriever.dart';

class ScreenBoundsValidator {
  Future<List<Rect>> getAllMonitorBounds() async {
    final screens = await screenRetriever.getAllDisplays();
    return screens.map((s) => Rect.fromLTWH(
      s.visiblePosition?.dx ?? 0,
      s.visiblePosition?.dy ?? 0,
      s.visibleSize?.width ?? 1920,
      s.visibleSize?.height ?? 1080,
    )).toList();
  }
}
```

### Phase 3: プレビューウィンドウ (P2)

#### 3.3.1 プレビューウィンドウのmacOS対応

プレビューウィンドウは`window_manager`と`--preview`フラグによる別プロセス起動を使用。
macOSでも同様のアプローチが可能だが、Platform Channel経由のwin32呼び出しを削除する必要がある。

**変更箇所**:
- `lib/ui/image_preview_window.dart`: `Platform.isWindows`チェック部分を`window_manager`APIに置き換え
- `lib/ui/widgets/text_preview_window.dart`: 同上

---

## 4. pubspec.yaml の変更

```yaml
dependencies:
  # 削除または条件付き
  # win32: ^5.5.4  # Windows専用 → 条件付きインポートへ

  # 追加
  screen_retriever: ^0.1.9       # マルチモニタ対応（クロスプラットフォーム）

  # 既存（継続使用）
  window_manager: ^0.3.9         # 既にmacOS対応済み
```

### 条件付きインポートの実装

`lib/system/clipboard/windows/windows_clipboard_impl.dart`:
```dart
// このファイルはWindowsでのみインポートされる
import 'package:win32/win32.dart';
// ...Windows専用実装
```

`lib/system/clipboard/clipboard_service_stub.dart`:
```dart
// スタブ（非対応プラットフォーム用）
ClipboardReader createReader() => throw UnsupportedError('...');
ClipboardWriter createWriter() => throw UnsupportedError('...');
```

`lib/system/clipboard/clipboard_service.dart`:
```dart
import 'clipboard_service_stub.dart'
    if (dart.library.io) 'clipboard_service_io.dart';
```

---

## 5. macOS固有の設定

### 5.1 entitlements

**編集**: `macos/Runner/Release.entitlements` および `DebugProfile.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- ファイルアクセス -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <!-- 下書き画像を選択したフォルダに保存するため -->
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
</dict>
</plist>
```

### 5.2 Info.plist

**編集**: `macos/Runner/Info.plist`

```xml
<!-- クリップボードアクセスの説明（macOS 15.4+で許可ダイアログに表示） -->
<key>NSPasteboardUsageDescription</key>
<string>ClipPixはコピーした画像やテキストを自動的に保存するためにクリップボードへのアクセスが必要です。この機能を使用しない場合は拒否できます。</string>
```

> **注意**: macOS 15.4以降では、この説明文がユーザーへの許可ダイアログに表示されます。
> ユーザーが理解しやすい説明を記載することが重要です。

---

## 6. テスト計画

### 6.1 ユニットテスト

| テスト対象 | テスト内容 |
|-----------|-----------|
| `ClipboardReader` | モック使用でread/getChangeCount動作確認 |
| `ClipboardWriter` | モック使用でwrite動作確認 |
| `ClipboardMonitor` | 抽象化レイヤー経由の監視動作確認 |
| `WindowBoundsService` | window_manager経由の位置保存/復元 |

### 6.2 統合テスト

| シナリオ | Windows | macOS |
|---------|---------|-------|
| 画像クリップボードコピー → 自動保存 | ✓ | ✓ |
| テキスト（URL）コピー → ダウンロード | ✓ | ✓ |
| 画像カードからクリップボードにコピー | ✓ | ✓ |
| ウィンドウ位置の保存/復元 | ✓ | ✓ |
| プレビューウィンドウ起動 | ✓ | ✓ |

### 6.3 手動テスト項目

- [ ] macOSでアプリ起動
- [ ] フォルダ選択ダイアログ動作
- [ ] 画像コピー→自動保存
- [ ] URLコピー→画像ダウンロード
- [ ] グリッド表示・リサイズ
- [ ] プレビューウィンドウ
- [ ] ウィンドウ位置記憶
- [ ] マルチモニタ環境

---

## 7. 移行スケジュール

| Phase | 内容 | 見積もり |
|-------|------|---------|
| Phase 1a | 抽象化レイヤー設計・インターフェース定義 | 0.5日 |
| Phase 1b | Windows実装の抽出・リファクタリング | 1日 |
| Phase 1c | macOS Swift実装 | 1日 |
| Phase 1d | ClipboardMonitor統合 | 0.5日 |
| Phase 2 | ウィンドウサービス統一 | 0.5日 |
| Phase 3 | プレビューウィンドウ対応 | 0.5日 |
| テスト | 統合テスト・バグ修正 | 1日 |
| **合計** | | **5日** |

---

## 8. リスクと対策

| リスク | 影響 | 対策 |
|-------|------|------|
| **macOS 15.4+ クリップボードプライバシー** | ユーザー許可なしでクリップボード読み取り不可。許可拒否で自動保存機能が無効化 | 1. 初回起動時に許可を求めるUI追加 2. 許可拒否時のフォールバック（手動ペーストモード） 3. `accessBehavior` APIで許可状態を確認 |
| macOSクリップボードの画像形式の違い | 画像が正しく読めない | TIFF→PNG変換をSwift側で実装 |
| サンドボックス制限 | ファイル保存不可 | entitlementsでファイルアクセス許可 |
| MethodChannelの非同期性 | changeCountのポーリング遅延 | キャッシュ戦略で対応 |
| Windows Hookの代替なし（macOS） | イベント駆動監視不可 | ポーリングで統一（両プラットフォーム共通化も検討） |

### 8.1 macOS 15.4+ プライバシー対応の詳細

macOS 15.4（2025年5月）より、アプリがクリップボードにプログラムからアクセスする際にユーザー許可が必要になりました。macOS 16で全面適用予定です。

#### テスト手順

開発中に新しいプライバシー動作をテストするには：

```bash
defaults write com.clip_pix EnablePasteboardPrivacyDeveloperPreview -bool yes
```

#### アクセス状態の確認

```swift
let behavior = NSPasteboard.general.accessBehavior
switch behavior {
case .alwaysAllowed:
    // 通常のポーリング監視が可能
case .requiresUserConsent:
    // ユーザー操作をトリガーに読み取り
case .denied:
    // 手動ペーストモードに切り替え
@unknown default:
    break
}
```

#### フォールバック戦略

| 許可状態 | 動作モード | UI |
|---------|----------|-----|
| `.alwaysAllowed` | 自動監視モード | 通常のクリップボード監視 |
| `.requiresUserConsent` | 半自動モード | ペーストボタン押下時に読み取り |
| `.denied` | 手動モード | ドラッグ&ドロップまたはファイル選択のみ |

---

## 9. 参考資料

### Flutter パッケージ
- [super_clipboard | pub.dev](https://pub.dev/packages/super_clipboard)
- [pasteboard | pub.dev](https://pub.dev/packages/pasteboard)
- [window_manager | pub.dev](https://pub.dev/packages/window_manager)
- [screen_retriever | pub.dev](https://pub.dev/packages/screen_retriever)

### Apple Developer Documentation
- [NSPasteboard | Apple Developer](https://developer.apple.com/documentation/appkit/nspasteboard)
- [NSPasteboard changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/1533544-changecount)
- [NSPasteboard accessBehavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior)

### macOS 15.4+ プライバシー変更
- [Pasteboard Privacy Preview in macOS 15.4 - Michael Tsai](https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/)
- [macOS 16 clipboard privacy protection - 9to5Mac](https://9to5mac.com/2025/05/12/macos-16-clipboard-privacy-protection/)
- [Apple to Block Mac Apps From Secretly Accessing Your Clipboard - MacRumors](https://www.macrumors.com/2025/05/12/apple-mac-apps-clipboard-change/)

---

## 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | 初版作成 |
| 2025-11-29 | macOS 15.4+クリップボードプライバシー対応を追加（セクション8.1）、Info.plist説明文更新、参考資料追加 |
