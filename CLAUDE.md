---
title: 必应每日壁纸采集 · 项目规则
created: 2026-09-01
updated: 2026-09-14
status: 任务A / 任务B 均已完成；2026-09-14 新增「切换模式 + 自动切换间隔 + 菜单分组」，已构建并实测验证，待老大确认后提交
---

# 必应每日壁纸采集

把必应每日 4K 壁纸采集到本地，并自动/手动切换 macOS 桌面壁纸。

## 目录分工（别搞混）

| 用途 | 路径 | 说明 |
|---|---|---|
| **项目/开发** | `/Users/pxdog/Project/BingWallpaper/` | 源码、图标、构建脚本、本文档 |
| **数据/图片** | `/Users/pxdog/Pictures/bing-wallpaper/` | 壁纸存放地（**可在 App 菜单里改**） |
| **产物 App** | `/Applications/BingWallpaper.app` | 编译后的菜单栏应用 |

项目目录：`BingWallpaperApp.swift`（源码）、`backfill.py`（回填）、`build.sh` / `package.sh`、
`verify-wallpaper.sh`（壁纸验证探针）、`logo2.jpeg` + `AppIcon.*`（图标产物，可由 build.sh 重建）、
`docs/`、`README.md`、`CLAUDE.md`（本文档）。

### 深入文档（docs/ 指针表）

| 文件 | 什么时候读 |
|---|---|
| `docs/backfill-notes.md` | 要跑 / 要改历史回填 `backfill.py` 时 |
| `docs/appkit-pitfalls.md` | 要动 GUI 时（自建 modal 输入、菜单栏菜单、图标、签名） |
| `docs/decisions-and-lessons.md` | 想知道「这条约定为什么这么定」时 |
| `docs/git-and-remote.md` | 换机器 / 推送认证失败时 |
| `docs/switch-mode-design.md` | 要改**切换模式 / 自动切换间隔**（`switchMode` / `switchInterval`）时 |

> 受众区分：`README.md` 讲"怎么用、怎么排错"，本文档讲"改代码时必须遵守什么"。
> 两者不互相抄全文。

## 两个彼此独立的任务

### 任务 A · 历史回填 —— 已完成（2026-09-02）
脚本 `backfill.py`：解析 GitHub 仓库 `niumoo/bing-wallpaper` 的月度 README 索引，
拼裸 `_UHD.jpg` 直链下载 2021-02 至今存量。结果 **1994 张、失败 0**（全库 2038 张 / 7.14GB）。

- **缺 5 天已核实无需补**（4 天上游未收录 + 1 天上游重复收录被去重），别再试图补——见 `docs/backfill-notes.md`
- **日期基准（老大 2026-09-02 拍板）**：用仓库原始日期，**不对齐**任务 B 的接口日期。
  后果：现有 16 张比同图的历史命名早 2 天；序列仍连续单调，**不产生重复文件**
- 完整实测数据、参数表、`downloaded.json` 两阶段处理 → **`docs/backfill-notes.md`**

### 任务 B · 菜单栏 App —— 已完成并验证
`/Applications/BingWallpaper.app`，Swift 原生，功能：
- 抓最新 Bing 4K 壁纸并下载
- 按**自身清单**去重，不重复下载
- **切换模式**（2026-09-14 新增，存 `switchMode`，默认「最新」）：最新 / 循环 / 随机
  - ⚠️ **本条推翻 2026-09-02「无自动模式」旧拍板**（老大 2026-09-14 重新提出）
  - **最新**：取图库最新一张
  - **循环**：**从旧到新**推进，到最新一张后**回卷**到最旧；与手动翻页按钮方向一致
  - **随机**：排除「当前正显示的那张」——否则可能抽到同一张、视觉上像没换
  - 手动的「设为最新」「随机一张」与自动模式共用同一套选图逻辑（`pickImage` / `randomImage`）
- **自动切换间隔**（2026-09-14 新增，存 `switchInterval`，默认「手动」）：
  手动 / 30 分钟 / 1 小时 / 4 小时 / 8 小时 / 12 小时 / 24 小时；**rawValue 直接是秒数**，
  判定即 `now - lastSwitch >= rawValue` 一句话，加档位只改 enum
  - ⚠️ 挂在**同一个 60 秒轮询**上（`runAutoSwitchIfNeeded`），**绝不另起 Timer**——理由同"每天定时"
  - 计时基准 `lastSwitch` 持久化；手动切图 / 改模式改间隔 / 每次自动切换后刷新（`resetSwitchTimer`）
  - **手动模式下不自动切换**，但每天定点检查后仍按模式应用一张（即升级前的旧行为，
    故默认「手动 + 最新」时行为与旧版完全一致）
  - 睡眠期间不切换，唤醒后若已超间隔**只补切一次**（比较的是时间差，天然如此）
  - 「目标 == 当前壁纸」时跳过设置调用，但**计时照常推进**（否则会每分钟重复尝试无意义设置）
  - 菜单显示「下次切换 HH:mm」倒计时（`nextSwitchAt`）。用**绝对时刻**、跨天带日期——
    相对时间（「还有 N 分钟」）在菜单久开时会变成过期数据
  - ⚠️ **「最新」+ 短间隔是矛盾的**：Bing 一天只出一张新图，故「30 分钟 + 最新」实际一天只变一次。
    短间隔只有配**循环 / 随机**才有意义
