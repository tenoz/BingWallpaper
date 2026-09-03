---
title: 必应每日壁纸采集 · 项目规则
created: 2026-09-01
updated: 2026-09-03
status: 任务A / 任务B 均已完成；第 7–11 轮 UI 打磨**尚未提交**（等老大确认）
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
package.sh               分发打包脚本（方案 B，产出 dist/ 下的 zip）
docs/                    面向接手者的补充文档（`backfill-notes.md` 回填实测）
README.md                面向使用/接手的说明（怎么用、怎么排错）
CLAUDE.md                本文档（面向 AI 的规则）
```

> 受众区分：`README.md` 讲"怎么用、怎么排错"，本文档讲"改代码时必须遵守什么"。
> 两者不互相抄全文。

## 两个彼此独立的任务

### 任务 A · 历史回填 —— 已完成（2026-09-02）
脚本 `backfill.py`：解析 GitHub 仓库 `niumoo/bing-wallpaper` 的
`picture/YYYY-MM/README.md` 索引，拼裸 `_UHD.jpg` 直链下载 2021-02 至今存量。

- **结果**：2021-02 ~ 2026-09 共 **1994 张，失败 0**；全库 2038 张 / 7.14GB，MD5 重复 0 组
- **缺 5 天已核实无需补**（4 天上游未收录 + 1 天上游重复收录被去重）。
  别再试图补这几天——原因见 `docs/backfill-notes.md`
- **日期基准（老大 2026-09-02 拍板）**：用仓库原始日期，**不对齐**任务 B 的接口日期。
  后果：现有 16 张比同图的历史命名早 2 天；序列仍连续单调，**不产生重复文件**
- 完整实测数据、参数表、`downloaded.json` 两阶段处理 → **`docs/backfill-notes.md`**

### 任务 B · 菜单栏 App —— 已完成并验证
`/Applications/BingWallpaper.app`，Swift 原生，功能：
- 抓最新 Bing 4K 壁纸并下载
- 按**自身清单**去重，不重复下载
- **无自动模式**（2026-09-02 老大拍板去掉）：每次检查后固定应用最新一张；随机只保留手动「随机一张」
- **更新时间**（2026-09-03 老大拍板，已**移除**早期的「按间隔」二选一）：
  只有「每天定时」一种，存 `dailyTime`（默认 08:00）。「自定义时间…」弹窗输入时
  **自动补冒号**（输 `0830` 实时变 `08:30`，不必手输 `:`；只输 1-2 位数字按整点处理），
  保存最近 3 个使用过的时段（存 `recentTimes`）作快捷选择；一次性定时器到点重排防漂移
- 壁纸填充方式（存 `scalingMode`，默认充满屏幕）：充满屏幕 / 适合于屏幕 /
  拉伸以充满屏幕 / 居中，映射 `NSImageScaling`，选择后立即对当前壁纸重应用
- 手动切换：菜单顶部预览图**两侧圆形按钮** = 上一张 / 下一张（从系统当前壁纸反查索引，无状态）
- 菜单顶部显示当前桌面壁纸预览图（`.window` 样式 + ImageIO 缩略图，maxPixel 560）
- **子菜单行（壁纸填充/更新时间）**：SwiftUI 外观 + `AnchorReader` 锚点定位 +
  `NSMenu.popUp` 手工在**整行右侧**弹出；嵌套子菜单经 `NSMenuItem.submenu` 右侧级联；
  整行可点。**勿改回 SwiftUI `Menu`（只能向下弹）或 NSButton（外观与 MenuRow 不一致）**
- 【关于 Bing Wallpaper】面板：App 图标 + 版本（`0.9.0`，从 Info.plist 读）
  + 说明「必应Bing壁纸每日自动更新」+ 复制版本信息按钮；自建 NSWindow（无 NSAlert 图标）
- 菜单可手动触发下载
- 下载目录可手动指定（默认 `/Users/pxdog/Pictures/bing-wallpaper`，存 UserDefaults 的 `picsDir`）
- 开机启动开关，**默认关闭**

## 版本与分发

- 版本号单一来源：`build.sh` 里的 Info.plist（当前 **0.9.0** 测试版）；关于面板从
  `Bundle.main.infoDictionary` 读取，不在代码里写第二份
- **分发 = `package.sh`（方案 B，老大 2026-09-03 选定）**：构建 → 停 App →
  `ditto` 压 zip 到 `dist/BingWallpaper-<版本>.zip`。无开发者签名，对方需
  **右键 → 打开**绕 Gatekeeper，仅 arm64。要免拦需 Developer ID 签名 + 公证（未购）

## 版本管理

git 仓库（main 分支），`.gitignore` 排除：`.DS_Store`、`.workbuddy/`（会话记忆）、
`build/`、`dist/`、`AppIcon.iconset/`、`AppIcon.icns`、`.logo-src.png`（全部可由 logo2.jpeg + build.sh 重建）。
**提交前必须先问老大（2026-09-03 定）**

- **远端（2026-09-03 建并首推）**：`https://github.com/tenoz/BingWallpaper.git`，私有仓库

