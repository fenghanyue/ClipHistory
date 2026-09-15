#!/bin/bash
# 用法：scripts/swift.sh build | test | run ...   （参数原样传给 swift 命令）
#
# 为什么需要这个包装脚本：本机的命令行工具（CLT 16.2）从旧版本升级时没有清理干净，残留了两类旧文件，
# 直接运行 swift build 会失败。这里在项目的 .build/toolchain-fix 目录下做绕过处理，系统文件保持不动。
# 以后命令行工具重装或修复后，检测不到这些旧文件，对应的绕过就自动不再生效。
#
#   残留 1：usr/lib/swift/pm/*API/*.swiftmodule/*.private.swiftinterface（2024-02，Swift 5.10）
#          编译器优先读取它们，和新版 SwiftPM 库对不上 → Package.swift 本身编译失败
#          绕过：复制一份去掉旧文件的 SwiftPM 库，用 SWIFTPM_CUSTOM_LIBS_DIR 指过去
#   残留 2：usr/include/swift/module.modulemap（2023-08），和新版 bridging.modulemap 重复定义 SwiftBridging 模块
#          → 无法编译 import Foundation / AppKit 的代码
#          绕过：用虚拟文件映射（-vfsoverlay）让编译器把这个旧文件看成空文件
set -euo pipefail

CLT="/Library/Developer/CommandLineTools"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIX_DIR="$PROJECT_DIR/.build/toolchain-fix"
EXTRA_FLAGS=()

# --- 残留 1：比同目录公开接口文件更旧的私有接口文件 ---
SYSTEM_PM="$CLT/usr/lib/swift/pm"
STALE_INTERFACES=()
for private_file in "$SYSTEM_PM"/*API/*.swiftmodule/*.private.swiftinterface; do
  [ -e "$private_file" ] || continue
  public_file="${private_file%.private.swiftinterface}.swiftinterface"
  if [ -e "$public_file" ] && [ "$private_file" -ot "$public_file" ]; then
    STALE_INTERFACES+=("$private_file")
  fi
done
if [ ${#STALE_INTERFACES[@]} -gt 0 ]; then
  FIXED_PM="$FIX_DIR/swiftpm-libs"
  # 副本不存在，或系统库已更新（dylib 内容变了）时，重新生成副本
  if ! cmp -s "$SYSTEM_PM/ManifestAPI/libPackageDescription.dylib" \
              "$FIXED_PM/ManifestAPI/libPackageDescription.dylib" 2>/dev/null; then
    rm -rf "$FIXED_PM"
    mkdir -p "$FIXED_PM"
    cp -R "$SYSTEM_PM/ManifestAPI" "$SYSTEM_PM/PluginAPI" "$FIXED_PM/"
    for stale_file in "${STALE_INTERFACES[@]}"; do
      rm -f "$FIXED_PM${stale_file#"$SYSTEM_PM"}"
    done
  fi
  export SWIFTPM_CUSTOM_LIBS_DIR="$FIXED_PM"
fi

# --- 残留 2：新旧两个 modulemap 重复定义 SwiftBridging ---
SWIFT_INCLUDE="$CLT/usr/include/swift"
if grep -qs "module SwiftBridging" "$SWIFT_INCLUDE/module.modulemap" &&
   grep -qs "module SwiftBridging" "$SWIFT_INCLUDE/bridging.modulemap"; then
  mkdir -p "$FIX_DIR"
  : > "$FIX_DIR/empty.modulemap"
  cat > "$FIX_DIR/overlay.yaml" <<EOF
{
  "version": 0,
  "roots": [
    {
      "type": "directory",
      "name": "$SWIFT_INCLUDE",
      "contents": [
        { "type": "file", "name": "module.modulemap", "external-contents": "$FIX_DIR/empty.modulemap" }
      ]
    }
  ]
}
EOF
  EXTRA_FLAGS+=(-Xswiftc -vfsoverlay -Xswiftc "$FIX_DIR/overlay.yaml")
fi

cd "$PROJECT_DIR"
case "${1:-}" in
  # 只有编译类子命令接受 -Xswiftc 参数
  build|test|run) exec swift "$@" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} ;;
  *) exec swift "$@" ;;
esac
