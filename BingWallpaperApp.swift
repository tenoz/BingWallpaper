import SwiftUI
import AppKit
import ImageIO

// MARK: - 路径

let DEFAULT_PICS_DIR = URL(fileURLWithPath: "/Users/pxdog/Pictures/bing-wallpaper", isDirectory: true)
let SUPPORT_DIR      = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/BingWallpaper", isDirectory: true)
let AGENT_PLIST      = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/com.pxdog.bingwallpaper.plist")

// MARK: - 模型

enum UpdateMode: String, CaseIterable {
    case interval = "按间隔"
    case daily    = "每天定时"
}

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

    /// 自动检查间隔（小时），按间隔模式生效，持久化到 UserDefaults，默认 3
    @Published var intervalHours: Int {
        didSet {
            UserDefaults.standard.set(intervalHours, forKey: "intervalHours")
            if updateMode == .interval { setupTimer() }
        }
    }
    /// 更新方式：按间隔 / 每天定时，二选一
    @Published var updateMode: UpdateMode {
        didSet {
            UserDefaults.standard.set(updateMode.rawValue, forKey: "updateMode")
            setupTimer()
        }
    }
    /// 每天定时的时刻（24h 制 HH:mm），默认 08:00
    @Published var dailyTime: String {
        didSet {
            UserDefaults.standard.set(dailyTime, forKey: "dailyTime")
            if updateMode == .daily { setupTimer() }
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
    private var timer: Timer?

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
        intervalHours = UserDefaults.standard.object(forKey: "intervalHours") as? Int ?? 3
        updateMode    = UpdateMode(rawValue: UserDefaults.standard.string(forKey: "updateMode") ?? "") ?? .interval
        dailyTime     = UserDefaults.standard.string(forKey: "dailyTime") ?? "08:00"
        recentTimes   = UserDefaults.standard.stringArray(forKey: "recentTimes") ?? ["08:00"]
        scalingMode   = ScalingMode(rawValue: UserDefaults.standard.string(forKey: "scalingMode") ?? "") ?? .fill
        let savedDir = UserDefaults.standard.string(forKey: "picsDir") ?? ""
        picsDir = savedDir.isEmpty ? DEFAULT_PICS_DIR : URL(fileURLWithPath: savedDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: picsDir,     withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: SUPPORT_DIR, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: manifestFile),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [String] { manifest = Set(arr) }
        refreshCurrentName()
        setupTimer()
        Task { @MainActor in await self.refresh() }
    }

    /// 按更新方式重建定时器（先 invalidate 旧的，避免双定时器）
    private func setupTimer() {
        timer?.invalidate()
        timer = nil
        switch updateMode {
        case .interval:
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalHours * 3600), repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        case .daily:
            // 一次性定时器到点触发，触发后重排下一天（避免累积漂移，天然跟随修改）
            let wait = max(nextDailyFire().timeIntervalSinceNow, 1)
            timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    await self?.refresh()
                    self?.setupTimer()
                }
            }
        }
    }

    /// 下一个 dailyTime 时刻（今日已过则排明天）
    private func nextDailyFire() -> Date {
        let p = dailyTime.split(separator: ":").compactMap { Int($0) }
        let h = p.count > 0 ? min(max(p[0], 0), 23) : 8
        let m = p.count > 1 ? min(max(p[1], 0), 59) : 0
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = h
        c.minute = m
        let t = Calendar.current.date(from: c) ?? Date().addingTimeInterval(86400)
        return t > Date() ? t : t.addingTimeInterval(86400)
    }

    /// 规范化 "H:mm" → "HH:mm"；非法返回 nil
    static func normalizeTime(_ s: String) -> String? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// 设每天定时时刻并切到定时模式；同时记入近期使用（去重、最新在前、最多 3 个）
    func setDailyTime(_ t: String) {
        dailyTime = t
        updateMode = .daily
        recentTimes = ([t] + recentTimes.filter { $0 != t }).prefix(3).map { $0 }
        status = "更新方式：每天 \(t)"
    }

    /// 弹窗输入每天定时的时分（HH:mm）。
    /// 不用 NSAlert：它强制在最左侧显示 App 图标，且设 icon = nil 无效（会退回默认图标）。
    func askCustomTime() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 124),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "每天定时"
        win.isReleasedWhenClosed = false

        let view = win.contentView!
        let hint = NSTextField(labelWithString: "24 小时制，格式 HH:mm（例如 08:30）")
        hint.frame = NSRect(x: 20, y: 78, width: 260, height: 16)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        view.addSubview(hint)

        let input = NSTextField(frame: NSRect(x: 20, y: 50, width: 260, height: 24))
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

        let cancel = NSButton(frame: NSRect(x: 128, y: 14, width: 76, height: 28))
        cancel.title = "取消"; cancel.bezelStyle = .push; cancel.keyEquivalent = "\u{1b}"
        cancel.target = bridge; cancel.action = #selector(TimeInputBridge.cancel(_:))
        view.addSubview(cancel)

        let ok = NSButton(frame: NSRect(x: 204, y: 14, width: 76, height: 28))
        ok.title = "确定"; ok.bezelStyle = .push; ok.keyEquivalent = "\r"
        ok.target = bridge; ok.action = #selector(TimeInputBridge.ok(_:))
        view.addSubview(ok)

        win.center()
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement App 需主动激活
        win.makeFirstResponder(input)
        NSApp.runModal(for: win)                  // bridge 在本作用域存活至 modal 结束
    }

    // MARK: 抓取与下载

    /// 接口 idx 被服务端钳在 8、n 钳在 8，故取 0 与 8 两段 = 最近约 16 天
    private func candidates() async -> [BingImage] {
        var out: [BingImage] = []
        for idx in [0, 8] {
            guard let u = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=\(idx)&n=8&mkt=zh-CN"),
                  let (data, _) = try? await URLSession.shared.data(from: u),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = obj["images"] as? [[String: Any]] else { continue }
            for im in images {
                guard let sd  = im["startdate"] as? String,
                      let ub  = im["urlbase"] as? String,
                      let raw = ub.components(separatedBy: "id=").last,
                      let url = URL(string: "https://www.bing.com/th?id=\(raw)_UHD.jpg") else { continue }
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
        try? d.write(to: manifestFile)
    }

    /// 抓取 + 按清单去重下载 + 按自动模式应用壁纸（手动触发下载走同一入口）
    func refresh() async {
        status = "检查新壁纸…"
        let cands = await candidates()
        guard !cands.isEmpty else { status = "接口无返回"; return }
        var added = 0
        for c in cands where !manifest.contains(c.id) {
            if await download(c) { manifest.insert(c.id); added += 1 }
        }
        saveManifest()
        applyAuto(note: added > 0 ? "（新增 \(added) 张）" : "（无新图）")
    }

    // MARK: 图片列表

    func listImages() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: picsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "jpg" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func newestImage() -> URL? { listImages().last }
    func randomImage() -> URL? { listImages().randomElement() }

    // MARK: 应用壁纸

    /// 检查后自动应用最新一张
    func applyAuto(note: String = "") {
        guard let t = newestImage() else { status = "库内无图片" + note; return }
        setWallpaper(t, note: note)
    }

    func setWallpaper(_ url: URL, note: String = "") {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let ok = NSScreen.screens.allSatisfy { ws.desktopImageURL(for: $0) == url }
            if !ok { self.status = "设置可能未生效：" + url.lastPathComponent }
        }
    }

    /// 上一张 / 下一张：从系统当前壁纸反查索引，无状态、自愈
    func step(_ delta: Int) {
        let imgs = listImages()
        guard !imgs.isEmpty else { status = "库内无图片"; return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let cur = NSWorkspace.shared.desktopImageURL(for: screen),
              let i = imgs.firstIndex(where: { $0.standardizedFileURL == cur.standardizedFileURL })
        else {
            setWallpaper(delta > 0 ? imgs[0] : imgs[imgs.count - 1])
            return
        }
        setWallpaper(imgs[min(max(i + delta, 0), imgs.count - 1)])
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

/// 时间输入面板的按钮/窗口事件桥接（AppKit 的 target-action 要求 NSObject）
private final class TimeInputBridge: NSObject, NSWindowDelegate {
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

/// 子菜单入口行：padding / 行长 / hover 高亮全在样式里，与 MenuRow 用同一套数值，
/// 保证「壁纸填充」「更新方式」两行与普通菜单行严格对齐
struct RowMenuStyle: MenuStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// 子菜单入口的内容：左图标（与 MenuRow 同宽 14）+ 标题 + 右端 chevron
struct SubmenuLabel: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 14)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.body)
    }
}

