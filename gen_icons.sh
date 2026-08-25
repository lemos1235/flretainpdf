#!/usr/bin/env bash
# 用 icon.png 一键刷新 macOS / Windows 的应用图标。
# 用法：换了 icon.png 之后直接执行 ./update_app_icons.sh 即可。
set -euo pipefail
cd "$(dirname "$0")"

SRC_PNG="icon.png"
MAC_DEST="macos/Runner/Assets.xcassets/AppIcon.appiconset"
WIN_DEST="windows/runner/resources/app_icon.ico"

command -v png2icons >/dev/null || { echo "缺少 png2icons，请先 npm install -g png2icons" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "缺少 iconutil（需要在 macOS 上运行）" >&2; exit 1; }
[ -f "$SRC_PNG" ] || { echo "找不到 $SRC_PNG" >&2; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> 由 $SRC_PNG 生成 icon.icns / icon.ico"
png2icons "$SRC_PNG" "$WORKDIR/icon" -allwe

echo "==> 拆分 icns 得到各尺寸 png"
iconutil -c iconset "$WORKDIR/icon.icns" -o "$WORKDIR/icon.iconset"

echo "==> 写入 macOS AppIcon.appiconset"
cp "$WORKDIR/icon.iconset/icon_16x16.png"      "$MAC_DEST/app_icon_16.png"
cp "$WORKDIR/icon.iconset/icon_32x32.png"      "$MAC_DEST/app_icon_32.png"
cp "$WORKDIR/icon.iconset/icon_32x32@2x.png"   "$MAC_DEST/app_icon_64.png"
cp "$WORKDIR/icon.iconset/icon_128x128.png"    "$MAC_DEST/app_icon_128.png"
cp "$WORKDIR/icon.iconset/icon_128x128@2x.png" "$MAC_DEST/app_icon_256.png"
cp "$WORKDIR/icon.iconset/icon_512x512.png"    "$MAC_DEST/app_icon_512.png"
cp "$WORKDIR/icon.iconset/icon_512x512@2x.png" "$MAC_DEST/app_icon_1024.png"

echo "==> 写入 Windows app_icon.ico"
cp "$WORKDIR/icon.ico" "$WIN_DEST"

echo "==> 完成，同时把生成的 icon.icns / icon.ico 留在根目录备用"
cp "$WORKDIR/icon.icns" icon.icns
cp "$WORKDIR/icon.ico" icon.ico

echo "全部图标已更新完毕。"
