// HotKey.swift — 全局热键（三通道 + 可读诊断日志）
//
// 为什么要有三条通道（实测结论，不是预防性编程）：
//   ① Carbon RegisterEventHotKey —— 在 macOS 26 上**注册返回 0、ref 也非空，但事件永远不派发**。
//      状态行显示「已注册」完全是误导，所以它只能当兜底，不能当主力。
//   ② NSEvent.addGlobalMonitorForEvents / addLocalMonitorForEvents —— 需要「辅助功能」授权。
//      能收到大多数组合键，但**如果别的 App 用 local monitor 抢占了同一个键，
//      这里就收不到**（实测 ⌃⌥D 就是这样被抢的，而 ⌃⌥F 没被抢就能收到）。
//   ③ CGEventTap（session 级）—— 位于事件分发链最上游，**抢不走**，是最可靠的主力通道。
//      需要「辅助功能」或「输入监控」权限。
//
// 实测（macOS 26.6.2）：
//   按 ⌃⌥D → 只有 CGEventTap 记录到 keyCode=0x02，Carbon 回调从未被调用 → 走 ③ 触发 ✅
//   按 ⌃⌥F → CGEventTap 与全局监听都记录到 keyCode=0x03，且因为不是 D 而不触发 → 证明键码没错
//
// 键码约定（ANSI / 美国键盘布局）：
//   系统里 kVK_ANSI_D == 0x02，**不是 0x27**（0x27 是单引号 '）。
//   这套码可以用系统的 Unicode 转换反查验证，见 Tools/test_hotkey/main.swift。
import AppKit
import ApplicationServices
import CShim

// MARK: - 诊断日志

/// 热键诊断日志：写到 ~/Library/Logs/DDLShot/hotkey.log
/// （NSLog 在 launchd 拉起的 GUI 进程里不一定进得了统一日志，文件更可靠）
public enum HotKeyLog {
    public static let path: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DDLShot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hotkey.log").path
    }()

    private static let queue = DispatchQueue(label: "ddlshot.hotkey.log")

    /// 日志体积上限。诊断日志只在「带 ⌘/⌃/⌥ 的按键」或目标键时写，
    /// 普通打字不记 —— 但重度用快捷键的人一天能写几百行，
    /// 不加轮转的话文件会一直涨，所以超过 1MB 就滚一代（只留一代备份）。
    private static let maxBytes = 1_048_576
    private static var backupPath: String { path + ".1" }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        try? fm.removeItem(atPath: backupPath)
        try? fm.moveItem(atPath: path, toPath: backupPath)
    }

    public static func write(_ message: String) {
        let line = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(message)\n"
        queue.sync {
            rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                    defer { try? fh.close() }
                    fh.seekToEndOfFile()
                    fh.write(data)
                } else {
                    try? line.write(toFile: path, atomically: false, encoding: .utf8)
                }
            }
        }
        NSLog("DDLShot[hotkey]: %@", message)
    }

    /// 追加一行「最近发生过什么」，方便回看
    public static func trace(_ message: String) {
        write(message)
    }
}

// MARK: - 组合键

public struct HotKeyCombo: Equatable {
    public var keyCode: UInt32
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool

    public init(keyCode: UInt32, control: Bool = false, option: Bool = false,
                shift: Bool = false, command: Bool = false) {
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    // 常用 ANSI 虚拟键码（已用系统 Unicode 反查验证）
    public enum Key {
        public static let a: UInt32 = 0x00
        public static let s: UInt32 = 0x01
        public static let d: UInt32 = 0x02
        public static let f: UInt32 = 0x03
        public static let h: UInt32 = 0x04
        public static let g: UInt32 = 0x05
        public static let z: UInt32 = 0x06
        public static let x: UInt32 = 0x07
        public static let c: UInt32 = 0x08
        public static let v: UInt32 = 0x09
        public static let b: UInt32 = 0x0B
        public static let q: UInt32 = 0x0C
        public static let w: UInt32 = 0x0D
        public static let e: UInt32 = 0x0E
        public static let r: UInt32 = 0x0F
        public static let y: UInt32 = 0x10
        public static let t: UInt32 = 0x11
        public static let o: UInt32 = 0x1F
        public static let u: UInt32 = 0x20
        public static let i: UInt32 = 0x22
        public static let p: UInt32 = 0x23
        public static let l: UInt32 = 0x25
        public static let j: UInt32 = 0x26
        public static let k: UInt32 = 0x28
        public static let n: UInt32 = 0x2D
        public static let m: UInt32 = 0x2E
    }

    /// 默认 ⌃⌥D
    public static let `default` = HotKeyCombo(keyCode: Key.d, control: true, option: true)

    /// Carbon 的修饰键位掩码
    public var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if command { m |= UInt32(DDLHotKeyModifierCommand) }
        if shift { m |= UInt32(DDLHotKeyModifierShift) }
        if option { m |= UInt32(DDLHotKeyModifierOption) }
        if control { m |= UInt32(DDLHotKeyModifierControl) }
        return m
    }

    /// 显示用符号，例如 ⌃⌥D
    public var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + HotKeyCombo.name(for: keyCode)
    }

    /// 配置文件写法，例如 "ctrl+alt+d"
    public var configString: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        parts.append(HotKeyCombo.name(for: keyCode).lowercased())
        return parts.joined(separator: "+")
    }

    /// 解析 "ctrl+alt+d" 这类写法
    public static func parse(_ raw: String) -> HotKeyCombo? {
        let parts = raw.lowercased()
            .replacingOccurrences(of: "⌃", with: "ctrl+")
            .replacingOccurrences(of: "⌥", with: "alt+")
            .replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = parts.last else { return nil }
        guard let code = code(for: last) else { return nil }
        var c = HotKeyCombo(keyCode: code)
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": c.control = true
            case "alt", "option": c.option = true
            case "shift": c.shift = true
            case "cmd", "command", "super", "meta": c.command = true
            default: return nil
            }
        }
        return c
    }

    /// 键码 → 字符名
    public static func name(for code: UInt32) -> String {
        let table: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z",
            0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E",
            0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
            0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8",
            0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
            0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
            0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x31: "Space", 0x35: "Esc",
            0x7A: "F1", 0x78: "F2", 0x63: "F3",
            0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9",
            0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x24: "Return"
        ]
        return table[code] ?? "Key\(code)"
    }

    /// 字符名 → 键码
    public static func code(for name: String) -> UInt32? {
        let n = name.lowercased()
        let table: [String: UInt32] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06,
            "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E,
            "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23,
            "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
            "8": 0x1C, "9": 0x19, "0": 0x1D,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
            "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
            "space": 0x31, "return": 0x24, "enter": 0x24, "esc": 0x35, "escape": 0x35
        ]
        return table[n]
    }

    /// 是否与某个 NSEvent 精确匹配（修饰键不多不少）
    public func matches(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == keyCode else { return false }
        let f = event.modifierFlags
        return f.contains(.control) == control
            && f.contains(.option) == option
            && f.contains(.shift) == shift
            && f.contains(.command) == command
    }

    /// CGEvent 的修饰键原始掩码（与 Carbon 的掩码不是一回事，定义见 ddlshot_hotkey.h）
    public enum CGMask {
        public static let shift: UInt64     = UInt64(DDLHotKeyMaskShift)
        public static let control: UInt64   = UInt64(DDLHotKeyMaskControl)
        public static let alternate: UInt64 = UInt64(DDLHotKeyMaskAlternate)
        public static let command: UInt64   = UInt64(DDLHotKeyMaskCommand)
    }

    /// 是否与某个 CGEvent 精确匹配（只看四个修饰键的原始掩码）
    public func matches(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode) else { return false }
        let raw = event.flags.rawValue
        let has: (UInt64) -> Bool = { raw & $0 != 0 }
        return has(CGMask.control) == control
            && has(CGMask.alternate) == option
            && has(CGMask.shift) == shift
            && has(CGMask.command) == command
    }

    /// 把一组标志位渲染成人话，用于日志
    public static func describe(_ f: NSEvent.ModifierFlags) -> String {
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        if f.contains(.capsLock) { s += "⇪" }
        if s.isEmpty { s = "（无修饰键）" }
        return s
    }
}