struct MenuContent: View {
    @ObservedObject var mgr: WallpaperManager
    @State private var thumb: NSImage?

    /// 长路径缩写为 ~/...，避免撑宽菜单
    private var dirText: String {
        (mgr.picsDir.path as NSString).abbreviatingWithTildeInPath
    }

    private var updateText: String {
        if mgr.updateMode == .interval { return "更新方式：每 \(mgr.intervalHours) 小时" }
        return "更新方式：每天 \(mgr.dailyTime)"
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

            MenuRow("设为最新", icon: "sparkles") { if let u = mgr.newestImage() { mgr.setWallpaper(u) } }
            MenuRow("随机一张", icon: "shuffle")  { if let u = mgr.randomImage() { mgr.setWallpaper(u) } }

            Divider()

            Menu {
                ForEach(ScalingMode.allCases, id: \.rawValue) { m in
                    Button {
                        guard mgr.scalingMode != m else { return }
                        mgr.scalingMode = m
                        if let u = mgr.currentURL { mgr.setWallpaper(u) }
                    } label: {
                        if mgr.scalingMode == m { Label(m.rawValue, systemImage: "checkmark") }
                        else { Text(m.rawValue) }
                    }
                }
            } label: {
                SubmenuLabel(title: "壁纸填充：\(mgr.scalingMode.rawValue)", icon: "aspectratio")
            }
            .menuStyle(RowMenuStyle())
            .frame(width: 280)

            Menu {
                Menu("按间隔") {
                    ForEach([1, 3, 6, 12, 24], id: \.self) { h in
                        Button {
                            mgr.intervalHours = h
                            mgr.updateMode = .interval
                        } label: {
                            if mgr.updateMode == .interval && mgr.intervalHours == h {
                                Label("每 \(h) 小时", systemImage: "checkmark")
                            } else { Text("每 \(h) 小时") }
                        }
                    }
                }
                Section("近期使用") {
                    ForEach(mgr.recentTimes, id: \.self) { t in
                        Button {
                            mgr.setDailyTime(t)
                        } label: {
                            if mgr.updateMode == .daily && mgr.dailyTime == t {
                                Label("每天 \(t)", systemImage: "checkmark")
                            } else { Text("每天 \(t)") }
                        }
                    }
                }
                Button {
                    mgr.askCustomTime()
                } label: {
                    Label("自定义时间…", systemImage: "pencil")
                }
            } label: {
                SubmenuLabel(title: updateText, icon: "clock")
            }
            .menuStyle(RowMenuStyle())
            .frame(width: 280)

            MenuRow("立即检查更新", icon: "arrow.clockwise") { Task { await mgr.refresh() } }
            MenuRow("打开壁纸文件夹", icon: "folder")        { mgr.openFolder() }
            MenuRow("选择下载目录…",  icon: "externaldrive") { mgr.chooseFolder() }

            Divider()

            Toggle("开机启动", isOn: $mgr.autostart)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

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
