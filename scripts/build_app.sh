#!/bin/bash
# 自用安装：编译并组装 ClipHistory.app → 退出旧版本 → 安装到 ~/Applications 并启动
set -euo pipefail

APP_NAME="ClipHistory"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/Applications"

"$PROJECT_DIR/scripts/assemble_app.sh"

echo "==> 退出旧版本"
pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true

echo "==> 安装到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$PROJECT_DIR/build/$APP_NAME.app" "$INSTALL_DIR/"

echo "==> 启动"
open "$INSTALL_DIR/$APP_NAME.app"
echo "完成：$INSTALL_DIR/$APP_NAME.app"