// MARK: - 配置读取

public enum HotKeyConfig {
    public static let defaultConfigPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ddlshot/config.json").path

    /// 从 ~/.config/ddlshot/config.json 的 "hotkey" 字段读组合键
    public static func load(path: String? = nil) -> HotKeyCombo {
        let p = path ?? defaultConfigPath
        guard let data = FileManager.default.contents(atPath: p),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .default }
        if let s = raw["hotkey"] as? String { return HotKeyCombo.parse(s) ?? .default }
        if let h = raw["hotkey"] as? [String: Any], let s = h["keys"] as? String {
            return HotKeyCombo.parse(s) ?? .default
        }
        return .default
    }
}

// MARK: - 热键管理器

// 注意：只在主线程使用（AppKit 的事件监控与定时器都要求主线程）。
public final class HotKeyManager {
    public static let shared = HotKeyManager()

    /// 触发回调，参数是来源描述
    public var onFire: ((String) -> Void)?

    private var carbonRef: DDLHotKeyRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var trustTimer: Timer?
    private(set) public var combo: HotKeyCombo = .default
    /// Carbon 注册返回的 OSStatus（0 = 成功）
    public private(set) var carbonStatus: Int32 = -1
    /// 辅助功能监听是否已装上
    public private(set) var accessibilityActive = false
    /// CGEventTap 是否已装上
    public private(set) var eventTapActive = false
    /// 最近一次触发来自哪条通道
    public private(set) var lastSource: String?

    private init() {}

    // MARK: 启动

    public func start(combo: HotKeyCombo) {
        self.combo = combo
        HotKeyLog.write("=== DDLShot 热键启动 ===")
        HotKeyLog.write("组合键 = \(combo.display)  keyCode=0x\(String(format: "%02X", combo.keyCode))  配置串=\(combo.configString)")
        carbonStatus = registerCarbon(combo)
        if accessibilityActive { removeAccessibilityMonitor() }
        installAccessibilityMonitorIfTrusted()
        installEventTapIfTrusted()
        startTrustPolling()
        HotKeyLog.write("启动完成：\(statusText)")
    }

