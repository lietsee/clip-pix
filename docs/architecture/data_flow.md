# データフロー

**作成日**: 2025-10-28
**最終更新**: 2025-11-27
**ステータス**: 実装完了

## 全体データフロー

```mermaid
flowchart TB
    subgraph Input["入力ソース"]
        CB[クリップボード<br>画像/URL/テキスト]
        FILE[ファイルシステム]
        USER[ユーザー操作]
    end

    subgraph System["システムレイヤー"]
        CBM[ClipboardMonitor]
        FW[FileWatcher]
        IS[ImageSaver]
        TS[TextSaver]
        UDS[UrlDownloadService]
        DS[DeleteService]
        IPPM[ImagePreviewProcessManager]
        TPPM[TextPreviewProcessManager]
    end

    subgraph State["状態管理レイヤー"]
        ILN[ImageLibraryNotifier]
        IHN[ImageHistoryNotifier]
        GLS[GridLayoutStore]
        SFN[SelectedFolderNotifier]
        DMN[DeletionModeNotifier]
    end

    subgraph Data["データレイヤー"]
        IR[ImageRepository]
        GCPR[GridCardPreferencesRepo]
        GLSR[GridLayoutSettingsRepo]
        OPR[OpenPreviewsRepository]
        MW[MetadataWriter]
    end

    subgraph UI["UIレイヤー"]
        MS[MainScreen]
        GV[GridViewModule]
        IC[ImageCard / TextCard]
        IPW[ImagePreviewWindow]
        TPW[TextPreviewWindow]
    end

    CB --> CBM
    CBM -->|画像| IS
    CBM -->|URL| UDS
    CBM -->|テキスト| TS
    UDS --> IS
    IS --> MW
    TS --> MW
    MW --> FILE
    FILE --> FW
    FW --> ILN
    ILN --> GV

    USER --> MS
    MS --> SFN
    SFN --> IR
    IR --> ILN

    ILN --> GLS
    GLS --> GCPR
    GCPR --> FILE

    GV --> IC
    IC --> GLS

    IC --> IPPM
    IC --> TPPM
    IPPM --> IPW
    TPPM --> TPW
    IPPM --> OPR
    TPPM --> OPR

    USER -->|削除モード| DMN
    DMN --> DS
    DS --> FILE
```

## フロー1: クリップボード画像保存

```mermaid
sequenceDiagram
    participant User
    participant Clipboard
    participant CBM as ClipboardMonitor
    participant IS as ImageSaver
    participant MW as MetadataWriter
    participant FS as FileSystem
    participant FW as FileWatcher
    participant ILN as ImageLibraryNotifier
    participant UI

    User->>Clipboard: Ctrl+C（画像コピー）
    Clipboard->>CBM: ポーリング検出（400ms）
    CBM->>CBM: ガードトークン確認
    CBM->>CBM: シーケンス番号変更チェック
    CBM->>Clipboard: GetImage() (DIBV5 → PNG → DIB)
    Clipboard-->>CBM: 画像バイト
    CBM->>IS: save(bytes, metadata)
    IS->>FS: writeAsBytes(image.jpg)
    IS->>MW: writeMetadata(.fileInfo.json)
    MW->>FS: appendEntry(JSON)
    FS->>FW: ファイル作成イベント
    FW->>ILN: addImage(ImageItem)
    ILN->>ILN: notifyListeners()
    ILN->>UI: 再描画トリガー
    UI->>UI: 新しいImageCard表示
```

## フロー2: URL画像ダウンロード

```mermaid
sequenceDiagram
    participant User
    participant Clipboard
    participant CBM as ClipboardMonitor
    participant UDS as UrlDownloadService
    participant HTTP as HTTPサーバー
    participant IS as ImageSaver
    participant FS as FileSystem

    User->>Clipboard: Ctrl+C（URL文字列）
    Clipboard->>CBM: ポーリング検出
    CBM->>Clipboard: GetText()
    Clipboard-->>CBM: "https://example.com/image.jpg"
    CBM->>CBM: URL正規表現マッチ
    CBM->>UDS: downloadImage(url)
    UDS->>HTTP: GET https://example.com/image.jpg
    HTTP-->>UDS: 200 OK + image/jpeg bytes
    UDS->>UDS: Content-Type検証
    UDS-->>CBM: UrlDownloadResult(bytes, ext)
    CBM->>IS: save(bytes, metadata: {source: url, originalUrl: ...})
    IS->>FS: writeAsBytes(clipboard_123.jpg)
    Note over FS: 以降はフロー1と同じ
```