- **更新时间**（2026-09-03 老大拍板，已**移除**早期的「按间隔」二选一）：
  只有「每天定时」一种，存 `dailyTime`（默认 08:00）。「自定义时间…」弹窗输入时
  **自动补冒号**（输 `0830` 实时变 `08:30`，不必手输 `:`；只输 1-2 位数字按整点处理），
  保存最近 3 个使用过的时段（存 `recentTimes`）作快捷选择。
  ⚠️ **定时实现是「每分钟轮询 + `lastDailyCheck` 日期标记」，不是一次性定时器**
  （2026-09-08 改，见"已知的坑"）：到点后当天只跑一次，错过/被挂起也能在下分钟补跑
- **检查触发点**：① 每天过 `dailyTime` 后的**定点检查**（轮询判断，当天只跑一次）；
  ② `App 冷启动`（`init` 里的 `refresh()`）；③ `电脑唤醒`（`didWakeNotification`）。
  ②③ 是兜底，**不写 `lastDailyCheck`**——否则早上冷启动跑过就占掉当天的定点机会。
  按清单去重，重复触发不重复下载。
  **`refresh(apply:)` 参数**（2026-09-14）：以上三处 + 菜单「立即检查更新」都走同一入口，
  但菜单那处传 `apply: false`——只拉新图入库，**不**顺手顶掉当前壁纸
- 壁纸填充方式（存 `scalingMode`，默认充满屏幕）：充满屏幕 / 适合于屏幕 /
  拉伸以充满屏幕 / 居中，映射 `NSImageScaling`，选择后立即对当前壁纸重应用
  （重应用的是**同一张图**，故 `setWallpaper(resetTimer: false)`，不重置自动切换计时）
- 手动切换：菜单顶部预览图**两侧圆形按钮** = 上一张 / 下一张（从系统当前壁纸反查索引，无状态）。
  ⚠️ 手动翻页到边界**夹紧**（不回卷），自动循环才回卷——两者共用 `adjacent(_:wrap:)`，靠 `wrap` 开关区分
- 菜单顶部显示当前桌面壁纸预览图（`.window` 样式 + ImageIO 缩略图，maxPixel 560）
- **菜单按功能分 4 组**（2026-09-14）：**切换壁纸** / **显示** / **下载与更新** / **通用**，
  组间 `Divider()` + `SectionHeader` 小标题（11px 次级灰字，不可点）
- **子菜单行（切换模式 / 自动切换 / 壁纸填充 / 更新时间）**：SwiftUI 外观 + `AnchorReader` 锚点定位 +
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
- **推送的坑（2026-09-14 更新，方向反转过了）**：
  ① git 通道**只认 Basic**（`x-access-token` + PAT），用 Bearer 头报 `invalid credentials`；
  ② **代理方向会反转，必须现判**——09-04 是「必须绕过代理」，09-14 实测**直连被拦、必须走代理**，
  且代理端口每次会话都可能变（09-04 见 59218，09-14 见 56231）。**别照抄旧结论、别写死端口**。
  裸 `git push` 已不可用，改用 `docs/git-and-remote.md` 里的自适应覆盖命令
  （从 `env` 现取代理端口 + `git -c ...push`）。代理会间歇 502，重试一两次即可。
  重建步骤与备用方案 → **`docs/git-and-remote.md`**

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
- **抓取主机一律用 `cn.bing.com`，别用 `www.bing.com`**（2026-09-05 实测）：国内直连
  `www.bing.com` 会被断流（SSL_ERROR_SYSCALL，接口 + `/th?id=` 图片 CDN 一起挂），
  `cn.bing.com` 稳定且数据与 www 完全一致（startdate / 图片 ID 相同，不影响去重键）。
  源码 `candidates()` 两处 URL 均已走 cn，勿改回 www。
- **Bing 当天图发布晚于早上**（2026-09-05 / 09-06 / 09-08 三次观察一致）：zh-CN 接口在早上
  查到的最新 `startdate` 常仍是**前一天**（09-08 早上查到的是 09-07 的图）。
  后果：**设 09:30 定点也必然慢一天**，「一早看到当天新图」靠调时刻解决不了。
  另：`backfill.py` 目前仍写 `www.bing.com`（与上方铁律不符，属已知待改项）——
  要续传回填前先改成 cn，否则会重演 2026-09-05 的整轮断流。

