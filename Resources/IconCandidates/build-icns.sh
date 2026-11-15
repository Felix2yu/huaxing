#!/bin/bash
# 把 1024×1024 设计稿转成 macOS 标准 .icns（10 个尺寸，@1x/@2x 成对）。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# iconutil 约定的 iconset 文件名 → 像素尺寸
SIZES=(
  "icon_16x16.png 16"
  "icon_16x16@2x.png 32"
  "icon_32x32.png 32"
  "icon_32x32@2x.png 64"
  "icon_128x128.png 128"
  "icon_128x128@2x.png 256"
  "icon_256x256.png 256"
  "icon_256x256@2x.png 512"
  "icon_512x512.png 512"
  "icon_512x512@2x.png 1024"
)

for name in "1-墨印" "2-折光" "3-线环" "4-叠片" "5-融形" "6-化圆"; do
  src="$name.png"
  [ -f "$src" ] || { echo "缺少设计稿：$src（先运行 swift generate.swift .）" >&2; exit 1; }

  set="$name.iconset"
  rm -rf "$set"
  mkdir -p "$set"
  for spec in "${SIZES[@]}"; do
    file="${spec%% *}"
    px="${spec##* }"
    sips -z "$px" "$px" "$src" --out "$set/$file" > /dev/null
  done

  iconutil -c icns "$set" -o "$name.icns"
  printf '✓ %-14s %s  (%s 个尺寸)\n' "$name.icns" \
    "$(du -h "$name.icns" | cut -f1)" "$(ls "$set" | wc -l | tr -d ' ')"
done

echo "候选已就绪；尚未写入 App（Resources/化形.icns 不存在，Info.plist 也未引用图标）。"
echo "请先确认采用哪一个，之后再做集成；本脚本不替你做选择。"
