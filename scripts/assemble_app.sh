#!/bin/bash
# 编译 release 版，组装并签名 build/ClipHistory.app（build_app.sh 和 make_dmg.sh 共用）
# 用法：scripts/assemble_app.sh [--require-cert]
#   --require-cert：找不到证书就报错退出。分发版必须用固定证书签名，同事开过的辅助功能权限才能在更新后保留
set -euo pipefail

APP_NAME="ClipHistory"
SIGN_IDENTITY="ClipHistory Dev"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"
SWIFT="$PROJECT_DIR/scripts/swift.sh"

echo "==> 编译（release，Apple 芯片）"
"$SWIFT" build -c release
BIN_PATH="$("$SWIFT" build -c release --show-bin-path)/$APP_NAME"

echo "==> 组装 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> 签名"
# 有固定证书就用证书签名：重新编译后"辅助功能"权限依然有效
# 没有证书就用临时签名：每次重新编译后都要重新授权
if security find-identity -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
  echo "    已用证书 \"$SIGN_IDENTITY\" 签名"
elif [ "${1:-}" = "--require-cert" ]; then
  echo "❌ 找不到证书 \"$SIGN_IDENTITY\"：分发版必须用它签名" >&2
  exit 1
else
  codesign --force --sign - "$APP_DIR"
  echo "    未找到证书 \"$SIGN_IDENTITY\"，已用临时签名（重新编译后需要重新授权辅助功能）"
fi
codesign --verify "$APP_DIR"
