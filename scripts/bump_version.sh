#!/bin/bash
#
# バージョンバンプスクリプト
#
# 使用方法:
#   ./scripts/bump_version.sh patch   # 0.1.0 → 0.1.1
#   ./scripts/bump_version.sh minor   # 0.1.0 → 0.2.0
#   ./scripts/bump_version.sh major   # 0.1.0 → 1.0.0
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PUBSPEC="$PROJECT_ROOT/pubspec.yaml"

# 引数チェック
if [ -z "$1" ]; then
    echo "使用方法: $0 <patch|minor|major>"
    echo ""
    echo "  patch  - パッチバージョンを上げる (0.1.0 → 0.1.1)"
    echo "  minor  - マイナーバージョンを上げる (0.1.0 → 0.2.0)"
    echo "  major  - メジャーバージョンを上げる (0.1.0 → 1.0.0)"
    exit 1
fi

BUMP_TYPE="$1"

# 現在のバージョン取得
CURRENT=$(grep '^version:' "$PUBSPEC" | sed 's/version: //')
VERSION=$(echo "$CURRENT" | cut -d'+' -f1)
BUILD=$(echo "$CURRENT" | cut -d'+' -f2)

# バージョン番号を分解
MAJOR=$(echo "$VERSION" | cut -d'.' -f1)
MINOR=$(echo "$VERSION" | cut -d'.' -f2)
PATCH=$(echo "$VERSION" | cut -d'.' -f3)

echo "現在のバージョン: $VERSION+$BUILD"

# バージョンバンプ
case "$BUMP_TYPE" in
    patch)
        PATCH=$((PATCH + 1))
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    *)
        echo "Error: 不明なバンプタイプ: $BUMP_TYPE"
        echo "patch, minor, major のいずれかを指定してください"
        exit 1
        ;;
esac

# ビルド番号をインクリメント
NEW_BUILD=$((BUILD + 1))
NEW_VERSION="$MAJOR.$MINOR.$PATCH"
NEW_FULL="$NEW_VERSION+$NEW_BUILD"

echo "新しいバージョン: $NEW_VERSION+$NEW_BUILD"

# pubspec.yaml を更新
sed -i '' "s/^version: .*/version: $NEW_FULL/" "$PUBSPEC"

echo ""
echo "✓ pubspec.yaml を更新しました"
echo ""
echo "次のステップ:"
echo "  git add pubspec.yaml"
echo "  git commit -m \"chore: bump version to $NEW_VERSION\""