**推送认证（两个坑，都踩过）**：
- GitHub 的 git 通道**不认 `Authorization: Bearer`**（报 `invalid credentials`），
  只认 Basic：用户名填 `x-access-token`、密码填 PAT。PAT 存 `~/.github_bw_pat`（600，30 天有效）。
- ⚠️ 推送**必须绕过本机代理**：环境里 `http_proxy`/`https_proxy` 指向 `127.0.0.1:59218`，
  走它会 `CONNECT tunnel failed, response 502`（且时好时坏）。绕法：
  ```bash
  env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= \
      GIT_ASKPASS=<返回 x-access-token / 读 ~/.github_bw_pat 的脚本> git push
  ```
  令牌**不写进 `.git/config`**——remote 保持干净的 `https://github.com/...` 地址。

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
- **NSAlert 的 App 图标去不掉**：`icon` 声明为 `NSImage!`，**赋 nil 无效**（nil = 用默认
  App 图标），只能塞 1×1 透明图占位（丑）。要无图标的自定输入面板 → 自建 `NSWindow`
  + `NSApp.runModal(for:)`（见 `askCustomTime` / `TimeInputBridge`）。
  ⚠️ 自建 modal 必须同时处理点关闭按钮：`NSWindowDelegate.windowWillClose` 里 `stopModal()`，
  否则 modal 循环卡死。
- **子菜单只能在右侧级联，前提是它本身是某个 NSMenu 的子项**：MenuBarExtra(.window)
  面板里的**顶层** `Menu` 只能向下弹出，SwiftUI 没有改变弹出方向的 API。
  想让它向右展开，就得给它套一个父级 Menu（多一层点击）。
- **MenuBarExtra(.window) 里 Menu 的视觉差异**：`borderlessButton` 会改写
  标签的**字型字重 + 垂直基线 + 右侧箭头方向**（箭头会按子菜单的弹出方向自动
  旋转为 ▾），覆盖了 `.font(.body)` 也会发现字型/字重仍不同；其它图标对比
  起来就是"水平不对齐"。要去掉这些自动改写 → **完全不用 borderlessButton**，
  `Menu(configuration)` 后直接挂 padding/background/hover（见 `RowMenuStyle`）。
  此模式 `>` 方向由你自己在 `SubmenuLabel` 画（chevron.right 不会被覆盖）。
- **/Applications 原地 ad-hoc 签名会产坏 seal（macOS 26 实测）**：`codesign -s -` 对
  /Applications 下的 bundle 签名后，`CodeResources` 的 files2 把主程序记成
  `MacOS/BingWallpaper.cstemp`（签名临时文件名），`codesign -v` 报
  `a sealed resource is missing or invalid`，删签名重签仍 100% 复现；
  **同一 bundle 在项目目录签名一次通过**。build.sh 因此改为暂存构建+验证后 ditto 搬运。
  排查时用 `plutil -p .../CodeResources | grep cstemp` 认症。
- **macOS 26 的 NSTextField 窄边框会被裁一半**（2026-09-03 实测）：系统改走 layer 绘制，
  legacy `isBordered`/bezel 在小尺寸控件上只画上半截+左侧。解法：关掉
  `isBordered/isBezeled` + `focusRingType=.none`，用 `wantsLayer` + layer 的
  `borderWidth/cornerRadius/borderColor` 自绘；聚焦变色走 `NSTextFieldDelegate`
  的 `controlTextDidBegin/EndEditing`（见 `askCustomTime` / `TimeInputBridge`）。
- **同样场景下文字不垂直居中**：单行 NSTextField **没有公开的垂直对齐属性**，
  `usesSingleLineMode` 也兜不住。解法是 `NSTextFieldCell` 子类重写
  `drawingRect(forBounds:)` 把文字摆到中间（见 `CenteredTextFieldCell`）。
- **UI 改动别指望在 agent shell 里截图自证**：跑 `NSApp.runModal` 的 GUI 探针进程会被
  环境 SIGTERM（exit 137）；即便截到图也要**先确认图里真有目标窗口**——曾把拍到 Figma
  桌面的截图当成"弹窗验证通过"报错结论。模态弹窗样式一律交老大目验。

## 未决（未排期）

- 菜单栏图标是否换成 logo —— **未排期**。触发条件：老大提供纯黑单色剪影版素材
  （全彩 logo 缩到 18px 会糊；macOS 菜单栏图标惯例走单色模板模式）
- 壁纸填充第五种「拼贴」—— **未排期**。公开 API 不支持（见"已知的坑"），
  可行方案是预合成拼贴大图 + 充满屏幕应用，会破坏上一张/下一张导航。
  触发条件：老大确认真的需要拼贴 4K 图（4K 图拼 4K 屏 ≈ 居中，实际意义存疑）。
