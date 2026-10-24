// Tools/test_hotkey/main.swift — 全局热键键码自检
//
// 背景：DDLShot 曾经把 kVK_ANSI_D 写成了 0x27（那是单引号 '），
// 结果注册上去的是 ⌃⌥'，按 ⌃⌥D 永远没反应。
// 这个自检用系统的 Unicode 转换反查每个键码到底是哪个字符，键码写错就立刻报错。
import AppKit
import CShim

/// 合成一个 keyDown，问系统它是哪个字符
func character(of keyCode: UInt32) -> String? {
    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) else { return nil }
    var length = 0
    var chars = [UniChar](repeating: 0, count: 8)
    e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return nil }
    return String(utf16CodeUnits: chars, count: length)
}

var passed = 0
var failed = 0

func check(_ name: String, _ code: UInt32, _ expect: String) {
    let got = character(of: code) ?? "<nil>"
    if got == expect {
        passed += 1
        print("通过  \(name) = 0x\(String(format: "%02X", code)) → \(got)")
    } else {
        failed += 1
        print("失败  \(name) = 0x\(String(format: "%02X", code)) → 实际「\(got)」，期望「\(expect)」")
    }
}

// 主键：D 必须是 0x02（0x27 是单引号）
check("D", DDLHotKeyCodeD, "d")
check("A", DDLHotKeyCodeA, "a")
check("S", DDLHotKeyCodeS, "s")
check("F", DDLHotKeyCodeF, "f")
check("G", DDLHotKeyCodeG, "g")
check("H", DDLHotKeyCodeH, "h")
check("J", DDLHotKeyCodeJ, "j")
check("K", DDLHotKeyCodeK, "k")
check("L", DDLHotKeyCodeL, "l")
check("P", DDLHotKeyCodeP, "p")
check("Q", DDLHotKeyCodeQ, "q")
check("R", DDLHotKeyCodeR, "r")
check("T", DDLHotKeyCodeT, "t")
check("U", DDLHotKeyCodeU, "u")
check("V", DDLHotKeyCodeV, "v")
check("W", DDLHotKeyCodeW, "w")
check("X", DDLHotKeyCodeX, "x")
check("Y", DDLHotKeyCodeY, "y")
check("Z", DDLHotKeyCodeZ, "z")

// 修饰键位
let modifierOK: Bool = {
    let expect: [(UInt32, UInt32)] = [
        (DDLHotKeyModifierControl, 0x1000),
        (DDLHotKeyModifierOption, 0x0800),
        (DDLHotKeyModifierShift, 0x0200),
        (DDLHotKeyModifierCommand, 0x0100)
    ]
    return expect.allSatisfy { $0.0 == $0.1 }
}()
if modifierOK {
    passed += 1
    print("通过  修饰键位 ctrl=0x1000 alt=0x0800 shift=0x0200 cmd=0x0100")
} else {
    failed += 1
    print("失败  修饰键位不对")
}

// 0x27 必须确实是单引号（防止有人又把 D 写成 0x27）
check("'（0x27 应当是单引号，不是 D）", 0x27, "'")

// ── CGEvent 的原始修饰键掩码 ──────────────────────────────
// 这组掩码和 Carbon 的修饰键位**不是一回事**，混用会导致热键永远匹配不上。
let cgMaskOK: Bool = {
    let expect: [(UInt32, UInt32)] = [
        (DDLHotKeyMaskShift, 0x00020000),
        (DDLHotKeyMaskControl, 0x00040000),
        (DDLHotKeyMaskAlternate, 0x00080000),
        (DDLHotKeyMaskCommand, 0x00100000)
    ]
    return expect.allSatisfy { $0.0 == $0.1 }
}()
if cgMaskOK {
    passed += 1
    print("通过  CGEvent 掩码 shift=0x20000 ctrl=0x40000 alt=0x80000 cmd=0x100000")
} else {
    failed += 1
    print("失败  CGEvent 掩码不对")
}

// ── 组合键匹配逻辑（镜像 HotKey.swift 的实现）──────────────
// 模拟 CGEventTap 收到一个 ⌃⌥D，验证只有 D 命中、F 不命中。
func matches(_ keyCode: UInt32, _ flags: UInt64) -> Bool {
    let wantCtrl = true, wantAlt = true, wantShift = false, wantCmd = false
    let has: (UInt64) -> Bool = { flags & $0 != 0 }
    return keyCode == DDLHotKeyCodeD
        && has(UInt64(DDLHotKeyMaskControl)) == wantCtrl
        && has(UInt64(DDLHotKeyMaskAlternate)) == wantAlt
        && has(UInt64(DDLHotKeyMaskShift)) == wantShift
        && has(UInt64(DDLHotKeyMaskCommand)) == wantCmd
}

let ctrlAlt = UInt64(DDLHotKeyMaskControl | DDLHotKeyMaskAlternate)
let matchCases: [(String, Bool, Bool)] = [
    ("⌃⌥D 应命中", matches(DDLHotKeyCodeD, ctrlAlt), true),
    ("⌃⌥F 不应命中", matches(DDLHotKeyCodeF, ctrlAlt), false),
    ("⌃⌥D 少按 Option 不应命中", matches(DDLHotKeyCodeD, UInt64(DDLHotKeyMaskControl)), false),
    ("⌃⌥D 少按 Control 不应命中", matches(DDLHotKeyCodeD, UInt64(DDLHotKeyMaskAlternate)), false),
    ("⌃⌥⇧D 多按 Shift 不应命中", matches(DDLHotKeyCodeD, ctrlAlt | UInt64(DDLHotKeyMaskShift)), false)
]
for (name, got, want) in matchCases {
    if got == want {
        passed += 1
        print("通过  组合键匹配：\(name)")
    } else {
        failed += 1
        print("失败  组合键匹配：\(name)（实际 \(got)，期望 \(want)）")
    }
}

print("\n通过 \(passed)，失败 \(failed)")
exit(failed == 0 ? 0 : 1)
