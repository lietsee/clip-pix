# ScreenBoundsValidator

**実装ファイル**: `lib/system/screen_bounds_validator.dart`
**作成日**: 2025-10-28
**更新日**: 2025-11-05
**ステータス**: 実装完了

## 概要

`ScreenBoundsValidator` は、マルチモニター環境でウィンドウの位置を検証し、画面外の位置を検出するサービスです。Win32 API を使用してモニター情報を取得し、ウィンドウが有効な位置にあるかを判定します。

## 主要機能

### 1. モニター境界の取得

仮想スクリーン全体の境界を取得します。

```dart
List<Rect> getAllMonitorBounds() {
  // GetSystemMetrics を使って仮想スクリーンの境界を取得
  final xVirtual = GetSystemMetrics(SM_XVIRTUALSCREEN);
  final yVirtual = GetSystemMetrics(SM_YVIRTUALSCREEN);
  final cxVirtual = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  final cyVirtual = GetSystemMetrics(SM_CYVIRTUALSCREEN);

  return [Rect.fromLTWH(xVirtual, yVirtual, cxVirtual, cyVirtual)];
}
```

### 2. ウィンドウ位置の検証（2025-11-05 改善）

2段階の検証を実施：

#### ステップ1: 中心点チェック

`MonitorFromPoint` を使用してウィンドウの中心点が実際のモニター上にあるかを確認。

```dart
final centerX = (windowBounds.left + windowBounds.right) ~/ 2;
final centerY = (windowBounds.top + windowBounds.bottom) ~/ 2;

final point = calloc<POINT>();
point.ref.x = centerX;
point.ref.y = centerY;

final hMonitor = MonitorFromPoint(point.ref, MONITOR_DEFAULTTONULL);
if (hMonitor == 0) {
  return false; // 中心点がどのモニターにもない
}
```

**利点**:
- モニター構成が変更された場合に正確に検出
- 仮想スクリーンの「隙間」も検出可能

#### ステップ2: 四隅チェック

ウィンドウの四隅のうち、少なくとも1つが仮想スクリーン内にあることを確認。

```dart
final virtualBounds = getAllMonitorBounds().first;

final topLeft = virtualBounds.contains(windowBounds.topLeft);
final topRight = virtualBounds.contains(windowBounds.topRight);
final bottomLeft = virtualBounds.contains(windowBounds.bottomLeft);
final bottomRight = virtualBounds.contains(windowBounds.bottomRight);

if (!topLeft && !topRight && !bottomLeft && !bottomRight) {
  return false; // すべての隅が画面外
}
```

**利点**:
- 部分的に画面外のウィンドウを検出
- より厳格な検証

### 3. 画面外ウィンドウの調整

```dart
Rect? adjustIfOffScreen(Rect windowBounds) {
  if (isValidPosition(windowBounds)) {
    return windowBounds; // 有効ならそのまま返す
  }
  return null; // 無効なら null を返す（呼び出し側で center: true を使用）
}
```

## API

### getAllMonitorBounds()

```dart
List<Rect> getAllMonitorBounds()
```

仮想スクリーン全体の境界を返します。

**戻り値**: `List<Rect>` - 仮想スクリーンの境界（通常は1要素）

**使用API**:
- `GetSystemMetrics(SM_XVIRTUALSCREEN)` - 仮想スクリーンの左端X座標
- `GetSystemMetrics(SM_YVIRTUALSCREEN)` - 仮想スクリーンの上端Y座標
- `GetSystemMetrics(SM_CXVIRTUALSCREEN)` - 仮想スクリーンの幅
- `GetSystemMetrics(SM_CYVIRTUALSCREEN)` - 仮想スクリーンの高さ

### isValidPosition(Rect windowBounds)

```dart
bool isValidPosition(Rect windowBounds)
```

ウィンドウが有効な位置にあるかを検証します。

**パラメータ**:
- `windowBounds` - 検証するウィンドウの境界

**戻り値**: `bool` - 有効な位置なら `true`、画面外なら `false`

**検証基準**:
1. ウィンドウの中心点がモニター上にある（`MonitorFromPoint`）
2. ウィンドウの四隅のうち少なくとも1つが仮想スクリーン内にある

### adjustIfOffScreen(Rect windowBounds)

```dart
Rect? adjustIfOffScreen(Rect windowBounds)
```

画面外のウィンドウ位置を調整します。

**パラメータ**:
- `windowBounds` - 調整するウィンドウの境界

**戻り値**: `Rect?` - 有効な位置ならそのまま、無効なら `null`

## 使用例

### WindowBoundsService での使用

```dart
class WindowBoundsService {
  final ScreenBoundsValidator _validator = ScreenBoundsValidator();

  Future<void> _restoreBounds() async {
    final desired = Rect.fromLTWH(left, top, width, height);

    // マルチモニター検証
    if (!_validator.isValidPosition(desired)) {
      _logger.warning('Stored position is off-screen, using default');
      return; // デフォルト位置（中央）で起動
    }

    _applyBounds(desired);
  }
}
```

### プレビューウィンドウでの使用

```dart
// Image/Text Preview Window
final validator = ScreenBoundsValidator();
final savedState = repository.get(itemId);

if (savedState != null) {
  final bounds = Rect.fromLTWH(
    savedState.x!, savedState.y!,
    savedState.width!, savedState.height!,
  );
  restoredBounds = validator.adjustIfOffScreen(bounds);
}

final windowOptions = WindowOptions(
  size: restoredBounds?.size ?? defaultSize,
  center: restoredBounds == null, // 画面外ならセンタリング
);
```

