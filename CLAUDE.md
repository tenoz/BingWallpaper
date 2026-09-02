---
title: 必应每日壁纸采集 · 项目规则
created: 2026-09-01
updated: 2026-09-02
status: 任务A / 任务B 均已完成
---

# 必应每日壁纸采集

把必应每日 4K 壁纸采集到本地，并自动/手动切换 macOS 桌面壁纸。

## 目录分工（别搞混）

| 用途 | 路径 | 说明 |
|---|---|---|
| **项目/开发** | `/Users/pxdog/Project/BingWallpaper/` | 源码、图标、构建脚本、本文档 |
| **数据/图片** | `/Users/pxdog/Pictures/bing-wallpaper/` | 壁纸存放地（**可在 App 菜单里改**） |
| **产物 App** | `/Applications/BingWallpaper.app` | 编译后的菜单栏应用 |

项目目录内容：
```
BingWallpaperApp.swift   源码（Swift，SwiftUI MenuBarExtra）
backfill.py              任务 A 历史回填脚本（Python，解析仓库索引批量下载）
logo2.jpeg               当前图标源，1632×1632 正方 JPEG
AppIcon.icns / .iconset  由 logo 生成的图标产物
build.sh                 一键构建脚本
README.md                面向使用/接手的说明（怎么用、怎么排错）
CLAUDE.md                本文档（面向 AI 的规则）
```

> 受众区分：`README.md` 讲"怎么用、怎么排错"，本文档讲"改代码时必须遵守什么"。
> 两者不互相抄全文。

## 两个彼此独立的任务

### 任务 A · 历史回填 —— 已完成（2026-09-02）
脚本 `backfill.py`：解析 GitHub 仓库 `niumoo/bing-wallpaper` 的
`picture/YYYY-MM/README.md` 索引，拼裸 `_UHD.jpg` 直链下载 2021-02 至今存量。

```bash
PY=/Users/pxdog/.workbuddy/binaries/python/versions/3.13.12/bin/python3
$PY backfill.py --dry-run   # 空跑看清单
$PY backfill.py             # 真跑
```

- 参数：`--start/--end`（YYYY-MM）、`--dir`、`--workers`（默认 6）、`--dry-run`
- 断点续传：重跑即跳过已有（按目录文件名 + `downloaded.json` 的**大写 ID** 去重）
- 索引拉取偶发 SSL 握手超时（68 个月约 3 次），脚本内已重试 3 次

**日期基准（老大 2026-09-02 拍板）**：用仓库原始日期，**不对齐**任务 B 的接口日期。
后果：现有 16 张比同图的历史命名早 2 天；日期序列仍连续单调，且**不产生重复文件**。

**`downloaded.json` 的处理（分两个阶段，别搞混）**：
- 回填**过程中**不回写：App 接口窗口仅最近 16 天、与历史图不重叠，本就无需回写；
  且运行中的 App 会用内存里的旧 manifest 覆盖文件，造成竞态。
- 回填**完成后**已停 App 一次性合并：**16 → 2038 条**
  （备份 `/tmp/downloaded.json.bak-20260902-*`，重启后复查仍为 2038，未被覆盖）。
  此后即便重装 App、清清单或换目录，也不会把历史图重下一遍。
- 若要重做：先 `pkill -x BingWallpaper`，改完再 `open -a /Applications/BingWallpaper.app`。

**全量实测结果**：68 个月 / 索引 2040 条 / 去重 2035 / 实下 **1994 张，失败 0**，耗时 1h21m。
独立核验：总计 **2038 张 / 7.14GB**（平均 3.59MB/张），命名不合规范 0、非 JPEG 0、
`.part` 残留 0、**MD5 重复 0 组、同 ID 重复 0**。App 未受影响（进程存活、清单仍是 16 条）。

日期覆盖 2021-02-01 ~ 2026-09-01，缺 5 天，**均有合理解释、无需补**：
4 天（2021-03-01/02、2022-10-07、2023-01-26）上游索引本身未收录；
1 天（2021-08-04）是上游把 `WachsenburgCastle` 重复收录于 07-22 与 08-04，
按 ID 去重只下一次（文件落在 07-22），属正确行为。

另：2026-08-17/18/20/24 各有一天两张，是两套日期体系撞档（App 接口日 vs 仓库日），
MD5 确认是**内容不同的两张图**，非重复，无需处理。

### 任务 B · 菜单栏 App —— 已完成并验证
`/Applications/BingWallpaper.app`，Swift 原生，功能：
- 抓最新 Bing 4K 壁纸并下载
- 按**自身清单**去重，不重复下载
- 更新方式二选一（存 `updateMode`）：**按间隔**（1/3/6/12/24 小时，默认 3，存 `intervalHours`）
  / **每天定时**（00:00–23:00 整点，默认 08:00，存 `dailyHour`；一次性定时器到点重排防漂移）
