import SwiftUI
import AppKit
import ImageIO

// MARK: - 路径

let DEFAULT_PICS_DIR = URL(fileURLWithPath: "/Users/pxdog/Pictures/bing-wallpaper", isDirectory: true)
let SUPPORT_DIR      = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/BingWallpaper", isDirectory: true)
let AGENT_PLIST      = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/com.pxdog.bingwallpaper.plist")

// MARK: - 模型

/// 壁纸填充方式（映射 NSImageScaling；「拼贴」无公开 API，未纳入，见 CLAUDE.md）
enum ScalingMode: String, CaseIterable {
    case fill    = "充满屏幕"
    case fit     = "适合于屏幕"
    case stretch = "拉伸以充满屏幕"
    case center  = "居中"

    var scaling: NSImageScaling {
        switch self {
        case .fill:    return .scaleProportionallyUpOrDown
        case .fit:     return .scaleProportionallyDown
        case .stretch: return .scaleAxesIndependently
        case .center:  return .scaleNone
        }
    }
}

/// 切换模式：决定「该换哪一张」
enum SwitchMode: String, CaseIterable {
    case newest = "最新"
    case cycle  = "循环"
    case random = "随机"
}

/// 自动切换间隔。rawValue 直接是秒数，判定即 `now - lastSwitch >= rawValue`，
/// 加档位只改这里。manual = 0 表示不自动切换（每天定点检查仍会换一张，即旧行为）。
enum SwitchInterval: Int, CaseIterable {
    case manual = 0
    case min30  = 1800
    case hour1  = 3600
    case hour4  = 14400
    case hour8  = 28800
    case hour12 = 43200
    case hour24 = 86400

    var label: String {
        switch self {
        case .manual: return "手动"
        case .min30:  return "30 分钟"
        case .hour1:  return "1 小时"
        case .hour4:  return "4 小时"
        case .hour8:  return "8 小时"
        case .hour12: return "12 小时"
        case .hour24: return "24 小时"
        }
    }
}

struct BingImage {
    let date: String
    let name: String
    let id:   String
    let url:  URL
}

/// 去掉 _UHD.jpg 与市场后缀（_ZH-CN123456），保留原始大小写 → OHR.SamarkandCeiling
func stripMarket(_ s: String) -> String {
    var s = s
    for p in ["_UHD\\.jpg$", "_[A-Za-z]{2}-[A-Za-z]{2}\\d+$"] {
        if let r = s.range(of: p, options: .regularExpression) { s = String(s[s.startIndex..<r.lowerBound]) }
    }
    return s
}

/// 20260830 → 2026-08-30
func dashDate(_ s: String) -> String {
    guard s.count == 8 else { return s }
    let a = Array(s)
    return "\(String(a[0..<4]))-\(String(a[4..<6]))-\(String(a[6..<8]))"
}

// MARK: - 管理器

@MainActor
final class WallpaperManager: ObservableObject {

    @Published var status  = "就绪"
    @Published var current = "—"
    @Published var currentURL: URL?

    /// 每天定时的时刻（24h 制 HH:mm），默认 08:00
    @Published var dailyTime: String {
        didSet {
            UserDefaults.standard.set(dailyTime, forKey: "dailyTime")
            setupTimer()
        }
    }
    /// 近期使用过的定时时刻（最多 3 个，新的在前），作快捷选择
    @Published var recentTimes: [String] {
        didSet { UserDefaults.standard.set(recentTimes, forKey: "recentTimes") }
    }
    /// 壁纸填充方式，持久化；改变后由菜单显式重应用
    @Published var scalingMode: ScalingMode {
        didSet { UserDefaults.standard.set(scalingMode.rawValue, forKey: "scalingMode") }
    }
    /// 切换模式（最新 / 循环 / 随机）；改动只重置计时基准，不立即切换
    @Published var switchMode: SwitchMode {
        didSet {
            UserDefaults.standard.set(switchMode.rawValue, forKey: "switchMode")
            resetSwitchTimer()
        }
    }
    /// 自动切换间隔；改动只重置计时基准，不立即切换
    @Published var switchInterval: SwitchInterval {
        didSet {
            UserDefaults.standard.set(switchInterval.rawValue, forKey: "switchInterval")
            resetSwitchTimer()
        }
    }
    /// 下次自动切换时刻，仅供菜单显示倒计时。由 lastSwitch + switchInterval 算出，不持久化。
    /// 用绝对时刻而非「还有 N 分钟」：菜单久开时相对时间会变成过期数据。
    @Published var nextSwitchAt: Date?
    private var timer: Timer?
    private var wakeToken: NSObjectProtocol?
    /// App Nap 豁免：菜单栏 App 长期不活跃会被系统 App Nap 暂停，一次性 Timer 可能被无限期拖住
    ///（9-04/9-05/9-06 三天"定时没触发"的共同病灶）。beginActivity 防 nap 但不阻止系统睡眠。
    private var napActivity: NSObjectProtocol?