## フロー3: クリップボードテキスト保存 (2025-11-27追加)

```mermaid
sequenceDiagram
    participant User
    participant Clipboard
    participant CBM as ClipboardMonitor
    participant TS as TextSaver
    participant MW as MetadataWriter
    participant FS as FileSystem
    participant FW as FileWatcher
    participant ILN as ImageLibraryNotifier
    participant UI

    User->>Clipboard: Ctrl+C（テキストコピー）
    Clipboard->>CBM: ポーリング検出（400ms）
    CBM->>CBM: ガードトークン確認
    CBM->>Clipboard: GetText() (CF_UNICODETEXT)
    Clipboard-->>CBM: テキストデータ
    CBM->>CBM: URL判定 → 非URL
    CBM->>TS: saveTextData(text)
    TS->>TS: テキストサニタイズ
    TS->>TS: サイズチェック（1MB上限）
    TS->>FS: writeAsString(note.txt)
    TS->>MW: writeMetadata(.fileInfo.json)
    MW->>FS: appendEntry(JSON with content_type: "text")
    FS->>FW: ファイル作成イベント
    FW->>ILN: addImage(TextContentItem)
    ILN->>ILN: notifyListeners()
    ILN->>UI: 再描画トリガー
    UI->>UI: 新しいTextCard表示
```

## フロー4: フォルダ選択とスキャン

```mermaid
sequenceDiagram
    participant User
    participant MS as MainScreen
    participant SFN as SelectedFolderNotifier
    participant IR as ImageRepository
    participant FS as FileSystem
    participant FW as FileWatcher
    participant ILN as ImageLibraryNotifier

    User->>MS: [フォルダを選択]ボタン
    MS->>User: ファイル選択ダイアログ
    User->>MS: フォルダ選択確定
    MS->>SFN: updateFolder(folderPath)
    SFN->>IR: scanFolder(folderPath)
    IR->>FS: Directory.listSync()
    FS-->>IR: [file1.jpg, file2.png, note.txt, ...]
    IR->>IR: .fileInfo.json メタデータ読み込み
    IR->>IR: ContentItem生成（ImageItem / TextContentItem）
    IR-->>SFN: List<ContentItem>
    SFN->>FW: start(folderPath)
    FW->>FW: Watcher購読開始
    SFN->>ILN: syncLibrary(items)
    ILN->>ILN: notifyListeners()
    ILN->>MS: 再描画
    MS->>MS: GridView表示
```

## フロー5: カードリサイズ

```mermaid
sequenceDiagram
    participant User
    participant IC as ImageCard
    participant GLS as GridLayoutStore
    participant GCPR as GridCardPreferencesRepo
    participant Engine as GridLayoutLayoutEngine
    participant Surface as GridLayoutSurface
    participant Minimap as Minimap
    participant Hive

    User->>IC: ドラッグでリサイズ
    IC->>IC: onPanUpdate(delta)
    IC->>GLS: updateCard(id, customSize)

    Note over GLS: メモリ状態更新
    GLS->>GLS: _viewStates[id] = newState

    Note over GLS,Hive: Hive永続化
    GLS->>GCPR: saveBatch([record])
    GCPR->>Hive: box.put(id, preference)

    Note over GLS,Engine: スナップショット再生成
    GLS->>Engine: compute(geometry, orderedStates)
    Engine-->>GLS: LayoutComputationResult
    GLS->>GLS: _latestSnapshot = result.snapshot

    Note over GLS: リスナー通知
    GLS->>GLS: notifyListeners()
    GLS->>Surface: リスナー通知
    GLS->>Minimap: リスナー通知

    Note over Surface: バッファスワップ
    Surface->>Surface: setState(front ← staging)
    Surface->>Surface: PinterestSliverGrid再描画

    Note over Minimap: ミニマップ更新
    Minimap->>Minimap: setState() → rebuild with new snapshot
```

## フロー6: プレビューウィンドウ起動 (2025-11-27追加)

