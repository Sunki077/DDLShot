// HotKey.swift — 全局热键（双通道）
//
// 为什么要有两条通道：
//   ① Carbon RegisterEventHotKey —— 不需要任何系统权限，但属于 1990 年代的 API。
//   ② NSEvent.addGlobalMonitorForEvents —— 现代 API，macOS 26 上可靠，
//      但需要「辅助功能」授权。
// 两条路都指向同一个触发处理；辅助功能没授权时自动退回 Carbon。
//
// 键码约定（ANSI / 美国键盘布局）：
//   系统里 kVK_ANSI_D == 0x02，**不是 0x27**（0x27 是单引号 '）。
//   这套码可以用系统的 Unicode 转换反查验证，见 Tools/test_hotkey/main.swift。
import AppKit
import ApplicationServices
import CShim

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
    private var trustTimer: Timer?
    private(set) public var combo: HotKeyCombo = .default
    /// Carbon 注册返回的 OSStatus（0 = 成功）
    public private(set) var carbonStatus: Int32 = -1
    /// 辅助功能监听是否已装上
    public private(set) var accessibilityActive = false

    private init() {}

    // MARK: 启动

    public func start(combo: HotKeyCombo) {
        self.combo = combo
        carbonStatus = registerCarbon(combo)
        if accessibilityActive { removeAccessibilityMonitor() }
        installAccessibilityMonitorIfTrusted()
        startTrustPolling()
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
        NSLog("DDLShot: 注册热键 \(combo.display) 键码=0x\(String(format: "%02X", combo.keyCode)) → 字符「\(ch)」 status=\(status)")
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
            guard c.matches(event) else { return }
            DispatchQueue.main.async { HotKeyManager.shared.fire(source: "辅助功能监听") }
        }
        // 本地监听：App 自己是前台时生效（全局监听此时收不到）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if c.matches(event) {
                DispatchQueue.main.async { HotKeyManager.shared.fire(source: "辅助功能监听") }
            }
            return event
        }
        accessibilityActive = (globalMonitor != nil)
    }

    private func removeAccessibilityMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        accessibilityActive = false
    }

    // MARK: 状态描述

    public var statusText: String {
        var parts: [String] = []
        parts.append(carbonStatus == 0 ? "Carbon 已注册" : "Carbon 注册失败(\(carbonStatus))")
        parts.append(accessibilityActive ? "辅助功能监听已启用" : "辅助功能未授权")
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