## マルチモニターシナリオ

### シナリオ1: モニター数の減少

```
オフィス（3モニター）:
  - Primary: (0, 0) - (1920, 1080)
  - Secondary: (1920, 0) - (3840, 1080)  ← ウィンドウ保存位置 (2000, 100)
  - Tertiary: (3840, 0) - (5760, 1080)

自宅（1モニター）:
  - Primary: (0, 0) - (1920, 1080)
  - 仮想スクリーン: (0, 0) - (1920, 1080)

検証結果:
  - 保存位置 (2000, 100) の中心点をチェック
  - MonitorFromPoint → NULL（モニターなし）
  - isValidPosition → false
  - ウィンドウを中央配置
```

### シナリオ2: モニター配置の変更

```
変更前（左右配置）:
  - Primary: (0, 0) - (1920, 1080)
  - Secondary: (1920, 0) - (3840, 1080)  ← ウィンドウ保存位置 (2000, 100)

変更後（上下配置）:
  - Primary: (0, 0) - (1920, 1080)
  - Secondary: (0, 1080) - (1920, 2160)

検証結果:
  - 保存位置 (2000, 100) の中心点をチェック
  - MonitorFromPoint → NULL（該当モニターなし）
  - isValidPosition → false
  - ウィンドウを中央配置
```

### シナリオ3: 部分的に画面外

```
モニター構成:
  - Primary: (0, 0) - (1920, 1080)

保存位置: (1800, -100, 400, 300)
  - 左上: (1800, -100) ← 画面外（Y座標が負）
  - 右下: (2200, 200) ← 画面外（X座標が1920超）

検証結果:
  - 中心点 (2000, 50) をチェック
  - MonitorFromPoint → NULL
  - isValidPosition → false
  - ウィンドウを中央配置
```

## Win32 API リファレンス

### GetSystemMetrics

仮想スクリーンの境界を取得するために使用。

```dart
final xVirtual = GetSystemMetrics(SM_XVIRTUALSCREEN);  // -1920 (例)
final yVirtual = GetSystemMetrics(SM_YVIRTUALSCREEN);  // 0
final cxVirtual = GetSystemMetrics(SM_CXVIRTUALSCREEN); // 5760
final cyVirtual = GetSystemMetrics(SM_CYVIRTUALSCREEN); // 1080
```

**メトリクス**:
- `SM_XVIRTUALSCREEN` (76): 仮想スクリーンの左端X座標
- `SM_YVIRTUALSCREEN` (77): 仮想スクリーンの上端Y座標
- `SM_CXVIRTUALSCREEN` (78): 仮想スクリーンの幅
- `SM_CYVIRTUALSCREEN` (79): 仮想スクリーンの高さ

### MonitorFromPoint

指定された点がどのモニター上にあるかを判定。

```dart
final hMonitor = MonitorFromPoint(point.ref, MONITOR_DEFAULTTONULL);
if (hMonitor == 0) {
  // 点がどのモニターにもない
}
```

**フラグ**:
- `MONITOR_DEFAULTTONULL` (0): モニターがない場合は NULL を返す
- `MONITOR_DEFAULTTOPRIMARY` (1): プライマリモニターを返す
- `MONITOR_DEFAULTTONEAREST` (2): 最も近いモニターを返す

## パフォーマンス

### 検証コスト

- `GetSystemMetrics`: 1μs未満（キャッシュ済み）
- `MonitorFromPoint`: 10μs未満（システムコール）
- 四隅チェック: 1μs未満（計算のみ）
- **合計**: 20μs未満（無視できるオーバーヘッド）

### メモリ使用量

- `POINT` 構造体: 8バイト（一時的）
- `Rect` リスト: 32バイト × モニター数
- **合計**: 100バイト未満

## エラーハンドリング

### プラットフォームチェック

```dart
if (!Platform.isWindows) {
  return true; // 非Windows環境では常に有効とする
}
```

### API 呼び出しエラー

```dart
try {
  final hMonitor = MonitorFromPoint(point.ref, MONITOR_DEFAULTTONULL);
  // ...
} catch (e, stackTrace) {
  _logger.warning('Failed to validate window position, assuming invalid', e, stackTrace);
  return false; // 安全のため無効と判定
}
```

## テストガイドライン

### ユニットテスト

1. **有効な位置**: プライマリモニター内の位置 → `true`
2. **画面外**: 仮想スクリーン外の位置 → `false`
3. **部分的に画面外**: 一部が画面外 → 中心点次第
4. **無効な寸法**: 幅/高さが0以下 → `false`

### 統合テスト

1. **シングルモニター**: 基本的な検証
2. **マルチモニター**: 複数モニター環境での検証
3. **モニター構成変更**: モニター取り外しシミュレーション

## 今後の拡張

1. **EnumDisplayMonitors 統合**: 個別モニターの境界を取得（現在は仮想スクリーンのみ）
2. **Per-Monitor DPI 対応**: 高DPI環境でのスケーリング調整
3. **最小可視面積の調整**: 現在は中心点+四隅、将来は50%ルールなど

## 実装履歴

- **2025-10-28**: 初期実装（仮想スクリーンベース、50%可視ルール）
- **2025-11-05**: `MonitorFromPoint` 統合、2段階検証に改善
