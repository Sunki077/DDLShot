// main.swift — DDLShot 菜单栏 App 入口
//
// 设计说明（为什么有控制面板窗口）：
//   这台 macOS 26 上，**第三方 NSStatusItem 根本不渲染**（自写最小复现程序同样不显示，
//   而微信 / 拼多多的图标正常）——所以「菜单栏图标」不能作为唯一的入口。
//   因此 DDLShot 在双击启动时会直接弹出一个「控制面板」窗口，
//   里面直接放三个按钮；菜单栏图标保留但不再承担唯一入口职责。
import AppKit
import EventKit
import UserNotifications
import CShim

// MARK: - 单实例握手（用文件，不依赖任何私有 API）
//
// 背景：以前这里是「发现已有实例就 exit(0)」，双击之后屏幕上什么也没有，
//       用户会以为 App 打不开。
// 现在改成：已有实例 → 敲「敲门文件」把它叫醒（它弹出控制面板）→ 本进程退出；
//       没人应答（旧版本 / 已卡死）→ 本进程接管，结束旧进程。
enum SingleInstance {
    private static var dir: String { NSTemporaryDirectory() }
    private static var primaryPath: String { dir + "ddlshot-primary.pid" }
    private static var wakePath: String { dir + "ddlshot-wake" }
    private static var ackPath: String { dir + "ddlshot-ack" }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    private static func write(_ path: String, _ value: String) {
        try? value.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func readDouble(_ path: String) -> Double {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 登记自己是主实例
    static func becomePrimary() {
        write(primaryPath, "\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// 当前主实例的 PID（0 = 没有）
    static func primaryPID() -> pid_t {
        guard let s = try? String(contentsOfFile: primaryPath, encoding: .utf8) else { return 0 }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 某个 PID 是否还活着
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// 敲敲门，把控制面板交给已在运行的主实例。
    /// - Returns: true = 对方已接管（弹出了控制面板），本进程应当退出。
    static func wakeRunning(timeout: TimeInterval = 2.0) -> Bool {
        let t = now()
        write(wakePath, "\(t)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readDouble(ackPath) >= t { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// 主实例常驻轮询：发现「敲门」就回调（并在面板弹出后回 ack）
    static func pollWake(handler: @escaping () -> Void) {
        var last = readDouble(wakePath)
        DispatchQueue.global(qos: .utility).async {
            while true {
                Thread.sleep(forTimeInterval: 0.3)
                let t = readDouble(wakePath)
                guard t > last else { continue }
                last = t
                DispatchQueue.main.async {
                    handler()
                    write(SingleInstance.ackPath, "\(SingleInstance.now())")
                }
            }
        }
    }
}

// MARK: - 菜单栏控制器

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var cfg = Config()
    /// 热键自检的计时器
    private var hotkeyTestTimer: Timer?
    private var hotkeyTestDeadline: Date?

    /// 控制面板窗口（懒创建）
    private var panel: NSPanel?
    private var resultLabel: NSTextField?
    private var engineLabel: NSTextField?
    private var reminderLabel: NSTextField?
    private var screenLabel: NSTextField?
    private var hotkeyLabel: NSTextField?
    private var accessibilityButton: NSButton?

    func start() {
        setupStatusItem()
        statusItem.menu = buildMenu()
        setupHotkey()
        requestNotificationPermission()

        // 启动即申请「提醒事项」授权：让系统弹窗出现在用户眼前，而不是等到第一次抓图
        Notify.handler = { [weak self] t, b in self?.notify(t, b) }
        DispatchQueue.global(qos: .utility).async {
            _ = try? Reminders.store()
        }

        // 被第二个实例「敲门」时把控制面板叫出来
        SingleInstance.pollWake { [weak self] in
            guard let self else { return }
            self.showPanel()
            self.notify("DDLShot 已在运行", "控制面板已打开")
        }
    }

    // MARK: 菜单栏项

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            // 用和 App 图标一致的取景框符号，语义统一
            let img = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "DDLShot")
            btn.image = img
            btn.image?.isTemplate = true
            btn.toolTip = "DDLShot — 截屏识别 DDL（⌃⌥D）"
        }
    }

    // MARK: 菜单

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        add(m, "显示控制面板", #selector(showPanel))
        // 「截取最前窗口 / 手动框选 / 解析剪贴板」面板上都有按钮，菜单里不再重复；
        // 只有「整个屏幕」是面板没有的能力，所以留在这里。
        add(m, "截取整个屏幕并记录 DDL", #selector(captureScreen))
        let engItem = NSMenuItem(title: "引擎：\(engineTitle)", action: #selector(toggleEngine), keyEquivalent: "")
        engItem.target = self
        m.addItem(engItem)
        m.addItem(.separator())
        add(m, "打开提醒事项", #selector(openReminders))
        add(m, "关于 / 权限自检", #selector(showAbout))
        m.addItem(.separator())
        add(m, "退出 DDLShot", #selector(quit))
        return m
    }

    private var engineTitle: String {
        let c = LLMConfig.load()
        if let c, c.isConfigured { return "大模型（\(c.model)）" }
        return "本地规则"
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: 动作

    @objc private func captureWindow() { runCLI(["--capture"]) }
    @objc private func captureScreen() { runCLI(["--screen"]) }
    @objc private func captureInteractive() { runCLI(["--interactive"]) }
    @objc private func parseClipboard() { runCLI(["--clipboard"]) }

    @objc private func toggleEngine() {
        let c = LLMConfig.load()
        if let c, c.isConfigured {
            let al = NSAlert()
            al.messageText = "当前引擎"
            var lines = """
            供应商：\(c.providerTitle)
            模型　：\(c.model)
            地址　：\(c.baseURL)

            切换：把配置里的 "provider" 改成下面任意 id 即可，
            base_url / model / protocol 会自动补上：

            """
            for p in LLMProviders.all {
                lines += "\(p.id)  —  \(p.title)\n"
            }
            lines += "\n配置文件：\(c.configPath)"
            al.informativeText = lines
            al.runModal()
        } else {
            let al = NSAlert()
            al.messageText = "大模型还没配置"
            al.informativeText = """
            当前用本地规则引擎（离线、快，但只能抠关键词）。

            开启大模型需要两步：
            1. 写一份配置文件：
               \(LLMConfig.defaultConfigPath)
               内容形如（provider 换成任意一家都行，完整列表跑 --list-providers）：
               {
                 "llm": {
                   "provider": "minimax",
                   "api_key": "你的 key"
                 }
               }
            2. 重启 DDLShot（面板/菜单里点「退出 DDLShot」再重新打开）

            已内置的供应商：MiniMax / DeepSeek / OpenAI / 通义千问 / 智谱 / Kimi /
            豆包 / 硅基流动 / Gemini / 本地 Ollama / 自定义。
            任何 OpenAI 兼容接口都能用。
            """
            al.runModal()
        }
    }

    @objc private func openReminders() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Reminders.app"),
                                          configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func showAbout() {
        let remindOK = Permissions.remindersGranted
        let screenOK = Permissions.screenCaptureGranted
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let lcfg = LLMConfig.load()
        let llmStr = (lcfg?.isConfigured == true) ? "已配置（\(lcfg!.model)）" : "未配置"
        let msg = """
        DDLShot v\(ver)

        提醒事项权限：\(remindOK ? "已授权 ✅" : "未授权 ✗")
        屏幕录制权限：\(screenOK ? "已授权 ✅" : "未授权 ✗")
        大模型　　　：\(llmStr)
        目标清单　　：\(cfg.listName)
        快捷键　　　：\(HotKeyManager.shared.combo.display)（截取最前窗口）

        OCR 全部在本机完成；启用大模型后，只有屏幕内容会发给你配置的服务商。

        权限没开的话：
        · 提醒事项 → 系统设置 → 隐私与安全性 → 提醒事项
        · 屏幕录制 → 系统设置 → 隐私与安全性 → 录屏与系统录音
        """
        let al = NSAlert()
        al.messageText = "DDLShot"
        al.informativeText = msg
        al.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 控制面板

    @objc func showPanel() {
        if panel == nil {
            panel = makePanel()
        }
        // 万一窗口被拖到屏幕外（这个 App 没有 Dock 图标、菜单栏图标在这台 macOS 26 上
        // 又不显示，一旦飘出去就再也找不回来），先夹回可见区域再显示。
        if let p = panel { clampOnScreen(p) }
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        refreshPanelStatus()
    }

    /// 面板已经开着就别再叫一次（避免 activate → becomeActive → 再 activate 的回环）
    func showPanelIfNeeded() {
        if let p = panel, p.isVisible { return }
        showPanel()
    }

    /// 常规 App 的主菜单。
    /// 有了 Dock 图标之后就是个正常 Mac App，菜单栏不能是空的：
    /// 至少要能 ⌘Q 退出、⌘W 关窗、⌘M 最小化，以及在输入框里 ⌘C / ⌘V。
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // ── 应用菜单 ──
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let aboutItem = NSMenuItem(title: "关于 DDLShot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        let permItem = NSMenuItem(title: "权限自检…", action: #selector(showAbout), keyEquivalent: "")
        permItem.target = self
        appMenu.addItem(permItem)
        appMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "隐藏 DDLShot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 DDLShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        // ── 编辑菜单 ──
        let editMenu = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)
        for (title, sel, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
                                  ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"),
                                  ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let it = NSMenuItem(title: title, action: Selector((sel)), keyEquivalent: key)
            it.target = NSApp
            editMenu.addItem(it)
        }

        // ── 窗口菜单 ──
        let winMenu = NSMenu(title: "窗口")
        let winItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        winItem.submenu = winMenu
        main.addItem(winItem)
        let miniItem = NSMenuItem(title: "收起", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(miniItem)
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        return main
    }

    /// 把窗口夹回屏幕可见区域，至少留一部分在屏幕里
    private func clampOnScreen(_ w: NSWindow) {
        guard let screen = w.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var f = w.frame
        let minVisibleX: CGFloat = 90
        let minVisibleY: CGFloat = 50

        if f.maxX < visible.minX + minVisibleX {
            f.origin.x = visible.minX + minVisibleX - f.width
        } else if f.minX > visible.maxX - minVisibleX {
            f.origin.x = visible.maxX - minVisibleX
        }
        if f.maxY < visible.minY + minVisibleY {
            f.origin.y = visible.minY + minVisibleY - f.height
        } else if f.minY > visible.maxY - minVisibleY {
            f.origin.y = visible.maxY - minVisibleY
        }
        if f.origin != w.frame.origin {
            w.setFrameOrigin(f.origin)
        }
    }

    private func makePanel() -> NSPanel {
        let w: CGFloat = 380
        let h: CGFloat = 560
        // .miniaturizable：标题栏上要有最小化按钮（最小化后收到 Dock 里）
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .miniaturizable],
                        backing: .buffered, defer: false)
        p.title = "DDLShot"
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false

        // ⚠️ 千万别用 .floating：那会让面板**永远压在别的 App 窗口上面**，
        // 切到任何窗口都被它挡住，非常影响体验。
        // 普通层级下：切走之后它老老实实待在后面，跟普通窗口一个待遇。
        p.level = .normal
        // 别用 .canJoinAllSpaces（那会让它出现在每个桌面上），
        // 只跟着当前空间走就行。
        p.collectionBehavior = [.moveToActiveSpace]
        p.contentView = buildPanelContent(width: w, height: h)

        // 记住上次摆放的位置；第一次打开才居中
        p.setFrameAutosaveName("DDLShotPanel")
        if UserDefaults.standard.string(forKey: "NSWindow Frame DDLShotPanel") == nil {
            p.center()
        }
        clampOnScreen(p)
        return p
    }

    private func buildPanelContent(width: CGFloat, height: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let margin: CGFloat = 22
        let contentW = width - margin * 2
        var y = height - margin

        // 标题（左边配一个 App 图标）
        let iconSide: CGFloat = 38
        let appIcon: NSImage? = {
            if let img = NSApp.applicationIconImage, img.size.width > 1 { return img }
            if let p = Bundle.main.path(forResource: "AppIcon", ofType: "icns") {
                return NSImage(contentsOfFile: p)
            }
            return nil
        }()
        if let appIcon {
            let iv = NSImageView(frame: NSRect(x: margin, y: y - 33, width: iconSide, height: iconSide))
            iv.image = appIcon
            iv.imageScaling = .scaleProportionallyUpOrDown
            v.addSubview(iv)
        }
        let textX = margin + 50
        let title = makeLabel("DDLShot", size: 26, weight: .bold, color: .labelColor)
        title.frame = NSRect(x: textX, y: y - 32, width: contentW - 50, height: 32)
        v.addSubview(title)
        y -= 32

        let sub = makeLabel("截屏 → 识别 DDL → 写入「提醒事项」", size: 13, weight: .regular, color: .secondaryLabelColor)
        sub.frame = NSRect(x: textX, y: y - 20, width: contentW - 50, height: 20)
        v.addSubview(sub)
        y -= 20 + 16

        // 三个大按钮
        y = addButton(v, title: "截取最前窗口并记录 DDL",
                      subtitle: "⌃⌥D 随时触发",
                      x: margin, y: y, width: contentW, height: 52,
                      accent: true,
                      action: #selector(captureWindow))
        y -= 10
        y = addButton(v, title: "手动框选区域并记录 DDL",
                      subtitle: "自己拖一个框",
                      x: margin, y: y, width: contentW, height: 52,
                      action: #selector(captureInteractive))
        y -= 10
        y = addButton(v, title: "解析剪贴板文字并记录 DDL",
                      subtitle: "复制一段文字即可",
                      x: margin, y: y, width: contentW, height: 52,
                      action: #selector(parseClipboard))
        y -= 18

        // 分隔线
        let sep = NSView(frame: NSRect(x: margin, y: y, width: contentW, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.addSubview(sep)
        y -= 18

        // 状态行（注意：先强引用再赋给属性，直接赋给属性会被立刻释放）
        let engine = makeLabel("", size: 12, weight: .regular, color: .secondaryLabelColor)
        engine.frame = NSRect(x: margin, y: y - 17, width: contentW, height: 17)
        v.addSubview(engine)
        engineLabel = engine
        y -= 19

        let reminder = makeLabel("", size: 12, weight: .regular, color: .secondaryLabelColor)
        reminder.frame = NSRect(x: margin, y: y - 17, width: contentW, height: 17)
        v.addSubview(reminder)
        reminderLabel = reminder
        y -= 19

        let screen = makeLabel("", size: 12, weight: .regular, color: .secondaryLabelColor)
        screen.frame = NSRect(x: margin, y: y - 17, width: contentW, height: 17)
        v.addSubview(screen)
        screenLabel = screen
        y -= 19

        let hotkey = makeLabel("", size: 12, weight: .regular, color: .secondaryLabelColor)
        hotkey.frame = NSRect(x: margin, y: y - 17, width: contentW, height: 17)
        v.addSubview(hotkey)
        hotkeyLabel = hotkey
        y -= 19 + 6

        // 热键相关的小按钮
        let testBtn = NSButton(title: "测试热键", target: self, action: #selector(testHotkey))
        testBtn.bezelStyle = .rounded
        testBtn.controlSize = .small
        testBtn.font = NSFont.systemFont(ofSize: 12)
        testBtn.frame = NSRect(x: margin, y: y - 24, width: 96, height: 24)
        v.addSubview(testBtn)

        let axBtn = NSButton(title: "辅助功能授权", target: self, action: #selector(requestAccessibility))
        axBtn.bezelStyle = .rounded
        axBtn.controlSize = .small
        axBtn.font = NSFont.systemFont(ofSize: 12)
        axBtn.frame = NSRect(x: margin + 104, y: y - 24, width: 118, height: 24)
        v.addSubview(axBtn)
        accessibilityButton = axBtn
        y -= 24 + 12

        // 结果行
        let result = makeLabel("", size: 12, weight: .medium, color: .labelColor)
        result.maximumNumberOfLines = 3
        result.lineBreakMode = .byWordWrapping
        result.frame = NSRect(x: margin, y: y - 54, width: contentW, height: 54)
        v.addSubview(result)
        resultLabel = result
        y -= 54 + 10

        // 底部提示 + 退出
        let foot = makeLabel("关闭窗口后应用仍在后台运行，⌃⌥D 随时可用", size: 11, weight: .regular, color: .tertiaryLabelColor)
        foot.frame = NSRect(x: margin, y: y - 16, width: contentW - 60, height: 16)
        v.addSubview(foot)

        let quitBtn = NSButton(title: "退出", target: self, action: #selector(quit))
        quitBtn.bezelStyle = .inline
        quitBtn.isBordered = false
        quitBtn.font = NSFont.systemFont(ofSize: 12)
        quitBtn.contentTintColor = .secondaryLabelColor
        quitBtn.frame = NSRect(x: width - margin - 50, y: y - 18, width: 50, height: 20)
        v.addSubview(quitBtn)

        return v
    }

    private func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// 一个带主标题的大按钮，返回下一个可用 y
    private func addButton(_ v: NSView, title: String, subtitle: String,
                           x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                           accent: Bool = false,
                           action: Selector) -> CGFloat {
        let btn = NSButton(title: "", target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .large
        btn.frame = NSRect(x: x, y: y - height, width: width, height: height)
        btn.setButtonType(.momentaryPushIn)
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: accent ? .semibold : .medium),
            .foregroundColor: accent ? NSColor.white : NSColor.labelColor
        ])
        if accent {
            btn.bezelColor = .controlAccentColor
        }
        btn.toolTip = subtitle
        v.addSubview(btn)
        return y - height
    }

    private func refreshPanelStatus() {
        let lcfg = LLMConfig.load()
        let engine = (lcfg?.isConfigured == true) ? "\(lcfg!.providerTitle)（\(lcfg!.model)）" : "本地规则引擎"
        engineLabel?.stringValue = "引擎：\(engine)"
        reminderLabel?.stringValue = "提醒事项：\(Permissions.remindersGranted ? "已授权 ✅" : "未授权 ✗（系统设置 → 隐私与安全性 → 提醒事项）")"
        screenLabel?.stringValue = "屏幕录制：\(Permissions.screenCaptureGranted ? "已授权 ✅" : "未授权 ✗（系统设置 → 隐私与安全性 → 录屏与系统录音）")"

        let combo = HotKeyManager.shared.combo
        let carbonOK = HotKeyManager.shared.carbonStatus == 0
        let axOK = HotKeyManager.shared.accessibilityActive
        let tapOK = HotKeyManager.shared.eventTapActive
        hotkeyLabel?.stringValue = "热键：\(combo.display)（Carbon \(carbonOK ? "已注册" : "失败") · 监听 \(axOK ? "已启用" : "未授权") · tap \(tapOK ? "已启用" : "未启用")）"
        accessibilityButton?.isHidden = axOK
    }

    private func setResult(_ text: String, ok: Bool) {
        resultLabel?.stringValue = text
        resultLabel?.textColor = ok ? .systemGreen : .systemRed
        refreshPanelStatus()
    }

    // MARK: 执行

    private func runCLI(_ args: [String]) {
        setResult("正在识别…", ok: true)
        Task.detached(priority: .userInitiated) { [self] in
            var cli = CLI()
            cli.cfg = self.cfg
            cli.parseArgs(args)
            CLI.lastError = nil
            let code = await cli.run()
            let err = CLI.lastError
            await MainActor.run {
                if code != 0 {
                    self.setResult(err ?? "执行失败（退出码 \(code)）", ok: false)
                    self.showFailure(code: code)
                } else {
                    self.setResult("✅ 已写入提醒事项「\(self.cfg.listName)」", ok: true)
                }
            }
        }
    }

    /// 失败弹窗：直接展示真实原因，并按权限类型分流
    private func showFailure(code: Int32) {
        let al = NSAlert()
        al.messageText = "DDLShot 执行失败"
        var body = CLI.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.isEmpty { body = "退出码 \(code)" }
        var extra = ""
        if !Permissions.remindersGranted {
            extra += "\n提醒事项权限未开 → 系统设置 → 隐私与安全性 → 提醒事项"
        }
        if !Permissions.screenCaptureGranted {
            extra += "\n屏幕录制权限未开 → 系统设置 → 隐私与安全性 → 录屏与系统录音"
        }
        al.informativeText = body + extra
        al.runModal()
    }

    // MARK: 通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if err != nil {
                Notify.post(title, body)
            }
        }
    }

    // MARK: 全局快捷键 ⌃⌥D

    private func setupHotkey() {
        let combo = HotKeyConfig.load()
        HotKeyManager.shared.onFire = { [weak self] source in
            self?.handleHotkeyFire(source: source)
        }
        HotKeyManager.shared.start(combo: combo)
        if HotKeyManager.shared.carbonStatus != 0 {
            NSLog("DDLShot: Carbon 热键注册失败（OSStatus \(HotKeyManager.shared.carbonStatus)）")
        }
    }

    /// 热键触发：立刻给反馈，别让用户等几十秒以为没反应
    private func handleHotkeyFire(source: String) {
        let combo = HotKeyManager.shared.combo
        if hotkeyTestDeadline != nil {
            hotkeyTestDeadline = nil
            hotkeyTestTimer?.invalidate()
            hotkeyTestTimer = nil
            setResult("✅ 热键正常（\(combo.display)，来源：\(source)）", ok: true)
        } else {
            setResult("\(combo.display) 已触发（\(source)），正在识别…", ok: true)
        }
        notify("DDLShot", "\(combo.display) 已触发，正在截取最前窗口…")
        runCLI(["--capture"])
    }

    /// 「测试热键」：10 秒内按一下，给出明确结论
    @objc private func testHotkey() {
        showPanel()
        let combo = HotKeyManager.shared.combo
        setResult("请按 \(combo.display)（10 秒内）…", ok: true)
        hotkeyTestDeadline = Date().addingTimeInterval(10)
        hotkeyTestTimer?.invalidate()
        hotkeyTestTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                if let deadline = self.hotkeyTestDeadline, Date() < deadline { return }
                t.invalidate()
                self.hotkeyTestTimer = nil
                self.hotkeyTestDeadline = nil
                self.setResult("❌ 10 秒内没收到 \(combo.display)。看下面的热键状态行，或点「辅助功能授权」后再试。诊断日志：\(HotKeyLog.path)", ok: false)
            }
        }
    }

    @objc private func requestAccessibility() {
        HotKeyManager.shared.requestAccessibility()
        setResult("已弹出系统授权提示，去「系统设置 → 隐私与安全性 → 辅助功能」允许 DDLShot，2 秒内自动生效。", ok: true)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = MenuBarController()
    /// 由 launchd 开机拉起时不弹面板（免得开机就抢焦点）
    private let launchedAtLogin = ProcessInfo.processInfo.environment["DDLSHOT_LAUNCHED_AT_LOGIN"] == "1"
    /// 进程启动时刻：用来区分「启动瞬间系统自动激活」与「用户后来主动点 Dock 图标」
    private let launchDate = Date()
    /// 启动后这段时间内的激活一律视为系统自动激活，不弹面板
    private static let autoActivationWindow: TimeInterval = 8

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        if launchedAtLogin {
            controller.notify("DDLShot 已在后台运行", "点 Dock 图标或双击 DDLShot.app 可打开控制面板；⌃⌥D 可随时截取最前窗口")
        } else {
            controller.showPanel()
            controller.notify("DDLShot 已启动", "控制面板已打开；⌃⌥D 可随时截取最前窗口")
        }
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// 从 Dock 点图标进来时把面板叫出来。
    /// macOS 只在「没有可见窗口」时才发 reopen 事件，所以这里补一道 activation 兜底。
    func applicationDidBecomeActive(_ notification: Notification) {
        // 启动瞬间系统会自动激活一次（登录自启 / launchctl 拉起），那一次不该弹面板。
        // 这里用「启动后 8 秒内」的时间窗来识别它 —— 早先的写法是「跳过一次激活」，
        // 结果把用户的第一次点击也一起吞了，表现为点 Dock 一点反应都没有。
        // 注意：真正的 Dock 点击会发 reopen 事件，那条路不受这个时间窗影响，始终弹面板。
        if Date().timeIntervalSince(launchDate) < Self.autoActivationWindow { return }
        controller.showPanelIfNeeded()
    }

    /// App 已在运行时，用户又在访达里双击它 —— macOS 不会新起进程，
    /// 而是给正在跑的实例发一个「reopen」事件。不接这个事件的话，
    /// 双击就等于什么都没发生（用户以为 App 打不开）。这里把控制面板叫出来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showPanel()
        controller.notify("DDLShot 已在运行", "控制面板已打开")
        return true
    }
}

// MARK: - 入口

let rawArgs = Array(CommandLine.arguments.dropFirst())

// 单实例判定用运行中的 bundle id —— 由 build.sh 注入（可用 ~/.config/ddlshot/bundle_id 改）
let appBundleID = Bundle.main.bundleIdentifier ?? "app.ddlshot.mac"

if rawArgs.isEmpty {
    // 已经有实例在跑？→ 敲门把它叫醒（它会弹出控制面板），然后本进程退出。
    // （以前这里是直接 exit(0)，双击之后屏幕上什么也没有，用户会以为「App 打不开」。）
    let myPID = ProcessInfo.processInfo.processIdentifier
    let primary = SingleInstance.primaryPID()
    let hasPrimary = primary != myPID && SingleInstance.isAlive(primary)
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID)
        .filter { $0.processIdentifier != myPID && !$0.isTerminated }

    if hasPrimary || !others.isEmpty {
        if SingleInstance.wakeRunning() {
            exit(0)                       // 对方接管，控制面板会弹出来
        }
        // 没人应答（旧版本或已卡死）→ 结束旧进程，本进程接管
        for s in others { s.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let alive = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID)
                .filter { $0.processIdentifier != myPID && !$0.isTerminated }
            if alive.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    SingleInstance.becomePrimary()

    let app = NSApplication.shared
    let delegate = AppDelegate()          // 顶层变量 → 全局强引用，避免 delegate 被释放
    app.delegate = delegate
    // 正常 App 模式：要有 Dock 图标和主菜单。
    // 这里**不能**再 setActivationPolicy(.accessory) —— 那会把 App 从 Dock 里踢出去。
    app.mainMenu = delegate.controller.makeMainMenu()
    app.run()
} else {
    var cli = CLI()
    cli.parseArgs(rawArgs)
    // CLI 分支必须让主线程跑事件循环：
    //   --interactive 要弹框选窗口（RegionSelector 是 @MainActor），
    //   如果主线程卡在信号量上等待，MainActor 永远排不上 → 死锁。
    // 所以：主线程跑 NSApplication.run()，异步任务干完活后再退出。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let box = ResultBox()
    Task.detached {
        let code = await cli.run()
        box.value = code
        // 直接 exit(code) 而不是 NSApp.terminate —— 后者会把退出码抹成 0。
        exit(code)
    }
    app.run()
    exit(box.value)
}

/// 跨并发边界传递退出码
final class ResultBox: @unchecked Sendable {
    var value: Int32 = 1
}