```mermaid
sequenceDiagram
    participant User
    participant IC as ImageCard/TextCard
    participant PPM as PreviewProcessManager
    participant FS as FileSystem
    participant OPR as OpenPreviewsRepository
    participant PW as PreviewWindow

    User->>IC: ダブルクリック
    IC->>PPM: isLaunching(itemId)?
    PPM-->>IC: false
    IC->>PPM: markLaunching(itemId)
    IC->>FS: Process.start(exe, --preview, jsonPayload)
    FS-->>IC: Process
    IC->>PPM: registerProcess(itemId, process, alwaysOnTop)
    PPM->>OPR: add(itemId, alwaysOnTop)
    OPR->>OPR: Hive永続化
    PPM->>PPM: process.exitCode.then(...)
    FS-->>PW: 新プロセス起動
    PW->>PW: ウィンドウ表示

    Note over PW: ユーザーがウィンドウを閉じる
    User->>PW: 閉じる
    PW-->>PPM: exitCode callback
    PPM->>OPR: remove(itemId)
    PPM->>PPM: notifyListeners()
```

## フロー7: 一括削除 (2025-11-27追加)

```mermaid
sequenceDiagram
    participant User
    participant MS as MainScreen
    participant DMN as DeletionModeNotifier
    participant IC as ImageCard/TextCard
    participant DS as DeleteService
    participant FS as FileSystem
    participant FW as FileWatcher
    participant ILN as ImageLibraryNotifier
    participant GLS as GridLayoutStore

    User->>MS: 削除モードボタン
    MS->>DMN: enterDeletionMode()
    DMN->>DMN: state.isActive = true
    DMN->>MS: 再描画（選択UIオーバーレイ表示）

    User->>IC: カードをタップ（複数選択）
    IC->>DMN: toggleSelection(cardId)
    DMN->>DMN: selectedCardIds.add(cardId)

    User->>MS: [削除を実行]ボタン
    MS->>DMN: setDeleting(true)
    MS->>DS: deleteFiles(selectedCardIds)
    loop 各選択ファイル
        DS->>FS: file.delete()
        FS->>FW: REMOVE イベント
        FW->>ILN: removeItem(path)
        ILN->>GLS: removeCard(id)
    end
    DS-->>MS: 完了
    MS->>DMN: exitDeletionMode()
    DMN->>DMN: state = initial
    DMN->>MS: 再描画（通常UI復帰）
```

## フロー8: グリッド設定変更

```mermaid
sequenceDiagram
    participant User
    participant Dialog as GridSettingsDialog
    participant GLSR as GridLayoutSettingsRepo
    participant Hive
    participant GLS as GridLayoutStore
    participant Surface as GridLayoutSurface

    User->>Dialog: [グリッド設定]ボタン
    Dialog->>GLSR: value (現在の設定取得)
    GLSR->>Hive: box.get('settings')
    Hive-->>Dialog: GridLayoutSettings
    Dialog->>Dialog: フォームに表示
    User->>Dialog: カラム数変更 → [保存]
    Dialog->>GLSR: update(newSettings)
    GLSR->>Hive: box.put('settings', newSettings)
    GLSR->>GLSR: _controller.add(newSettings)
    GLSR->>Surface: stream.listen()
    Surface->>GLS: updateGeometry(newGeometry)
    Note over GLS,Surface: 以降はフロー5と同じ
```

## フロー9: Undo/Redo

```mermaid
sequenceDiagram
    participant User
    participant Dialog as GridSettingsDialog
    participant GRC as GridResizeController
    participant GLS as GridLayoutStore
    participant GCPR as GridCardPreferencesRepo

    User->>Dialog: [全カードを揃える]
    Dialog->>GRC: applyBulkSpan(span)
    GRC->>GRC: snapshot = store.captureSnapshot()
    GRC->>GRC: _undoStack.add(snapshot)
    GRC->>GLS: applyBulkSpan(span)
    GLS->>GCPR: saveBatch(records)

    User->>Dialog: [サイズを戻す]（Undo）
    Dialog->>GRC: undo()
    GRC->>GRC: snapshot = _undoStack.removeLast()
    GRC->>GRC: _redoStack.add(currentSnapshot)
    GRC->>GLS: restoreSnapshot(snapshot)
    GLS->>GCPR: saveBatch(records)
```

## データ永続化タイミング

