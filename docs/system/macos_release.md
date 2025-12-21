# macOS リリース手順

最終更新: 2025-12-21

本書は ClipPix の macOS 版をビルド・署名・公証・配布するための手順をまとめたものです。

## 1. 前提条件

### 1.1 必要なツール

| ツール | インストール方法 | 確認コマンド |
|--------|------------------|--------------|
| Flutter | https://flutter.dev | `flutter --version` |
| Xcode Command Line Tools | `xcode-select --install` | `xcrun --version` |
| create-dmg | `brew install create-dmg` | `which create-dmg` |

### 1.2 Apple Developer 設定

1. **Developer ID Application 証明書**
   - Apple Developer Portal で「Developer ID Application」証明書を作成
   - Keychain Access で証明書がインストールされていることを確認
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **App-Specific Password**
   - https://appleid.apple.com でApp用パスワードを生成
   - 「セキュリティ」→「App用パスワード」→「パスワードを生成」

### 1.3 環境変数の設定

`scripts/.env` ファイルを作成（`.env.example` をコピー）:

```bash
cp scripts/.env.example scripts/.env
```

編集して実際の値を設定:
```bash
APPLE_ID=your-apple-id@example.com
TEAM_ID=JJHF93SZLU
APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
```

## 2. ビルド・配布手順

### 2.1 クイックスタート

```bash
# 公証あり（本番配布用）
./scripts/build_macos_dmg.sh

# 公証なし（テスト用）
SKIP_NOTARIZE=1 ./scripts/build_macos_dmg.sh
```

### 2.2 処理フロー

```
1. flutter build macos --release
2. Developer ID Application で再署名
3. アプリ公証（xcrun notarytool submit）
4. Stapling（xcrun stapler staple）
5. DMG作成（create-dmg）
6. DMG署名
7. DMG公証
8. DMG Stapling
```

### 2.3 出力ファイル

| ファイル | 場所 | 説明 |
|----------|------|------|
| ClipPix.app | `build/macos/Build/Products/Release/` | 署名済みアプリ |
| ClipPix.dmg | `dist/` | 配布用DMG（公証済み） |

## 3. バージョン管理

### 3.1 バージョンの確認

```bash
grep '^version:' pubspec.yaml
```

### 3.2 バージョンのバンプ

```bash
# パッチバージョン（0.1.0 → 0.1.1）
./scripts/bump_version.sh patch

# マイナーバージョン（0.1.0 → 0.2.0）
./scripts/bump_version.sh minor

# メジャーバージョン（0.1.0 → 1.0.0）
./scripts/bump_version.sh major
```

## 4. トラブルシューティング

### 4.1 署名エラー

**症状**: `codesign` でエラーが発生

**対処**:
1. 証明書の有効期限を確認
   ```bash
   security find-identity -v -p codesigning
   ```
2. Keychain Access で証明書を確認
3. Xcode → Preferences → Accounts で証明書を更新

### 4.2 公証エラー（401 Invalid credentials）

**症状**: `HTTP status code: 401. Invalid credentials`

**対処**:
1. Apple IDが正しいか確認
2. App-Specific Passwordを再生成
3. 環境変数が正しく設定されているか確認
   ```bash
   echo $APPLE_ID
   echo $APP_PASSWORD
   ```

### 4.3 公証エラー（Invalid/Rejected）

**症状**: 公証が `Invalid` または `Rejected` で失敗

**対処**:
1. 詳細ログを確認
   ```bash
   xcrun notarytool log <submission-id> \
     --apple-id "$APPLE_ID" \
     --team-id "$TEAM_ID" \
     --password "$APP_PASSWORD"
   ```
2. 一般的な原因:
   - ハードニングされたランタイム（`--options runtime`）が未設定
   - 未署名のバイナリがバンドルに含まれている
   - エンタイトルメントの問題

### 4.4 DMG作成エラー

**症状**: `create-dmg` でエラーが発生

**対処**:
1. create-dmg を再インストール
   ```bash
   brew reinstall create-dmg
   ```
2. 既存のDMGファイルを削除
   ```bash
   rm -f dist/ClipPix.dmg
   ```

### 4.5 spctl で rejected

**症状**: `spctl --assess` で `rejected` と表示される

**対処**:
- 公証をスキップした場合は正常
- 公証済みの場合は Stapling を確認
  ```bash
  xcrun stapler validate dist/ClipPix.dmg
  ```

## 5. 関連ファイル

| ファイル | 説明 |
|----------|------|
| `scripts/build_macos_dmg.sh` | ビルド・公証・DMG作成スクリプト |
| `scripts/.env.example` | 環境変数テンプレート |
| `scripts/bump_version.sh` | バージョンバンプスクリプト |
| `macos/Runner/Release.entitlements` | リリース用エンタイトルメント |
| `pubspec.yaml` | バージョン情報 |

## 6. 参考リンク

- [Apple Notarization](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [create-dmg](https://github.com/create-dmg/create-dmg)
- [Flutter macOS deployment](https://docs.flutter.dev/deployment/macos)