- 壁纸填充方式（存 `scalingMode`，默认充满屏幕）：充满屏幕 / 适合于屏幕 /
  拉伸以充满屏幕 / 居中，映射 `NSImageScaling`，选择后立即对当前壁纸重应用
- 自动切换（最新 / 随机）
- 手动切换：菜单顶部预览图**两侧圆形按钮** = 上一张 / 下一张（从系统当前壁纸反查索引，无状态）
- 菜单顶部显示当前桌面壁纸预览图（`.window` 样式 + ImageIO 缩略图，maxPixel 560）
- 菜单可手动触发下载
- 下载目录可手动指定（默认 `/Users/pxdog/Pictures/bing-wallpaper`，存 UserDefaults 的 `picsDir`）
- 开机启动开关，**默认关闭**

## 版本管理

git 仓库（main 分支），`.gitignore` 排除：`.DS_Store`、`.workbuddy/`（会话记忆）、
`build/`、`AppIcon.iconset/`、`AppIcon.icns`、`.logo-src.png`（全部可由 logo2.jpeg + build.sh 重建）。

## 铁律与约定

1. **图片命名**：`YYYY-MM-DD_OHR.图片名.jpg`，平铺在壁纸目录。
   日期即时间戳；保留图片 ID 是为了扫文件名就能识别"这张下过了"。
2. **图片 ID 规范化（两种形态别混用）**：`stripMarket()` 依次剥掉 `_UHD.jpg` 与市场
   后缀 `_XX-XX数字`，**保留原始大小写** → `OHR.SamarkandCeiling`，这个用于**文件名**（驼峰）。
   大写形态 `OHR.SAMARKANDCEILING` 只作 `downloaded.json` 的**去重键**，不进文件名。
   ⚠️ 返回值**本身已带 `OHR.` 前缀**，任何地方都别再拼一次——曾因此拼出
   `OHR.OHR.XXX` 让任务 A 的去重整体失效（2000 张会全部重下）。
3. **去重策略（老大明确要求）**：任务 B **只与自己的清单比对**
   （`~/Library/Application Support/BingWallpaper/downloaded.json`），
   **不向后比对仓库历史文件**。代价：首次运行会与历史文件产生约 15 张重复，已接受。
4. **删除铁律**：绝不主动删除任何文件。要删先说明原因 + 影响，等老大明确确认。
   任务 A 跑完后的重复文件**只列出，不自动删**。
5. **改完必须验证**：不靠间接证据下结论（见下方"已知的坑"）。

## 构建与运行

```bash
/Users/pxdog/Project/BingWallpaper/build.sh
```
脚本依次：停 App → 生成图标 → **暂存目录**编译 + 写 Info.plist + ad-hoc 签名并验证 →
搬运到 /Applications → 重启 App。
**别改回在 /Applications 原地签名**：macOS 26 下原地签名会产生坏 seal（见"已知的坑"）。

手动启动：`open -a /Applications/BingWallpaper.app`

⚠️ 源码**不能**命名为 `main.swift`（否则 `@main` 与顶层代码冲突），且必须 `-parse-as-library`。

## 实测技术事实（2026-09-01 亲测，可信，别重复验证）

- 必应接口 `HPImageArchive.aspx`：`n` 钳在 8、`idx` 钳在 8 → **可达窗口最多 16 天**。
  换 `cn.bing.com` 主机、换 `format=rss` 结果一致，**无后门**
- GitHub 仓库 `picture/` 下**只有 README 没有图片文件**，但 README 含完整
  「日期 → 4K 直链」，覆盖 2021-02 → 今约 65 个月
- **两源固定 2 天偏移**：同一张图，**zh-CN 接口**日期比仓库日期早 2 天
  （SamarkandCeiling：接口 08-30 / 仓库 09-01），**13/13 抽样严格吻合**。
  ⚠️ 用 en-US 接口测只差 1 天（en-US 比 zh-CN 晚 1 天），算偏移务必先确认 mkt。
  另：两源并非严格一一对应，个别图（WhyteCliffP / EndofHeatY26）在仓库对应日被别的图占位。
- **仓库 README 的原链不能用**：带 `&rf=…&w=3840&h=2160`，CDN 会重压。同为 3840×2160，
  体积 2.43MB vs 裸链 3.82MB（少 36%），且 MD5 与 App 下载的不一致。
  **只取 `id=` 参数自行拼 `https://www.bing.com/th?id=<ID>_UHD.jpg`**。
- **历史图体积实测**：平均 4.24 MB/张（2021-02 抽样 28 张 = 118.7MB），全量约 2000 张 ≈ 8.3GB。
  部分老图原图**超过 4K**（最高 8664×4873）——`_UHD.jpg` 返回的是该图最大可用分辨率，非固定 4K。