### リアルタイム保存

| アクション | 保存先 | タイミング |
|-----------|--------|-----------|
| 画像保存 | FS (image.jpg + .fileInfo.json) | 即座 |
| テキスト保存 | FS (note.txt + .fileInfo.json) | 即座 |
| カードリサイズ | Hive (grid_card_prefs) | ドラッグ終了時 |
| フォルダ選択 | Hive (app_state) | 選択確定時 |
| グリッド設定変更 | Hive (grid_layout) | [保存]ボタン押下時 |
| プレビューウィンドウ起動 | Hive (open_previews) | 即座 |
| プレビューウィンドウ終了 | Hive (open_previews) | 即座 |

### バッチ保存

```dart
// 一括リサイズ時
await gridLayoutStore.applyBulkSpan(span: 3);
// → 全カードのpreferencesを1回のHive.putAllで保存
```

## 状態同期パターン

### パターン1: File → State (FileWatcher)

```dart
// FileWatcher検出
_watcher.events.listen((event) {
  if (event.type == ChangeType.ADD) {
    final contentItem = ContentItem.fromPath(event.path);
    _imageLibraryNotifier.addItem(contentItem);
  }
});
```

### パターン2: State → Hive (Repository)

```dart
// GridLayoutStore
await updateCard(id: id, customSize: size);
// ↓
_viewStates[id] = newState;
await _persistence.saveBatch([_recordFromState(newState)]);
notifyListeners();
```

### パターン3: Hive → State (起動時復元)

```dart
// アプリ起動時
final settings = GridLayoutSettingsRepository().value;
final selectedFolder = Hive.box('app_state').get('folder');
final openPreviews = OpenPreviewsRepository().getAll();
// → Providerに注入して初期化
```

## エラー伝播

```mermaid
flowchart LR
    A[エラー発生源] --> B{エラー種類}
    B -->|ファイルI/O| C[Logger.warning]
    B -->|ネットワーク| D[Logger.severe + null返却]
    B -->|状態不整合| E[StateError throw]
    B -->|テキストサイズ超過| F[SaveResult.failed]

    C --> G[処理続行]
    D --> G
    F --> G
    E --> H[SnackBar表示]
    H --> I[ユーザー通知]
```

### エラーハンドリング戦略

1. **回復可能**: ログ出力のみ、処理続行（例: メタデータ読み込み失敗）
2. **ユーザー通知必要**: SnackBar表示（例: フォルダアクセス拒否）
3. **サイズ制限**: SaveResult.failed 返却（例: テキスト1MB超過）
4. **致命的**: エラーダイアログ + アプリ終了（例: Hive初期化失敗）

## パフォーマンス特性

### メモリフットプリント

| コンポーネント | メモリ使用量 | 備考 |
|---------------|-------------|------|
| ImageLibraryNotifier | カード数 × 1KB | ContentItemリスト |
| GridLayoutStore | カード数 × 200B | viewStatesマップ |
| Hive (grid_card_prefs) | カード数 × 100B | 永続化データ |
| LayoutSnapshot | カード数 × 150B | Rectとメタデータ |
| PreviewProcessManager | プロセス数 × 50B | プロセス参照のみ |

### I/O最適化

- **バッチ書き込み**: `Hive.putAll()` で複数レコードを1回のI/Oで保存
- **遅延読み込み**: フォルダ選択時のみImageRepository.scanFolder実行
- **デバウンス**: ウィンドウリサイズ時の設定保存（200ms）
- **統合メタデータ**: 個別JSONファイルを廃止、`.fileInfo.json` に統合

## 関連ドキュメント

- [State Management Flow](./state_management_flow.md) - 状態管理の詳細
- [Grid Rendering Pipeline](./grid_rendering_pipeline.md) - レンダリングフロー
- [Repositories](../data/repositories.md) - データアクセス層
- [TextSaver](../system/text_saver.md) - テキスト保存サービス
- [ClipboardMonitor](../system/clipboard_monitor.md) - クリップボード監視

## 変更履歴

| 日付 | 内容 |
|------|------|
| 2025-11-27 | TEXT保存フロー、プレビューウィンドウフロー、削除フロー追加 |
| 2025-11-02 | カードリサイズフロー、ミニマップ更新パターン更新 |
| 2025-10-28 | 初版作成 |