    /// 下载目录：可手动指定，默认 DEFAULT_PICS_DIR，选择后持久化到 UserDefaults
    @Published var picsDir: URL {
        didSet {
            UserDefaults.standard.set(picsDir.path, forKey: "picsDir")
            try? FileManager.default.createDirectory(at: picsDir, withIntermediateDirectories: true)
        }
    }

    /// 开机启动：以 LaunchAgent plist 是否存在为唯一状态来源，默认关闭
    @Published var autostart: Bool {
        didSet { setAutostart(autostart) }
    }

    private var manifest = Set<String>()
    private var manifestFile: URL { SUPPORT_DIR.appendingPathComponent("downloaded.json") }

    init() {
        autostart = FileManager.default.fileExists(atPath: AGENT_PLIST.path)   // init 内不触发 didSet
        dailyTime     = UserDefaults.standard.string(forKey: "dailyTime") ?? "08:00"
        recentTimes   = UserDefaults.standard.stringArray(forKey: "recentTimes") ?? ["08:00"]
        scalingMode   = ScalingMode(rawValue: UserDefaults.standard.string(forKey: "scalingMode") ?? "") ?? .fill
        switchMode    = SwitchMode(rawValue: UserDefaults.standard.string(forKey: "switchMode") ?? "") ?? .newest
        // integer(forKey:) 对未存的键返回 0，正好等于 .manual，默认值天然正确
        switchInterval = SwitchInterval(rawValue: UserDefaults.standard.integer(forKey: "switchInterval")) ?? .manual
        let savedDir = UserDefaults.standard.string(forKey: "picsDir") ?? ""
        picsDir = savedDir.isEmpty ? DEFAULT_PICS_DIR : URL(fileURLWithPath: savedDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: picsDir,     withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: SUPPORT_DIR, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: manifestFile),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [String] { manifest = Set(arr) }
        refreshCurrentName()
        setupTimer()
        registerWakeObserver()
        // 阻止 App Nap：进程存活期间持续有效，保证每日定时与自动切换的轮询准时触发
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "壁纸定时检查与自动切换需准时触发"
        )
        updateNextSwitch()   // 重启后按持久化的 lastSwitch 复原倒计时
        Task { @MainActor in await self.refresh() }
    }

    /// 每天定时：**每分钟轮询 + 日期标记**，不用一次性长定时器。
    /// 一次性 Timer 一旦错过那个瞬间就永久错过（9-04/9-06/9-08 三天漏更的共同根因，
    /// 且 App Nap 豁免也兜不住）；轮询只要进程活过任意一分钟就会补跑，天然自愈。
    /// 每天只跑一次靠 lastDailyCheck 标记；修改 dailyTime 后下一分钟自动按新时刻判断。
    private func setupTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runDailyCheckIfNeeded()
                self?.runAutoSwitchIfNeeded()
            }
        }
    }

    /// 到点自动切换：**与「每天定点检查」共用同一个 60 秒轮询，不另起 Timer**。
    /// 8/12/24 小时这类长间隔若用一次性 Timer，会重演 9-04~9-08 的漏更问题
    /// （错过那个瞬间即永久错过，App Nap 豁免也兜不住）。
    /// 睡眠期间不切换，唤醒后若已超间隔则补切一次——比较的是时间差，天然只补一次。
    private func runAutoSwitchIfNeeded() {
        guard switchInterval != .manual else { return }
        let base = lastSwitch ?? Date()
        guard Date().timeIntervalSince(base) >= Double(switchInterval.rawValue) else { return }
        applyByMode()
    }

    /// 自动切换的计时基准：手动切图 / 改模式改间隔 / 每次自动切换后刷新。
    /// 用 UserDefaults 持久化，App 重启后不丢进度。
    private var lastSwitch: Date? {
        get { UserDefaults.standard.object(forKey: "lastSwitch") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastSwitch") }
    }

    /// 把计时基准拨到现在并刷新倒计时；**不触发立即切换**（避免改设置时画面跳变）
    private func resetSwitchTimer() {
        lastSwitch = Date()
        updateNextSwitch()
    }

    /// 由 lastSwitch + switchInterval 算出下次切换时刻（手动模式 → nil，菜单不显示倒计时）
    private func updateNextSwitch() {
        guard switchInterval != .manual, let base = lastSwitch else { nextSwitchAt = nil; return }
        nextSwitchAt = base.addingTimeInterval(Double(switchInterval.rawValue))
    }

    /// 倒计时文案；跨天时带日期，避免「12:34」被误读成今天
    var nextSwitchText: String? {
        guard let d = nextSwitchAt else { return nil }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MM-dd HH:mm"
        return "下次切换 " + f.string(from: d)
    }

    /// 已过今天的设定时刻、且今天的定点检查还没跑过 → 跑一次
    private func runDailyCheckIfNeeded() {
        guard isPastDailyTime else { return }
        if let d = lastDailyCheck, Calendar.current.isDate(d, inSameDayAs: Date()) { return }
        lastDailyCheck = Date()
        Task { @MainActor in await refresh() }
    }

    private var isPastDailyTime: Bool { todayFireDate() <= Date() }

    /// 今天的 dailyTime 时刻
    private func todayFireDate() -> Date {
        let p = dailyTime.split(separator: ":").compactMap { Int($0) }
        let h = p.count > 0 ? min(max(p[0], 0), 23) : 8
        let m = p.count > 1 ? min(max(p[1], 0), 59) : 0
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = h
        c.minute = m
        return Calendar.current.date(from: c) ?? Date()
    }

    /// 已完成「定点检查」的日期。冷启动 / 唤醒那两次**不写这里**，
    /// 否则早上冷启动跑过一次就把当天的定点机会占掉了（定点可能才有新图）。
    private var lastDailyCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastDailyCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastDailyCheck") }
    }

    /// 电脑从睡眠唤醒时自动检查一次：让"醒来立刻看到新图"，不必等下一分钟轮询。
    /// refresh 按清单去重，重复唤醒不会重复下载；定时器已是每分钟轮询，无需在此重排。
    private func registerWakeObserver() {
        wakeToken = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// 规范化 "H:mm" → "HH:mm"；非法返回 nil
    static func normalizeTime(_ s: String) -> String? {
        let raw = s.trimmingCharacters(in: .whitespaces)
        var h: Int?, m = 0
        if raw.contains(":") {
            let p = raw.split(separator: ":")
            guard p.count == 2, let hh = Int(p[0]), let mm = Int(p[1]) else { return nil }
            h = hh; m = mm
        } else {
            // 容错：用户没输入冒号（如粘贴 0830、或只输小时 8）
            let digits = raw.filter { $0.isNumber }
            switch digits.count {
            case 1, 2: h = Int(digits)
            case 3:     h = Int(String(digits.prefix(1))); m = Int(String(digits.suffix(2))) ?? 0
            case 4:     h = Int(String(digits.prefix(2))); m = Int(String(digits.suffix(2))) ?? 0
            default:    return nil
            }
        }
        guard let hh = h, (0...23).contains(hh), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", hh, m)
    }

    /// 设每天定时时刻；同时记入近期使用（去重、最新在前、最多 3 个）
    func setDailyTime(_ t: String) {
        dailyTime = t
        recentTimes = ([t] + recentTimes.filter { $0 != t }).prefix(3).map { $0 }
        status = "更新时间：每天 \(t)"
    }

    /// 版本信息，全部从 Info.plist 读取，避免代码里硬编码第二份
    var versionText: String {
        let d = Bundle.main.infoDictionary ?? [:]
        let short = d["CFBundleShortVersionString"] as? String ?? "?"
        let build = d["CFBundleVersion"] as? String ?? "?"
        return "\(short)（Build \(build)）"
    }

    /// 【关于】面板：与自定义时间面板同一套路（自建窗口），放 App 图标
    func showAbout() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "关于 Bing Wallpaper"
        win.isReleasedWhenClosed = false

        let view = win.contentView!

        // App 图标（从 bundle 的 AppIcon 读取），整窗居中
        let iconView = NSImageView(frame: NSRect(x: 138, y: 138, width: 64, height: 64))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(iconView)

        let title = NSTextField(labelWithString: "Bing Wallpaper")
        title.frame = NSRect(x: 20, y: 116, width: 300, height: 20)
        title.font = .boldSystemFont(ofSize: 15)
        title.alignment = .center
        view.addSubview(title)

        let ver = NSTextField(labelWithString: "版本 \(versionText)（测试版）")
        ver.frame = NSRect(x: 20, y: 96, width: 300, height: 16)
        ver.font = .systemFont(ofSize: 12)
        ver.textColor = .secondaryLabelColor
        ver.alignment = .center
        view.addSubview(ver)

        let desc = NSTextField(labelWithString: "必应Bing壁纸每日自动更新")
        desc.frame = NSRect(x: 20, y: 76, width: 300, height: 16)
        desc.font = .systemFont(ofSize: 12)
        desc.alignment = .center
        view.addSubview(desc)

        let detail = NSTextField(labelWithString: "原生 Swift / SwiftUI，无第三方依赖")
        detail.frame = NSRect(x: 20, y: 52, width: 300, height: 16)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        view.addSubview(detail)

        let bridge = AboutBridge(win: win, version: "Bing Wallpaper \(versionText)")

        // 复制 / 好 两个按钮整体居中（110 + 12 + 76 = 198，起点 (340-198)/2 = 71）
        let copy = NSButton(frame: NSRect(x: 71, y: 16, width: 110, height: 28))
        copy.title = "复制版本信息"; copy.bezelStyle = .push
        copy.target = bridge; copy.action = #selector(AboutBridge.copyVersion(_:))
        view.addSubview(copy)

        let ok = NSButton(frame: NSRect(x: 193, y: 16, width: 76, height: 28))
        ok.title = "好"; ok.bezelStyle = .push; ok.keyEquivalent = "\r"
        ok.target = bridge; ok.action = #selector(AboutBridge.close(_:))
        view.addSubview(ok)
        win.delegate = bridge

        win.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: win)
    }

    /// 弹窗输入每天定时的时分（HH:mm）。
    /// 不用 NSAlert：它强制在最左侧显示 App 图标，且设 icon = nil 无效（会退回默认图标）。
    func askCustomTime() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 156),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "自定义更新时间"
        win.isReleasedWhenClosed = false

        let view = win.contentView!

        let title = NSTextField(labelWithString: "自定义更新时间")
        title.frame = NSRect(x: 20, y: 116, width: 280, height: 20)
        title.font = .boldSystemFont(ofSize: 13)
        title.alignment = .center
        view.addSubview(title)

        let hint = NSTextField(labelWithString: "24 小时制，自动补冒号（例如 0830 → 08:30）")
        hint.frame = NSRect(x: 20, y: 92, width: 280, height: 16)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        view.addSubview(hint)

        // 输入框宽度刚好容纳 5 个字符（HH:mm）。
        // macOS 26 起 NSTextField 传统 bezel/焦点环在小尺寸下渲染损坏（边框被裁一半），
        // 故关闭系统 bezel，用 layer 自绘边框，聚焦时由 delegate 切换为强调色。
        let input = CenteredTextField(frame: NSRect(x: 128, y: 54, width: 64, height: 24))
        input.cell = CenteredTextFieldCell()   // 强制文字垂直居中（macOS 26 无 bezel 偏上 workaround）
        input.isBordered = false
        input.isBezeled = false
        input.drawsBackground = true
        input.backgroundColor = .controlBackgroundColor
        input.focusRingType = .none
        input.wantsLayer = true
        input.layer?.cornerRadius = 6
        input.layer?.borderWidth = 1
        input.layer?.borderColor = NSColor.separatorColor.cgColor
        input.font = .systemFont(ofSize: 13)
        input.usesSingleLineMode = true   // 单行 → 文字垂直居中
        input.alignment = .center         // 时间值水平居中
        input.isEditable = true            // 显式开编辑（menu bar 为 accessory，弹窗非 key 时易失效）
        input.isSelectable = true
        input.stringValue = dailyTime
        input.placeholderString = "08:30"
        view.addSubview(input)

        let bridge = TimeInputBridge(win: win, input: input) { [weak self] v in
            guard let t = Self.normalizeTime(v) else {
                self?.status = "时间格式无效：\(v)（须 HH:mm）"
                return
            }
            self?.setDailyTime(t)
        }
        win.delegate = bridge
        input.delegate = bridge   // 聚焦切换边框颜色

        let cancel = NSButton(frame: NSRect(x: 78, y: 16, width: 76, height: 28))
        cancel.title = "取消"; cancel.bezelStyle = .push; cancel.keyEquivalent = "\u{1b}"
        cancel.target = bridge; cancel.action = #selector(TimeInputBridge.cancel(_:))
        view.addSubview(cancel)

        let ok = NSButton(frame: NSRect(x: 166, y: 16, width: 76, height: 28))
        ok.title = "确定"; ok.bezelStyle = .push; ok.keyEquivalent = "\r"
        ok.target = bridge; ok.action = #selector(TimeInputBridge.ok(_:))
        view.addSubview(ok)

        win.center()
        // 菜单栏 App（LSUIElement）默认是 accessory，窗口在非激活态无法成为 key window，
        // 导致 NSTextField 拿不到键盘焦点、无法编辑（按钮照常可点）。
        // 临时升到 .regular 让弹窗真正成为 key window；LSUIElement 保证 Dock 不露图标；
        // modal 结束后还原 .accessory，菜单栏不受影响。
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(input)
        NSApp.runModal(for: win)                  // bridge 在本作用域存活至 modal 结束
        if wasAccessory { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: 抓取与下载

    /// 接口 idx 被服务端钳在 8、n 钳在 8，故取 0 与 8 两段 = 最近约 16 天
    private func candidates() async -> [BingImage] {
        var out: [BingImage] = []
        for idx in [0, 8] {
            // 主机走 cn.bing.com：国内直连 www.bing.com 会被断流（2026-09-05 实测），
            // cn 与 www 的接口/图片数据一致，不会影响去重键
            guard let u = URL(string: "https://cn.bing.com/HPImageArchive.aspx?format=js&idx=\(idx)&n=8&mkt=zh-CN"),
                  let (data, _) = try? await URLSession.shared.data(from: u),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = obj["images"] as? [[String: Any]] else { continue }
            for im in images {
                guard let sd  = im["startdate"] as? String,
                      let ub  = im["urlbase"] as? String,
                      let raw = ub.components(separatedBy: "id=").last,
                      let url = URL(string: "https://cn.bing.com/th?id=\(raw)_UHD.jpg") else { continue }
                let name = stripMarket(raw)
                out.append(BingImage(date: dashDate(sd), name: name, id: name.uppercased(), url: url))
            }
        }
        return out
    }

    private func download(_ img: BingImage) async -> Bool {
        let dst = picsDir.appendingPathComponent("\(img.date)_\(img.name).jpg")
        if FileManager.default.fileExists(atPath: dst.path) { return true }
        guard let (tmp, resp) = try? await URLSession.shared.download(from: img.url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let data = try? Data(contentsOf: tmp),
              data.count > 50_000,
              data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) else { return false }
        do { try data.write(to: dst) } catch { return false }
        return true
    }

    private func saveManifest() {
        guard let d = try? JSONSerialization.data(withJSONObject: Array(manifest).sorted()) else { return }
        // 目录可能被清理工具（如腾讯柠檬清理 2026-09-05 实测）删掉，先确保存在再写，否则静默失败
        try? FileManager.default.createDirectory(at: SUPPORT_DIR, withIntermediateDirectories: true)
        try? d.write(to: manifestFile)
    }

    /// 抓取 + 按清单去重下载。
    /// apply = 是否顺带按模式换壁纸：定点检查 / 冷启动 / 唤醒为 true（保持旧行为），
    /// 菜单「立即检查更新」传 false——用户点它可能只想刷新列表，不该顺手顶掉当前壁纸。
    func refresh(apply: Bool = true) async {
        status = "检查新壁纸…"
        let cands = await candidates()
        guard !cands.isEmpty else { status = "接口无返回"; return }
        var added = 0
        for c in cands where !manifest.contains(c.id) {
            if await download(c) { manifest.insert(c.id); added += 1 }
        }
        saveManifest()
        let note = added > 0 ? "（新增 \(added) 张）" : "（无新图）"
        guard apply else { status = "已检查" + note; return }
        applyByMode(note: note)
    }

    // MARK: 图片列表

    func listImages() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: picsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "jpg" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func newestImage() -> URL? { listImages().last }

    /// 随机一张：排除「当前正显示的那张」，否则可能抽到同一张、视觉上像没换。
    /// 手动的「随机一张」与自动的随机模式共用此入口。
    func randomImage() -> URL? {
        let imgs = listImages()
        guard !imgs.isEmpty else { return nil }
        guard imgs.count > 1 else { return imgs[0] }
        let cur = currentWallpaperURL()
        let pool = imgs.filter { $0.standardizedFileURL != cur?.standardizedFileURL }
        return (pool.isEmpty ? imgs : pool).randomElement()
    }

    /// 相对当前壁纸偏移 delta 张。从系统当前壁纸**反查索引**，不存游标——
    /// App 重启 / 用户在系统设置里换图 / 库目录增删文件都不会错乱。
    /// wrap=false 到边界夹紧（手动翻页）；wrap=true 回卷（自动循环）。
    private func adjacent(_ delta: Int, wrap: Bool) -> URL? {
        let imgs = listImages()
        guard !imgs.isEmpty else { return nil }
        guard let cur = currentWallpaperURL(),
              let i = imgs.firstIndex(where: { $0.standardizedFileURL == cur.standardizedFileURL })
        else { return delta > 0 ? imgs[0] : imgs[imgs.count - 1] }   // 不在库内 → 从头 / 从尾开始
        if wrap { return imgs[(i + delta + imgs.count) % imgs.count] }
        return imgs[min(max(i + delta, 0), imgs.count - 1)]
    }

    /// 循环下一张：从旧到新推进，到最新一张后回卷到最旧
    private func cycleNext() -> URL? { adjacent(1, wrap: true) }

    /// 系统当前桌面壁纸（主屏）
    private func currentWallpaperURL() -> URL? {
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: s)
    }

    // MARK: 应用壁纸

    /// 按当前模式取一张应用。每天定点检查后与自动切换到点共用此入口。
    func applyByMode(note: String = "") {
        guard let u = pickImage() else { status = "库内无图片" + note; return }
        // 目标与当前相同（如「最新」模式下库内没有新图）→ 跳过设置调用，但计时照常推进，
        // 否则每隔一分钟都会重复尝试同一个无意义的设置
        if let cur = currentWallpaperURL(), cur.standardizedFileURL == u.standardizedFileURL {
            resetSwitchTimer()
            status = "已是\(switchMode.rawValue)壁纸" + note
            return
        }
        setWallpaper(u, note: note)
    }

    private func pickImage() -> URL? {
        switch switchMode {
        case .newest: return newestImage()
        case .cycle:  return cycleNext()
        case .random: return randomImage()
        }
    }

    /// resetTimer = false 用于「填充方式变更后重应用当前图」——图没变，不该重置自动切换计时
    func setWallpaper(_ url: URL, note: String = "", resetTimer: Bool = true) {
        let ws = NSWorkspace.shared
        var screens = NSScreen.screens
        var tries = 0
        while screens.isEmpty && tries < 20 {
            Thread.sleep(forTimeInterval: 0.5)
            screens = NSScreen.screens
            tries += 1
        }
        guard !screens.isEmpty else { status = "未取到屏幕"; return }
        // ⚠️ 此 SDK 未把 NSWorkspaceDesktopImageScalingKey 等常量导入为 .scaling 等成员，
        //    只能用 C 原始字符串构造（实测 rawValue init 可用）
        let scalingKey  = NSWorkspace.DesktopImageOptionKey(rawValue: "NSWorkspaceDesktopImageScalingKey")
        let clippingKey = NSWorkspace.DesktopImageOptionKey(rawValue: "NSWorkspaceDesktopImageAllowClippingKey")
        var opts: [NSWorkspace.DesktopImageOptionKey: Any] = [scalingKey: scalingMode.scaling.rawValue]
        if scalingMode == .fill { opts[clippingKey] = true }
        for s in screens { try? ws.setDesktopImageURL(url, for: s, options: opts) }
        current    = url.lastPathComponent
        currentURL = url
        status  = "已设为 " + url.lastPathComponent + note
        if resetTimer { resetSwitchTimer() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let ok = NSScreen.screens.allSatisfy { ws.desktopImageURL(for: $0) == url }
            if !ok { self.status = "设置可能未生效：" + url.lastPathComponent }
        }
    }

    /// 上一张 / 下一张：手动翻页，到边界**夹紧**（不回卷，与自动循环的回卷语义区分开）
    func step(_ delta: Int) {
        guard let u = adjacent(delta, wrap: false) else { status = "库内无图片"; return }
        setWallpaper(u)
    }

    func openFolder() { NSWorkspace.shared.open(picsDir) }

    /// 手动指定下载目录
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt               = "选择"
        panel.message              = "选择壁纸保存目录"
        panel.directoryURL         = picsDir
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement App 需主动激活，否则面板不前置
        guard panel.runModal() == .OK, let u = panel.url else { return }
        picsDir = u
        status  = "目录已切换"
    }

    // MARK: 开机启动

    /// App 运行在 GUI 会话内，由它调 launchctl 才有写权限（外部 shell 调会 EIO 失败）
    private func setAutostart(_ on: Bool) {
        let uid = getuid()
        if on {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.pxdog.bingwallpaper</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/Applications/BingWallpaper.app/Contents/MacOS/BingWallpaper</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>LimitLoadToSessionType</key>
                <string>Aqua</string>
            </dict>
            </plist>
            """
            try? plist.write(to: AGENT_PLIST, atomically: true, encoding: .utf8)
            _ = run("/bin/launchctl", "bootstrap", "gui/\(uid)", AGENT_PLIST.path)
            status = FileManager.default.fileExists(atPath: AGENT_PLIST.path) ? "已开启开机启动" : "开机启动开启失败"
        } else {
            _ = run("/bin/launchctl", "bootout", "gui/\(uid)/com.pxdog.bingwallpaper")
            try? FileManager.default.removeItem(at: AGENT_PLIST)
            status = FileManager.default.fileExists(atPath: AGENT_PLIST.path) ? "开机启动关闭失败" : "已关闭开机启动"
        }
    }

    @discardableResult
    private func run(_ path: String, _ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func refreshCurrentName() {
        guard let s = NSScreen.main ?? NSScreen.screens.first,
              let u = NSWorkspace.shared.desktopImageURL(for: s) else { return }
        current    = u.lastPathComponent
        currentURL = u
    }
}

/// 关于面板的按钮/关闭事件桥接
private final class AboutBridge: NSObject, NSWindowDelegate {
    let win: NSWindow
    let version: String
    init(win: NSWindow, version: String) { self.win = win; self.version = version }

    @objc func close(_ sender: Any?) {
        NSApp.stopModal()
        win.orderOut(nil)
    }
    @objc func copyVersion(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(version, forType: .string)
    }
    func windowWillClose(_ notification: Notification) { NSApp.stopModal() }
}

/// 强制文字垂直居中的输入框 cell：macOS 26 下无 bezel 的 NSTextField 单行文字会偏上，
/// 公开 API 无垂直对齐开关，故重写 drawingRect 让文字在控件高度内垂直居中。
private final class CenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var r = super.drawingRect(forBounds: rect)
        let textH = attributedStringValue.size().height
        if textH < rect.height {
            r.origin.y = (rect.height - textH) / 2
            r.size.height = textH
        }
        return r
    }
}

/// 编辑态（field editor 接管绘制）也要垂直居中：`CenteredTextFieldCell.drawingRect`
/// 只解决非编辑态显示，进入编辑后由 NSTextView 负责绘制，需用 `textContainerInset`
/// 顶部补偿上偏移，否则 macOS 26 下输入文字会偏上。
private final class CenteredTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let editor = currentEditor() as? NSTextView {
            let lineH = (editor.font.flatMap { editor.layoutManager?.defaultLineHeight(for: $0) })
                      ?? (self.font?.boundingRectForFont.height ?? bounds.height)
            let inset = max(0, (bounds.height - lineH) / 2)
            editor.textContainerInset = NSSize(width: 0, height: inset)
        }
        return true
    }
}

/// 时间输入面板的按钮/窗口事件桥接（AppKit 的 target-action 要求 NSObject）
private final class TimeInputBridge: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let win: NSWindow
    let input: NSTextField
    let onOK: (String) -> Void

    init(win: NSWindow, input: NSTextField, onOK: @escaping (String) -> Void) {
        self.win = win; self.input = input; self.onOK = onOK
    }

    @objc func ok(_ sender: Any?) {
        close()
        onOK(input.stringValue)
    }
    @objc func cancel(_ sender: Any?) { close() }

    /// 点窗口关闭按钮时也要退出 modal 循环，否则卡死
    func windowWillClose(_ notification: Notification) { NSApp.stopModal() }

    // 聚焦时边框变强调色，失焦恢复分隔线灰（配合 askCustomTime 里的 layer 边框）
    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.object as? NSTextField)?.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        (obj.object as? NSTextField)?.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    // 实时把输入的数字自动格式化为 HH:mm（每两位自动插冒号，无需手输“:”）
    @objc func controlTextDidChange(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        let masked = Self.maskTime(tf.stringValue)
        if masked != tf.stringValue { tf.stringValue = masked }
    }

    /// 纯数字 → HH:mm 掩码：去非数字、最多 4 位、每两位插冒号
    private static func maskTime(_ raw: String) -> String {
        let digits = raw.filter { $0.isNumber }.prefix(4)
        let s = String(digits)
        switch s.count {
        case 0:     return ""
        case 1, 2:  return s               // "8" / "08"（等第 3 位再插冒号）
        case 3:     return "\(s.prefix(2)):\(s.suffix(1))"
        default:    return "\(s.prefix(2)):\(s.suffix(2))"
        }
    }

    private func close() {
        NSApp.stopModal()
        win.orderOut(nil)
    }
}

// MARK: - 菜单（window 样式：顶部可放壁纸预览图）

/// 用 ImageIO 生成小尺寸缩略图，避免整张 4K 解码占内存
func makeThumbnail(_ url: URL, maxPixel: CGFloat) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// 菜单分组小标题：不可点，仅作视觉分类
struct SectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 菜单行：整行可点、悬停高亮，模拟原生菜单观感
struct MenuRow: View {
    let title: String
    let icon: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).frame(width: 14) }
                Text(title)
                Spacer()
            }
            .font(.body)          // 与子菜单行为同一套字型，避免被按钮样式改写
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 预览图两侧的翻页按钮：半透明圆形，悬停加深
struct PreviewNavButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(hovering ? 0.55 : 0.3)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 子菜单行（NSMenu 手工弹出：才能在右侧展开 + 整行可点）

struct ContextItem {
    let title: String
    let checked: Bool
    let action: (() -> Void)?
    let children: [ContextItem]?

    /// 叶子项
    init(_ title: String, checked: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.checked = checked; self.action = action; self.children = nil
    }
    /// 带子菜单的分组项（子菜单也会在右侧级联展开）
    init(_ title: String, children: [ContextItem]) {
        self.title = title; self.checked = false; self.action = nil; self.children = children
    }
}

/// 透明锚点：只为拿到整行在屏幕上的 frame，用来定位 NSMenu 的弹出位置。
/// 外观与点击全部交给 SwiftUI（与 MenuRow 完全同一套构建方式），
/// 避免 NSButton 自带的 image/title 布局破坏图标对齐与字型。
final class AnchorBox: NSObject { weak var view: NSView? }

struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

struct SubmenuRow: View {
    let icon: String
    let title: String
    let items: [ContextItem]

    @State private var hovering = false
    private let anchor = AnchorBox()

    var body: some View {
        Button(action: popUp) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 14)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hovering
                        ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                        : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(AnchorReader(box: anchor))
    }

    /// 在整行**右侧**弹出 NSMenu（SwiftUI 顶层 Menu 只能向下，做不到）
    private func popUp() {
        guard let v = anchor.view, let win = v.window else { return }
        let r = win.convertToScreen(v.convert(v.bounds, to: nil))
        let menu = buildMenu(items)
        menu.popUp(positioning: nil, at: NSPoint(x: r.maxX, y: r.maxY), in: nil)
    }

    /// 递归构建；闭包用 ActionBox 装箱进 representedObject，
    /// 任意层级的项都走同一个 invoke，不依赖 index
    private func buildMenu(_ list: [ContextItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let c = MenuActions.shared
        for it in list {
            let mi = NSMenuItem(title: it.title,
                                action: it.action == nil ? nil : #selector(MenuActions.invoke(_:)),
                                keyEquivalent: "")
            mi.target = it.action == nil ? nil : c
            mi.state = it.checked ? .on : .off
            if let act = it.action { mi.representedObject = ActionBox(act) }
            if let kids = it.children { mi.submenu = buildMenu(kids) }
            menu.addItem(mi)
        }
        return menu
    }
}

/// NSMenuItem 的 action 目标（单例，生命周期与 App 同）
final class MenuActions: NSObject {
    static let shared = MenuActions()
    @objc func invoke(_ sender: NSMenuItem) {
        (sender.representedObject as? ActionBox)?.action()
    }
}


/// 让闭包能塞进 NSMenuItem.representedObject（要求 AnyObject）
final class ActionBox: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

struct MenuContent: View {
    @ObservedObject var mgr: WallpaperManager
    @State private var thumb: NSImage?

    /// 长路径缩写为 ~/...，避免撑宽菜单
    private var dirText: String {
        (mgr.picsDir.path as NSString).abbreviatingWithTildeInPath
    }

    private var updateText: String {
        "更新时间：每天 \(mgr.dailyTime)"
    }

    /// 「更新时间」子菜单：近期使用 / 自定义时间…
    private var updateItems: [ContextItem] {
        var out: [ContextItem] = mgr.recentTimes.map { t in
            ContextItem("每天 \(t)", checked: mgr.dailyTime == t) {
                mgr.setDailyTime(t)
            }
        }
        out.append(ContextItem("自定义时间…") { mgr.askCustomTime() })
        return out
    }

    /// 「切换模式」子菜单：最新 / 循环 / 随机
    private var modeItems: [ContextItem] {
        SwitchMode.allCases.map { m in
            ContextItem(m.rawValue, checked: mgr.switchMode == m) {
                guard mgr.switchMode != m else { return }
                mgr.switchMode = m
            }
        }
    }

    /// 「自动切换」子菜单：手动 / 30 分钟 … 24 小时
    private var intervalItems: [ContextItem] {
        SwitchInterval.allCases.map { i in
            ContextItem(i.label, checked: mgr.switchInterval == i) {
                guard mgr.switchInterval != i else { return }
                mgr.switchInterval = i
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部：当前桌面壁纸预览，两侧叠上一张/下一张
            ZStack {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color(nsColor: .windowBackgroundColor)
                            Image(systemName: "photo").foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 280, height: 158)
                .clipped()

                HStack {
                    PreviewNavButton(systemName: "chevron.left")  { mgr.step(-1) }
                    Spacer()
                    PreviewNavButton(systemName: "chevron.right") { mgr.step(1) }
                }
                .padding(.horizontal, 6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(mgr.current).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(mgr.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text("目录：\(dirText)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // ── 切换壁纸：选哪张、多久换一次、手动换 ──
            SectionHeader("切换壁纸")

            SubmenuRow(icon: "arrow.triangle.2.circlepath",
                       title: "切换模式：\(mgr.switchMode.rawValue)",
                       items: modeItems)
                .frame(width: 280, height: 26)

            SubmenuRow(icon: "timer",
                       title: "自动切换：\(mgr.switchInterval.label)",
                       items: intervalItems)
                .frame(width: 280, height: 26)

            // 倒计时：仅自动模式显示（手动模式 nextSwitchText 为 nil）
            if let t = mgr.nextSwitchText {
                Text(t)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            MenuRow("设为最新", icon: "sparkles") { if let u = mgr.newestImage() { mgr.setWallpaper(u) } }
            MenuRow("随机一张", icon: "shuffle")  { if let u = mgr.randomImage() { mgr.setWallpaper(u) } }

            Divider()

            // ── 显示：填充方式 ──
            SectionHeader("显示")

            SubmenuRow(icon: "aspectratio",
                       title: "壁纸填充：\(mgr.scalingMode.rawValue)",
                       items: ScalingMode.allCases.map { m in
                ContextItem(m.rawValue, checked: mgr.scalingMode == m) {
                    guard mgr.scalingMode != m else { return }
                    mgr.scalingMode = m
                    // 重应用的是当前这张图，图没变 → 不重置自动切换计时
                    if let u = mgr.currentURL { mgr.setWallpaper(u, resetTimer: false) }
                }
            })
            .frame(width: 280, height: 26)

            Divider()

            // ── 下载与更新：抓新图、存哪儿 ──
            SectionHeader("下载与更新")

            // 更新时间：近期使用 / 自定义时间…（子菜单在右侧级联）
            SubmenuRow(icon: "clock", title: updateText, items: updateItems)
                .frame(width: 280, height: 26)

            // apply: false —— 只拉新图入库，不顺手顶掉当前壁纸
            MenuRow("立即检查更新", icon: "arrow.clockwise") { Task { await mgr.refresh(apply: false) } }
            MenuRow("打开壁纸文件夹", icon: "folder")        { mgr.openFolder() }
            MenuRow("选择下载目录…",  icon: "externaldrive") { mgr.chooseFolder() }

            Divider()

            // ── 通用 ──
            SectionHeader("通用")

            Toggle("开机启动", isOn: $mgr.autostart)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            MenuRow("关于 Bing Wallpaper", icon: "info.circle") { mgr.showAbout() }

            MenuRow("退出") { NSApp.terminate(nil) }
        }
        .frame(width: 280)
        .task(id: mgr.currentURL) {
            thumb = mgr.currentURL.flatMap { makeThumbnail($0, maxPixel: 560) }
        }
    }
}

// MARK: - App

@main
struct BingWallpaperApp: App {
    @StateObject private var mgr = WallpaperManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(mgr: mgr)
        } label: {
            Image(systemName: "photo")
        }
        .menuBarExtraStyle(.window)
    }
}