- **`osascript` + System Events 被拦（-10004 权限违例）**。换壁纸必须走 `NSWorkspace`，
  **不需要任何 Automation 授权**
- **`/usr/bin/python3` 是 3.9.6**；终端里的 3.13.12 在 `~/.workbuddy/...` 下，
  launchd 的 PATH 看不到它（定时任务若依赖会静默失效）
- **`launchctl` 写操作在 agent shell 中一律 EIO 失败**（`bootstrap`/`bootout`/`load`
  报 `5: Input/output error`），读操作正常。根因是 shell 不在 GUI 会话上下文。
  **要改 launchd 注册状态，交给 App 自身（GUI 进程）调 launchctl。**
- 环境：macOS 26.6.2 Tahoe / arm64 / 完整 Xcode（swiftc 6.3.3）/ 磁盘剩余 157GB

## 已知的坑（都踩过，别再踩）

- **图标生成**：`sips` 从 jpeg 源输出 `.png` 时**只改后缀不改编码**，
  `iconutil` 会报 `Failed to generate ICNS`。
  **必须先用 `sips -s format png` 把源转成真 PNG，再生成各尺寸。**
- **别信壁纸 `Index.plist` 的 `LastSet` 字段**：那是「系统设置」App 的记账字段，
  不走 NSWorkspace 更新。设完壁纸后它仍显示旧日期，极易误判为"没生效"。
  验证壁纸请写 Swift 探针读 `NSWorkspace.shared.desktopImageURL(for:)`。
- **shell 里别用 `/tmp` 做路径前缀判断**：macOS 会解析成 `/private/tmp`，断言会误判。
- **`ls -t` 按修改时间排序不可靠**：批量下载时文件同秒，排序会乱。
  文件名以 `YYYY-MM-DD` 开头，用字典序（默认 `sort`）才是时间序。
- **agent shell 里 `ps` 被拦**：查进程存活用 `pgrep -x <名>` + `kill -0 <pid>`。
- **Swift init 顺序**：实例计算属性不能在 init 里访问（报 `self used before all
  stored properties are initialized`），路径常量请放顶层 `let`。
  有 didSet 的存储属性同理：init 里赋值不触发 didSet，且必须在访问 self 前先初始化。
- **桌面图选项常量未被 Swift 导入**：`NSWorkspaceDesktopImageScalingKey` 等
  在本 SDK（swiftc 6.3.3）**没有**导入为 `NSWorkspace.DesktopImageOptionKey.scaling`
  等成员（`.scalingKey` 变体也不存在），但类型改名通知又指向该类型。
  **用 `init(rawValue: "NSWorkspaceDesktopImageScalingKey")` 构造**（实测可用）。
- **「拼贴」无公开 API**：`setDesktopImageURL` 选项仅 scaling / allowClipping / fillColor，
  系统设置的拼贴走私有 WallpaperKit。要支持只能预合成拼贴大图再以充满屏幕应用，
  代价：桌面 URL 变成合成文件，上一张/下一张导航失效（见"未决"）。
- **/Applications 原地 ad-hoc 签名会产坏 seal（macOS 26 实测）**：`codesign -s -` 对
  /Applications 下的 bundle 签名后，`CodeResources` 的 files2 把主程序记成
  `MacOS/BingWallpaper.cstemp`（签名临时文件名），`codesign -v` 报
  `a sealed resource is missing or invalid`，删签名重签仍 100% 复现；
  **同一 bundle 在项目目录签名一次通过**。build.sh 因此改为暂存构建+验证后 ditto 搬运。
  排查时用 `plutil -p .../CodeResources | grep cstemp` 认症。

## 待办

- [x] 任务 A：历史回填脚本 `backfill.py`（已建，2021-02 全月 28 张实测通过）
- [x] 跑任务 A 前确认壁纸目录（`/Users/pxdog/Pictures/bing-wallpaper`）
- [x] 全量下载收尾：1994 张全部成功，失败 0，已独立核验
- [x] 重复文件清单：**零重复**（MD5 比对 2038 张，0 组相同）

## 未决（未排期）

- 菜单栏图标是否换成 logo —— **未排期**。触发条件：老大提供纯黑单色剪影版素材
  （全彩 logo 缩到 18px 会糊；macOS 菜单栏图标惯例走单色模板模式）
- 壁纸填充第五种「拼贴」—— **未排期**。公开 API 不支持（见"已知的坑"），
  可行方案是预合成拼贴大图 + 充满屏幕应用，会破坏上一张/下一张导航。
  触发条件：老大确认真的需要拼贴 4K 图（4K 图拼 4K 屏 ≈ 居中，实际意义存疑）。
