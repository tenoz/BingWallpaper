#!/bin/bash
# BingWallpaper 一键构建脚本
# 用法：在项目目录下执行 ./build.sh
# 作用：生成图标 → 编译 → 打包 → 签名 → 重启 App
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/BingWallpaper.app"
SRC="$PROJ/BingWallpaperApp.swift"
# 自动识别 logo 文件（logo.png / logo2.jpeg 等），换文件名也不会让构建失效
LOGO="$(ls "$PROJ"/logo* 2>/dev/null | head -1)"

echo "▶ 1/5 停止正在运行的 App"
pkill -x BingWallpaper 2>/dev/null && echo "   已停止" || echo "   未在运行"

echo "▶ 2/5 生成图标"
if [ -f "$LOGO" ]; then
  echo "   图标源: $(basename "$LOGO")"
  ICONSET="$PROJ/AppIcon.iconset"
  mkdir -p "$ICONSET"
  # 源可能是 jpeg：必须先转成真 PNG。sips 只改后缀不改编码会让 iconutil 报
  # "Failed to generate ICNS"（它只认真实 PNG 格式，不认后缀）
  SRCPNG="$PROJ/.logo-src.png"
  sips -s format png "$LOGO" --out "$SRCPNG" >/dev/null 2>&1
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SRCPNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$SRCPNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  rm -f "$SRCPNG"
  iconutil -c icns "$ICONSET" -o "$PROJ/AppIcon.icns"
  echo "   AppIcon.icns 已生成"
else
  echo "   ⚠ 未找到 logo 文件，沿用已有 AppIcon.icns"
fi

echo "▶ 3/5 编译 Swift（暂存目录）"
BUILD="$PROJ/build/BingWallpaper.app"
rm -rf "$PROJ/build"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
xcrun swiftc -O -parse-as-library \
  -o "$BUILD/Contents/MacOS/BingWallpaper" \
  "$SRC"

echo "▶ 4/5 写入 Info.plist 与图标"
cp "$PROJ/AppIcon.icns" "$BUILD/Contents/Resources/AppIcon.icns"
cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>BingWallpaper</string>
    <key>CFBundleDisplayName</key>
    <string>Bing Wallpaper</string>
    <key>CFBundleIdentifier</key>
    <string>com.pxdog.bingwallpaper</string>
    <key>CFBundleExecutable</key>
    <string>BingWallpaper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.9.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "▶ 5/5 ad-hoc 签名（暂存目录签好、验证通过后搬运到 /Applications）"
codesign -s - --force "$BUILD"
codesign -v "$BUILD"
rm -rf "$APP"
ditto "$BUILD" "$APP"
codesign -v "$APP"

echo ""
echo "✅ 构建完成"
echo "▶ 重新启动 App"
open -a "$APP"
