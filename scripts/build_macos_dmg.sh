#!/bin/bash
#
# macOS DMG配布パッケージ作成スクリプト
#
# 使用方法:
#   ./scripts/build_macos_dmg.sh
#
# 前提条件:
#   1. create-dmg がインストール済み: brew install create-dmg
#   2. Apple ID App-Specific PasswordがKeychainに保存済み:
#      security add-generic-password -a "your-apple-id@example.com" \
#        -w "xxxx-xxxx-xxxx-xxxx" -s "AC_PASSWORD"
#   3. Developer ID Application証明書がインストール済み
#
# 環境変数（必要に応じて設定）:
#   APPLE_ID       - Apple ID（デフォルト: スクリプト内の値）
#   TEAM_ID        - Apple Team ID（デフォルト: スクリプト内の値）
#   SKIP_NOTARIZE  - "1"を設定すると公証をスキップ
#

set -e

# ===== 設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_NAME="ClipPix"
BUNDLE_ID="net.niwatoku.clipPix"

# .envファイルから環境変数を読み込み（存在する場合）
if [ -f "$SCRIPT_DIR/.env" ]; then
    echo "Loading environment from .env file..."
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Apple Developer設定（環境変数で上書き可能）
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="${TEAM_ID:-JJHF93SZLU}"
# パスワード: 環境変数 > Keychain の優先順位
APP_PASSWORD="${APP_PASSWORD:-@keychain:AC_PASSWORD}"

# パス設定
BUILD_DIR="$PROJECT_ROOT/build/macos/Build/Products/Release"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="$PROJECT_ROOT/dist"

# pubspec.yamlからバージョン取得
VERSION=$(grep '^version:' "$PROJECT_ROOT/pubspec.yaml" | sed 's/version: //' | cut -d'+' -f1)
DMG_NAME="$APP_NAME.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# Developer ID Application証明書
DEVELOPER_ID="Developer ID Application: Daiki Fujiwara (JJHF93SZLU)"

# ===== 関数 =====
log() {
    echo ""
    echo "=========================================="
    echo "  $1"
    echo "=========================================="
}

check_requirements() {
    log "前提条件チェック"

    # create-dmg
    if ! command -v create-dmg &> /dev/null; then
        echo "Error: create-dmg がインストールされていません"
        echo "インストール: brew install create-dmg"
        exit 1
    fi
    echo "✓ create-dmg: $(which create-dmg)"

    # xcrun notarytool
    if ! xcrun notarytool --version &> /dev/null; then
        echo "Error: xcrun notarytool が利用できません"
        echo "Xcode Command Line Toolsをインストールしてください"
        exit 1
    fi
    echo "✓ xcrun notarytool: available"

    # Flutter
    if ! command -v flutter &> /dev/null; then
        echo "Error: flutter がインストールされていません"
        exit 1
    fi
    echo "✓ flutter: $(flutter --version | head -1)"

    # Apple ID確認（公証する場合）
    if [ "$SKIP_NOTARIZE" != "1" ] && [ -z "$APPLE_ID" ]; then
        echo ""
        echo "Warning: APPLE_ID が設定されていません"
        echo "公証を行うには環境変数 APPLE_ID を設定してください"
        echo "例: export APPLE_ID='your-apple-id@example.com'"
        echo ""
        read -p "公証をスキップして続行しますか? (y/N): " answer
        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            exit 1
        fi
        SKIP_NOTARIZE=1
    fi
}

build_app() {
    log "リリースビルド"
    cd "$PROJECT_ROOT"
    flutter build macos --release

    if [ ! -d "$APP_PATH" ]; then
        echo "Error: ビルド結果が見つかりません: $APP_PATH"
        exit 1
    fi
    echo "✓ ビルド完了: $APP_PATH"
}

sign_with_developer_id() {
    log "Developer ID で再署名"

    # エンタイトルメントファイル
    local ENTITLEMENTS="$PROJECT_ROOT/macos/Runner/Release.entitlements"

    # 全てのフレームワークとライブラリに署名
    echo "フレームワークに署名中..."
    find "$APP_PATH/Contents/Frameworks" -type f -perm +111 -exec codesign --force --options runtime --sign "$DEVELOPER_ID" {} \; 2>/dev/null || true
    find "$APP_PATH/Contents/Frameworks" -name "*.framework" -exec codesign --force --options runtime --sign "$DEVELOPER_ID" {} \; 2>/dev/null || true
    find "$APP_PATH/Contents/Frameworks" -name "*.dylib" -exec codesign --force --options runtime --sign "$DEVELOPER_ID" {} \; 2>/dev/null || true

    # メインアプリに署名
    echo "アプリ本体に署名中..."
    codesign --force --options runtime --sign "$DEVELOPER_ID" --entitlements "$ENTITLEMENTS" "$APP_PATH"

    echo "✓ Developer ID署名完了"
}

