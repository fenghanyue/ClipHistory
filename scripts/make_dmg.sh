#!/bin/bash
# 打包可以发给同事的 DMG（免费版：用自签名证书签名，没有经过苹果付费认证和公证，仅支持 Apple 芯片）
# 产物：dist/ClipHistory-<版本号>.dmg，里面有 ClipHistory.app、「应用程序」快捷方式、安装前请看.txt
set -euo pipefail

APP_NAME="ClipHistory"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Resources/Info.plist")"
STAGE_DIR="$PROJECT_DIR/build/dmg-stage"
DMG_PATH="$PROJECT_DIR/dist/$APP_NAME-$VERSION.dmg"

"$PROJECT_DIR/scripts/assemble_app.sh" --require-cert

echo "==> 准备 DMG 内容"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$(dirname "$DMG_PATH")"
cp -R "$PROJECT_DIR/build/$APP_NAME.app" "$STAGE_DIR/"
# 拖到这个快捷方式上即可安装
ln -s /Applications "$STAGE_DIR/应用程序"
cat > "$STAGE_DIR/安装前请看.txt" <<EOF
ClipHistory $VERSION —— 剪贴板历史小工具
适用于 Apple 芯片（M 系列）的 Mac，需要 macOS 14 或更新版本

【安装】
1. 把 ClipHistory 拖到旁边的「应用程序」里，再到「应用程序」里双击打开
   （拖不进去的话，拖到桌面上双击也能用）
2. 如果提示"无法打开"或"无法验证开发者"：
   打开「系统设置 → 隐私与安全性」，往下找到 ClipHistory，点「仍要打开」
   （这个小工具没有做苹果的付费认证，第一次打开、以及每次更新后都要点一次）
3. 按提示在「系统设置 → 隐私与安全性 → 辅助功能」里打开 ClipHistory 的开关（用来自动输入）

【使用】
- 平时正常复制，会自动记录；记录只保存在你自己的电脑上
- 在输入框里按 ⌥⌘V（Option + Command + V）弹出历史，点一条就自动输入
- 右上角菜单栏的剪贴板图标里，可以暂停记录、清空历史
EOF

echo "==> 生成 DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE_DIR" -format UDZO -ov "$DMG_PATH" >/dev/null
echo "完成：$DMG_PATH"
