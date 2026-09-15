#!/bin/bash
# 从 Resources/AppIcon.source.jpg 生成标准正方形 AppIcon.icns
# 源图不必是正方形：sips -c 会居中裁剪（人物在画面中央时效果最好）
# 换图流程：替换 Resources/AppIcon.source.jpg → 运行本脚本 → 运行 build_app.sh / make_dmg.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_DIR/Resources/AppIcon.source.jpg"
ICONSET="$PROJECT_DIR/build/AppIcon.iconset"
OUT="$PROJECT_DIR/Resources/AppIcon.icns"

[ -f "$SRC" ] || { echo "❌ 找不到 $SRC" >&2; exit 1; }

echo "==> 居中裁剪为正方形"
W="$(sips -g pixelWidth  "$SRC" | awk '/pixelWidth/{print $2}')"
H="$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/{print $2}')"
SQUARE="$PROJECT_DIR/build/AppIcon.square.png"
if [ "$W" -gt "$H" ]; then
  sips -c "$H" "$H" "$SRC" --out "$SQUARE" >/dev/null
else
  sips -c "$W" "$W" "$SRC" --out "$SQUARE" >/dev/null
fi

# macOS 不会自动给图标加圆角（Launchpad 里会原样显示直角），这里用遮罩裁成圆角矩形。
# 圆角主体只占画布约 80.5%（苹果图标规范，1024 画布中图形约 824），四周留透明边距，
# 否则在 Launchpad/访达里会显得比别的图标大一圈。
echo "==> 加圆角遮罩"
ROUNDED="$PROJECT_DIR/build/AppIcon.rounded.png"
python3 - "$SQUARE" "$ROUNDED" <<'EOF'
import sys
from PIL import Image, ImageDraw

src, dst = sys.argv[1], sys.argv[2]
canvas_size = Image.open(src).width
inner = round(canvas_size * 0.805)

img = Image.open(src).convert("RGBA").resize((inner, inner), Image.LANCZOS)
mask = Image.new("L", (inner, inner), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, inner, inner],
                                       radius=round(inner * 0.225), fill=255)
img.putalpha(mask)

canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
canvas.paste(img, ((canvas_size - inner) // 2, (canvas_size - inner) // 2))
canvas.save(dst)
EOF

echo "==> 生成 iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
gen() { sips -s format png -z "$1" "$2" "$ROUNDED" --out "$ICONSET/icon_$3.png" >/dev/null; }
gen   16   16 16x16
gen   32   32 16x16@2x
gen   32   32 32x32
gen   64   64 32x32@2x
gen  128  128 128x128
gen  256  256 128x128@2x
gen  256  256 256x256
gen  512  512 256x256@2x
gen  512  512 512x512
gen 1024 1024 512x512@2x

echo "==> 生成 icns"
iconutil -c icns "$ICONSET" -o "$OUT"
rm -f "$SQUARE" "$ROUNDED"
echo "完成：$OUT"