    /// 注册 Carbon 热键。返回 OSStatus，0 表示成功。
    @discardableResult
    public func registerCarbon(_ combo: HotKeyCombo) -> Int32 {
        if let r = carbonRef { UnregisterEventHotKey(r); carbonRef = nil }
        var ref: DDLHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.carbonModifiers,
                                         DDLHotKeyID(signature: 0x44444C53, id: 1),
                                         carbonCallback, nil, &ref)
        carbonRef = ref
        carbonStatus = status
        // 运行时自检：把键码翻译成字符打出来，键码写错时一眼能看出来
        let ch = HotKeyManager.character(of: combo.keyCode) ?? "?"
        HotKeyLog.write("Carbon 注册：\(combo.display) keyCode=0x\(String(format: "%02X", combo.keyCode)) 字符「\(ch)」 status=\(status) ref=\(ref == nil ? "nil" : "ok")")
        return status
    }

    /// 合成一个 keyDown，问系统它是哪个字符（用来验证键码没写错）
    static func character(of keyCode: UInt32) -> String? {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) else { return nil }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// 触发处理
    public func fire(source: String) {
        lastSource = source
        HotKeyLog.write("🔥 触发：\(source)  组合键=\(combo.display)")
        onFire?(source)
    }

    // MARK: 辅助功能通道

    /// 系统是否已授予「辅助功能」权限
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的辅助功能授权提示
    public func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func startTrustPolling() {
        trustTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.installAccessibilityMonitorIfTrusted() }
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t
    }

    private func installAccessibilityMonitorIfTrusted() {
        guard globalMonitor == nil, accessibilityGranted else { return }
        let c = combo
        // 全局监听：App 不是前台时生效
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            HotKeyManager.logKeyEvent("全局监听", event)
            guard c.matches(event) else { return }
            DispatchQueue.main.async { HotKeyManager.shared.fire(source: "辅助功能·全局监听") }
        }
        // 本地监听：App 自己是前台时生效（全局监听此时收不到）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            HotKeyManager.logKeyEvent("本地监听", event)
            if c.matches(event) {
                DispatchQueue.main.async { HotKeyManager.shared.fire(source: "辅助功能·本地监听") }
            }
            return event
        }
        accessibilityActive = (globalMonitor != nil)
        HotKeyLog.write("辅助功能监听已安装：全局=\(globalMonitor != nil) 本地=\(localMonitor != nil)")
    }

    private func removeAccessibilityMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        accessibilityActive = false
    }

    /// 只记录「带修饰键的」或「正好是我们目标键」的按键，避免日志被普通打字刷屏
    private static func logKeyEvent(_ channel: String, _ event: NSEvent) {
        let f = event.modifierFlags
        let interesting = f.contains(.control) || f.contains(.option) || f.contains(.command)
            || UInt32(event.keyCode) == HotKeyManager.shared.combo.keyCode
        guard interesting else { return }
        let ch = HotKeyManager.character(of: UInt32(event.keyCode)) ?? "?"
        HotKeyLog.write("按键到达[\(channel)]：keyCode=0x\(String(format: "%02X", UInt32(event.keyCode))) 字符「\(ch)」 修饰键=\(HotKeyCombo.describe(f))")
    }

    // MARK: CGEventTap 通道（最可靠）

    /// 装一个 session 级事件 tap。需要「辅助功能」或「输入监控」权限。
    private func installEventTapIfTrusted() {
        guard eventTap == nil, accessibilityGranted else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .keyDown {
                HotKeyManager.logCGEvent(event)
                if HotKeyManager.shared.combo.matches(event) {
                    DispatchQueue.main.async { HotKeyManager.shared.fire(source: "CGEventTap") }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: nil) else {
            HotKeyLog.write("CGEventTap 创建失败（通常是缺「辅助功能」或「输入监控」权限）")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = src
        eventTapActive = true
        HotKeyLog.write("CGEventTap 已安装（session 级，监听 keyDown）")
    }

    private static func logCGEvent(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let raw = event.flags.rawValue
        let ctrl = raw & HotKeyCombo.CGMask.control != 0
        let alt = raw & HotKeyCombo.CGMask.alternate != 0
        let sh = raw & HotKeyCombo.CGMask.shift != 0
        let cmd = raw & HotKeyCombo.CGMask.command != 0
        let interesting = ctrl || alt || cmd || UInt32(code) == HotKeyManager.shared.combo.keyCode
        guard interesting else { return }
        var s = ""
        if ctrl { s += "⌃" }
        if alt { s += "⌥" }
        if sh { s += "⇧" }
        if cmd { s += "⌘" }
        if s.isEmpty { s = "（无修饰键）" }
        let ch = HotKeyManager.character(of: UInt32(code)) ?? "?"
        HotKeyLog.write("按键到达[CGEventTap]：keyCode=0x\(String(format: "%02X", UInt32(code))) 字符「\(ch)」 修饰键=\(s)")
    }

    // MARK: 状态描述

    public var statusText: String {
        var parts: [String] = []
        parts.append(carbonStatus == 0 ? "Carbon 已注册" : "Carbon 注册失败(\(carbonStatus))")
        parts.append(accessibilityActive ? "辅助功能监听已启用" : "辅助功能未授权")
        parts.append(eventTapActive ? "事件 tap 已启用" : "事件 tap 未启用")
        return parts.joined(separator: " · ")
    }
}

/// Carbon 回调必须是**不捕获上下文**的 C 函数指针，
/// 所以这里走全局单例 + 主线程跳转，而不是直接闭包捕获 self。
private let carbonCallback: DDLHotKeyProc = { _, _, _ in
    DispatchQueue.main.async {
        HotKeyManager.shared.fire(source: "Carbon 热键")
    }
    return DDLStatus(0)
}
