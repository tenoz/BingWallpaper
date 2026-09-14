#!/bin/bash
# 壁纸验证探针：读系统**真实生效**的桌面图，用于验证换壁纸是否真的成功。
#
# 为什么不看 Index.plist 的 LastSet：那是「系统设置」App 的记账字段，不走 NSWorkspace 更新，
# 设完壁纸后它仍显示旧日期，极易误判为"没生效"（见 CLAUDE.md「已知的坑」）。
#
# 用法：
#   ./verify-wallpaper.sh                  # 打印当前桌面壁纸的完整路径
#   ./verify-wallpaper.sh && ls -1 ~/Pictures/bing-wallpaper | sort | tail -1   # 与图库最新比对
#
# 退出码：0 正常 / 2 取不到屏幕 / 3 取不到壁纸 URL

set -e
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/probe.swift" <<'SWIFT'
import AppKit

let ws = NSWorkspace.shared
guard let s = NSScreen.main ?? NSScreen.screens.first else {
    print("NO_SCREEN")
    exit(2)
}
if let u = ws.desktopImageURL(for: s) {
    print(u.path)
} else {
    print("NO_WALLPAPER")
    exit(3)
}
SWIFT

xcrun swiftc -O -o "$TMP/probe" "$TMP/probe.swift"
"$TMP/probe"