## 已知的坑（都踩过，别再踩）

- **别信壁纸 `Index.plist` 的 `LastSet` 字段**：那是「系统设置」App 的记账字段，
  不走 NSWorkspace 更新。设完壁纸后它仍显示旧日期，极易误判为"没生效"。
  验证壁纸请写 Swift 探针读 `NSWorkspace.shared.desktopImageURL(for:)`
  —— 已固化为 `./verify-wallpaper.sh`（2026-09-14），直接用，不必每次重写。
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
- **GUI / AppKit 通用坑（自建 modal 输入三连、菜单栏菜单样式、图标 sips、原地签名坏 seal）**
  → 已迁 **`docs/appkit-pitfalls.md`**，动 GUI 前读它，本文档不重复展开
- **菜单栏 App 的一次性内存 Timer 会被 App Nap 无限期拖住**（9-04/9-05/9-06 三天"定时没触发"
  的共同病灶，2026-09-06 定性）：LSUIElement App 长期无窗口不活跃，系统对其 App Nap
  ——进程暂停、runloop 停摆，`Timer.scheduledTimer` 到期也不触发，直到用户交互唤醒。
  **现象最迷惑的一次**：App 活着、机器醒着（pmset 证实没睡）、网络通、有新图，09:30 却什么都没发生。
  解：进程存活期间持有一个 activity token 防 nap——
  `napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: ...)`
  （允许系统空闲睡眠，只防 App Nap，不破坏节能）。见 `WallpaperManager.napActivity`。
  ⚠️ **但豁免并不够**（2026-09-08 实测：加了 beginActivity，09:30 仍漏更）。
  **根本解法是别用一次性 Timer**：一次性 Timer 错过那个瞬间就永久错过，没有任何自愈机制。
  已改为**每分钟轮询 + `lastDailyCheck` 日期标记**（`setupTimer` / `runDailyCheckIfNeeded`）：
  只要进程活过任意一分钟就会补跑，天然自愈，且每天只跑一次。
  **以后别再改回"一次性 Timer + 重排下一天"的写法。**
  ⚠️ 2026-09-14 起**自动切换间隔**（`runAutoSwitchIfNeeded`）也挂在**同一个** 60 秒轮询上。
  8/12/24 小时这类长间隔尤其不许另起 Timer——那等于把上面这个坑重挖一遍。
- **腾讯柠檬清理会删 `~/Library/Application Support/BingWallpaper/`**（2026-09-05 20:36 实测，
  目录被整个清掉）：App 不重启时内存清单仍在、表现正常；一旦重启，init 重建空目录 + 清单归零。
  且 `saveManifest()` 原实现只 write 不 createDirectory → 目录被删后清单**再也写不回**（静默失败）。
  已修：saveManifest 写前先 `createDirectory(withIntermediateDirectories:)`。
  仍要提醒老大把该目录加进柠檬清理白名单，否则每次清理复发。
  附带防线：`download()` 先查目标文件是否存在（存在即跳过+记清单），故清单归零重启也不会重下历史图。

## 未决（未排期）

- 菜单栏图标是否换成 logo —— **老大 2026-09-04 决定：暂时保持现状**（继续用
  SF Symbol `photo`）。真要换，触发条件仍是提供纯黑单色剪影版素材
  （全彩 logo 缩到 18px 会糊；macOS 菜单栏图标惯例走单色模板模式）
- **`dailyTime` 是否从 09:30 挪到下午**（2026-09-08 提出，未排期）：因 Bing 当天图晚发
  （见"实测技术事实"），09:30 定点抓到的必然是前一天的图。备选：① 挪到 14:00（Bing 早发完）；
  ② 保留 09:30，若当次没抓到当天图则下午再补一次。
  **触发条件**：老大确认"慢一天"不可接受。在此之前保持现状。
- **把 `~/Library/Application Support/BingWallpaper/` 加进腾讯柠檬清理白名单**（2026-09-06 提出，
  **老大尚未确认已加**）：`LemonMonitor` 仍在运行，清单目录有被再次清掉的风险。
- 壁纸填充第五种「拼贴」—— **未排期**。公开 API 不支持（见"已知的坑"），
  可行方案是预合成拼贴大图 + 充满屏幕应用，会破坏上一张/下一张导航。
  **实际意义也存疑**：我们的图本身就是 4K，4K 屏上拼贴 = 一张刚好铺满（≈ 居中），
  小屏则只显示左上角局部，两种情况下平铺效果都看不出来。
  触发条件：老大确认真的需要（比如将来要铺低分辨率小图）。
