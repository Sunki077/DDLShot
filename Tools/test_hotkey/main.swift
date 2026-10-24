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

print("\n通过 \(passed)，失败 \(failed)")
exit(failed == 0 ? 0 : 1)
