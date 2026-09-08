# macOS AppKit / 菜单栏 App 的 GUI 坑位

面向接手者：本文收录**通用 macOS GUI 坑**（换项目同样适用），都是本项目实打实踩过、
已解决的。改代码必须遵守的约定在根 `CLAUDE.md`；本文只在**你正要动这块 GUI**时才需要读。

> 为什么单独一份：这些坑属于"改到才碰"的知识，全塞进 `CLAUDE.md` 会把
> 每次会话都必须看到的规则挤掉。`CLAUDE.md` 里只留一行指针。

---

## 一、自建 modal 输入面板（`askCustomTime` 那一套）

### 1. 输入框无法编辑（点进去像聚焦了，但打不进字）

App 是 `LSUIElement`（activationPolicy = `.accessory`），其窗口在 App **非激活态无法成为
key window**，而 `NSTextField` 必须在 key window 中才能进编辑模式；`runModal(for:)`
内部的 `makeKeyAndOrderFront` 因 App 非激活被系统忽略 → 表现为「按钮能点、输入框打不进字」
（按钮靠 mouse 事件派发，不依赖 key window，所以照常）。

**解**：弹窗前临时 `NSApp.setActivationPolicy(.regular)`（`LSUIElement` 保证 Dock 不露图标，
所以这是安全的），`runModal` 结束后还原 `.accessory`；并补 `makeKeyAndOrderFront`
+ `makeFirstResponder`，input 也显式 `isEditable/isSelectable`。

⚠️ **以后凡是自建 modal 窗口（NSTextField 输入类）都要走这套临时提升。**
系统 `NSOpenPanel`（选下载目录用的就是它）自带正确处理，不受影响。

### 2. 窄输入框边框只画一半（macOS 26）

系统改走 layer 绘制，legacy `isBordered` / bezel 在小尺寸控件上只画上半截 + 左侧。

**解**：关掉 `isBordered/isBezeled` + `focusRingType = .none`，用 `wantsLayer` + layer 的
`borderWidth/cornerRadius/borderColor` 自绘；聚焦变色走 `NSTextFieldDelegate` 的
`controlTextDidBegin/EndEditing`。

### 3. 文字不垂直居中（两层都得修）

单行 `NSTextField` **没有公开的垂直对齐属性**，`usesSingleLineMode` 也兜不住。

- ① **非编辑态**（显示已填值）：`NSTextFieldCell` 子类重写 `drawingRect(forBounds:)`
  把文字摆中间 → 见 `CenteredTextFieldCell`
- ② **编辑态**（点进去打字后）：绘制改由 field editor（`NSTextView`）接管，`drawingRect`
  不再生效、文字会偏上 → 须在 `NSTextField` 子类 `becomeFirstResponder()` 里拿
  `currentEditor()` 设 `textContainerInset` 顶部偏移补偿 → 见 `CenteredTextField`

**漏掉 ② 就是「能编辑但字偏上」**。

### 4. NSAlert 的 App 图标去不掉

`icon` 声明为 `NSImage!`，**赋 nil 无效**（nil = 用默认 App 图标），只能塞 1×1 透明图占位（丑）。
要无图标的自定输入面板 → 自建 `NSWindow` + `NSApp.runModal(for:)`。

⚠️ 自建 modal 必须同时处理点关闭按钮：`NSWindowDelegate.windowWillClose` 里调 `stopModal()`，
否则 modal 循环卡死。

---

## 二、菜单栏下拉菜单（MenuBarExtra）

### 5. 顶层 Menu 只能向下弹，无法右侧级联

子菜单要在右侧级联，前提是它**本身是某个 NSMenu 的子项**。MenuBarExtra(.window) 面板里的
**顶层** `Menu` 只能向下弹出，SwiftUI 没有改变弹出方向的 API。想向右展开就得套一层父级 Menu
（多一次点击）。

### 6. `borderlessButton` 会偷偷改写样式

MenuBarExtra(.window) 里，`borderlessButton` 会改写标签的**字型字重 + 垂直基线 + 右侧箭头
方向**（箭头按子菜单弹出方向自动旋转为 ▾）；覆盖了 `.font(.body)` 也会发现字型/字重仍不同，
跟其它图标比就是「水平不对齐」。

**解**：完全不用 `borderlessButton`，`Menu(configuration)` 后直接挂 padding / background /
hover（见 `RowMenuStyle`）。此模式下 `>` 方向由自己在 `SubmenuLabel` 画（`chevron.right`
不会被覆盖）。

---

## 三、构建与图标

### 7. 图标生成：sips 只改后缀不改编码

`sips` 从 jpeg 源输出 `.png` 时**只改后缀不改编码**，`iconutil` 会报
`Failed to generate ICNS`。

**解**：必须先用 `sips -s format png` 把源转成真 PNG，再生成各尺寸。

### 8. /Applications 原地 ad-hoc 签名会产坏 seal（macOS 26）

`codesign -s -` 对 /Applications 下的 bundle 签名后，`CodeResources` 的 files2 把主程序记成
`MacOS/BingWallpaper.cstemp`（签名临时文件名），`codesign -v` 报
`a sealed resource is missing or invalid`；删签名重签仍 100% 复现，**同一 bundle 在项目目录
签名一次通过**。

**解**：`build.sh` 改为「暂存目录构建 → 签名 → 验证 → ditto 搬运到 /Applications」。
排查认症：`plutil -p .../CodeResources | grep cstemp`
