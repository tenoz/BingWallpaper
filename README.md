# BingWallpaper

macOS 菜单栏小工具：抓取必应每日 4K 壁纸，并切换桌面壁纸。

- 语言：Swift（SwiftUI `MenuBarExtra`），单文件，无第三方依赖
- 系统要求：macOS 13+（开发与实际运行均在 macOS 26 Tahoe / Apple Silicon）
- 形态：菜单栏常驻，无 Dock 图标（`LSUIElement`）
- 更新节奏：**每天定时**自动检查一次（默认 08:00），App 启动 / 电脑唤醒也会各查一次作兜底；也可随时手动切换/手动触发

---

## 快速开始

```bash
# 构建并启动（一条命令搞定：生成图标 → 暂存目录构建 → 签名 → 搬运到 /Applications → 重启）
./build.sh

# 手动启动
open -a /Applications/BingWallpaper.app
```

> 构建脚本会把产物装到 `/Applications/BingWallpaper.app`，**不需要 Xcode 图形界面**，
> 只用命令行 `swiftc`。详情见 [CLAUDE.md](CLAUDE.md)。

---

## 怎么用

点菜单栏的图片图标，下拉菜单包含：

| 菜单项 | 说明 |
|---|---|
| **顶部预览图** | 当前桌面壁纸的 16:9 缩略图，**两侧圆形按钮为 上一张 / 下一张** |
| 设为最新 | 立即切到库里日期最新的那张 |
| 随机一张 | 从整个库随机抽一张 |
| **壁纸填充 → 充满屏幕 / 适合于屏幕 / 拉伸以充满屏幕 / 居中** | 壁纸缩放方式（默认充满屏幕，选择后立即重新应用） |
| **更新时间** | **每天定时**检查一次（默认 08:00）。「自定义时间…」弹窗里**直接输数字即可**，冒号会自动补（`0830` → `08:30`；只输 1–2 位按整点算，如 `21` → `21:00`），并保存最近 3 个使用过的时段供快捷选择 |
| 立即检查更新 | 手动触发一次抓取（下载后自动应用最新一张） |
| 打开壁纸文件夹 | 在 Finder 打开当前壁纸目录 |
| 选择下载目录… | 改壁纸存放位置，选择后持久化 |
| 开机启动 | 默认**关闭**；勾选后安装 LaunchAgent 实现登录自启 |
| 退出 | 退出应用 |

预览图下方实时显示：当前壁纸文件名、运行状态、当前下载目录。

---

## 源码仓库

<https://github.com/tenoz/BingWallpaper>（**私有仓库**，需有访问权限）

---

## 目录与文件

| 路径 | 用途 |
|---|---|
| 本目录 | 源码 `BingWallpaperApp.swift`、历史回填脚本 `backfill.py`、图标、构建脚本、文档 |
| `/Users/pxdog/Pictures/bing-wallpaper/` | 壁纸存放地（**默认**，可在菜单里改） |
| `/Applications/BingWallpaper.app` | 构建产物 |
| `~/Library/Application Support/BingWallpaper/downloaded.json` | 已下载图片 ID 清单（去重依据） |
| `~/Library/LaunchAgents/com.pxdog.bingwallpaper.plist` | 开机启动配置（开关关闭时不存在） |

图片命名：`YYYY-MM-DD_OHR.图片名.jpg`，平铺存放。

---

## 它怎么工作

1. 启动时、之后**每天定时**（默认 08:00）、以及**电脑唤醒**时各检查一次（后两者是兜底，接住睡眠/冷启动漏更），
   请求必应接口 `HPImageArchive.aspx`
   （受服务端限制，`idx` 和 `n` 都被钳在 8，故一次最多覆盖约 16 天）
2. 拿到候选图后，用**规范化后的图片 ID** 与 `downloaded.json` 比对，只下载清单里没有的
3. 下载时校验 JPEG 文件头与体积，避免把错误页存成图片
4. 按壁纸填充方式用 `NSWorkspace` 设置壁纸（**不需要任何"自动化"权限授权**）

> ⚠️ 检查**只在 App 运行时生效**。开机启动默认关闭，没勾选的话电脑重启后不手动启动一次，
> 自动更新就等于没开；不过合盖睡眠后**开盖会触发一次检查**（唤醒补查），睡眠导致的漏更会被自动接住。

> 系统设置里的第五种缩放「拼贴」未提供：`NSWorkspace` 公开 API 不支持
> （选项仅缩放/裁剪/底色），详见 [CLAUDE.md](CLAUDE.md)「未决」。

---

## 历史回填（backfill.py）

菜单栏 App 只能回溯约 16 天，更早的存量用这个脚本一次性补：

```bash
PY=/Users/pxdog/.workbuddy/binaries/python/versions/3.13.12/bin/python3
$PY backfill.py --dry-run   # 先看清单，不下载
$PY backfill.py             # 正式下载
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--start` / `--end` | `2021-02` / 当前月 | 月份范围（YYYY-MM） |
| `--dir` | `~/Pictures/bing-wallpaper` | 壁纸目录 |
| `--workers` | 6 | 并发数 |
| `--dry-run` | 关 | 只列清单不下载 |

- **可断点续传**：重跑即跳过已有文件，中断后直接再跑一次即可，不会重复下载。
- 已回填 2021-02 ~ 2026-09 共 1994 张（全库 2038 张 / 7.14GB）。
- 命名沿用 `YYYY-MM-DD_OHR.图片名.jpg`，但日期取**仓库标注日**，比 App 用的接口日期晚 2 天——
  这是刻意选择（详见 [CLAUDE.md](CLAUDE.md)，两套日期并存不影响使用）。

---

## 已知限制

- 菜单栏 App 受接口限制只能回溯约 16 天；更早的存量已用 `backfill.py` 回填至 2021-02（见上一节）。
- 开机启动默认关闭，重启电脑后需手动启动一次（或勾选开机启动）。
- 换壁纸目录**不会搬运旧文件**，新旧目录各自独立。
- 菜单栏图标用的是系统 SF Symbol，不是 App 图标。

---

## 排错

| 现象 | 排查 |
|---|---|
| 菜单栏没有图标 | 确认 App 在运行：`pgrep -x BingWallpaper`；没运行就 `open -a /Applications/BingWallpaper.app` |
| 壁纸没换 | 看菜单顶部状态文字；显示"设置可能未生效"说明系统调用被拒 |
| 想确认当前壁纸 | 菜单顶部会显示当前文件名 |
| 改了源码不生效 | 必须重新跑 `./build.sh`（改源码不会自动热更新） |

更多技术细节、实测结论与坑位见 [CLAUDE.md](CLAUDE.md)。
