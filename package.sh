#!/bin/bash
# BingWallpaper 分发打包（方案 B：无开发者账号，对方需右键打开）
# 用法：./package.sh
# 产物：dist/BingWallpaper-<版本>.zip
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/BingWallpaper.app"

# 从 build.sh 里提取版本号（单一来源，不在脚本里再写一份）
VERSION=$(grep -A1 'CFBundleShortVersionString' "$PROJ/build.sh" \
          | grep '<string>' | head -1 \
          | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
[ -z "$VERSION" ] && { echo "无法从 build.sh 提取版本号"; exit 1; }

echo "▶ 构建最新 App"
"$PROJ/build.sh"

echo "▶ 停止 App（避免文件占用）"
pkill -x BingWallpaper 2>/dev/null && sleep 1 || true

DIST="$PROJ/dist"
mkdir -p "$DIST"
ZIP="$DIST/BingWallpaper-$VERSION.zip"

echo "▶ 压缩 App → $ZIP"
# ditto 保留 bundle 结构与执行权限；zip 格式会清掉扩展属性（quarantine 等），正合需要
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▶ 重启 App"
open -a "$APP"

echo ""
echo "✅ 打包完成：$ZIP"
echo ""
echo "给对方的说明（建议连同 zip 一起发）："
echo "  1. 解压 zip，把 BingWallpaper.app 拖进「应用程序」"
echo "  2. 双击会被 Gatekeeper 拦（无开发者签名）："
echo "     **右键点 App → 打开 → 再点「打开」**，之后不会再拦"
echo "  3. 仅适配 Apple Silicon (arm64)"