verify_signature() {
    log "コード署名確認"

    # 署名確認
    if ! codesign --verify --deep --strict "$APP_PATH" 2>&1; then
        echo "Error: アプリの署名が無効です"
        exit 1
    fi
    echo "✓ 署名確認OK"

    # 署名情報表示
    echo ""
    echo "署名情報:"
    codesign -dv --verbose=2 "$APP_PATH" 2>&1 | grep -E "(Authority|TeamIdentifier|Identifier)" || true
}

notarize_app() {
    if [ "$SKIP_NOTARIZE" = "1" ]; then
        echo "公証をスキップします"
        return
    fi

    log "アプリ公証"

    # ZIP作成（公証用）
    local ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
    echo "ZIPファイル作成中..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    # 公証送信
    echo "公証サービスに送信中..."
    local SUBMIT_OUTPUT
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait 2>&1)

    echo "$SUBMIT_OUTPUT"

    # 結果確認
    if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
        echo "✓ 公証成功"
    else
        echo "Error: 公証失敗"
        # 詳細ログ取得
        local SUBMISSION_ID
        SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
        if [ -n "$SUBMISSION_ID" ]; then
            echo "詳細ログ:"
            xcrun notarytool log "$SUBMISSION_ID" \
                --apple-id "$APPLE_ID" \
                --team-id "$TEAM_ID" \
                --password "$APP_PASSWORD" || true
        fi
        exit 1
    fi

    # Stapling
    echo "Stapling..."
    xcrun stapler staple "$APP_PATH"
    echo "✓ Stapling完了"

    # ZIPクリーンアップ
    rm -f "$ZIP_PATH"
}

create_dmg() {
    log "DMG作成"

    # 出力ディレクトリ作成
    mkdir -p "$DIST_DIR"

    # 既存DMG削除
    rm -f "$DMG_PATH"

    # DMG作成
    echo "DMGファイル作成中..."
    create-dmg \
        --volname "$APP_NAME" \
        --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 190 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_PATH"

    echo "✓ DMG作成完了: $DMG_PATH"

    # DMGに署名
    echo "DMGに署名中..."
    codesign --force --sign "$DEVELOPER_ID" "$DMG_PATH"
    echo "✓ DMG署名完了"
}

notarize_dmg() {
    if [ "$SKIP_NOTARIZE" = "1" ]; then
        echo "DMG公証をスキップします"
        return
    fi

    log "DMG公証"

    # 公証送信
    echo "公証サービスに送信中..."
    local SUBMIT_OUTPUT
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait 2>&1)

    echo "$SUBMIT_OUTPUT"

    # 結果確認
    if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
        echo "✓ DMG公証成功"
    else
        echo "Error: DMG公証失敗"
        exit 1
    fi

    # Stapling
    echo "Stapling..."
    xcrun stapler staple "$DMG_PATH"
    echo "✓ Stapling完了"
}

verify_dmg() {
    log "最終確認"

    # DMGの署名・公証確認
    echo "DMG検証:"
    spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" 2>&1 || true

    # ファイルサイズ
    local SIZE
    SIZE=$(du -h "$DMG_PATH" | cut -f1)
    echo ""
    echo "=========================================="
    echo "  完了!"
    echo "=========================================="
    echo ""
    echo "出力ファイル: $DMG_PATH"
    echo "ファイルサイズ: $SIZE"
    echo "バージョン: $VERSION"
    echo ""
}

# ===== メイン =====
main() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  $APP_NAME macOS DMG Builder             ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "バージョン: $VERSION"
    echo "出力先: $DMG_PATH"
    echo ""

    check_requirements
    build_app
    sign_with_developer_id
    verify_signature
    notarize_app
    create_dmg
    notarize_dmg
    verify_dmg
}

main "$@"
