// Tools/make_icon.swift — 生成 DDLShot 的 App 图标（.icns）
//
// 用 SF Symbols 手绘，理由：
//   · 不依赖网络、不依赖任何二进制素材，仓库里只有这段源码，clone 下来就能复现
//   · SF Symbols 是矢量，**按每个尺寸原生重画**（而不是从 1024 缩下来），
//     所以 16px 的菜单栏尺寸也是锐的，不会糊成一团
//   · 视觉语言和系统一致，符合「原生 macOS 小工具」的定位
//
// 产出：
//   Resources/AppIcon.icns
//
// 用法：
//   swiftc -O Tools/make_icon.swift -o build/make_icon && ./build/make_icon <输出目录>
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources"
let outICNS = (outDir as NSString).appendingPathComponent("AppIcon.icns")

/// 取一个指定颜色（可多色）的 SF Symbol
func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, colors: [NSColor]) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        FileHandle.standardError.write("⚠️ SF Symbol 「\(name)」不存在\n".data(using: .utf8)!)
        return nil
    }
    let sized = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    let palette = NSImage.SymbolConfiguration(paletteColors: colors)
    return sized?.withSymbolConfiguration(palette)
}

/// 按给定边长（点）原生渲染一张图标
/// - Parameters:
///   - size: 画布边长（点）
///   - includeBadge: 是否画右下角绿色对勾徽章（小尺寸会糊，16px 用不到）
///   - bold: 笔画加粗（小尺寸必须加粗才看得清）
func renderArtwork(size: CGFloat, includeBadge: Bool, bold: Bool) -> NSImage {
    let weight: NSFont.Weight = bold ? .bold : .semibold
    let inset = size * 0.098
    let side = size - inset * 2
    let canvas = NSImage(size: NSSize(width: size, height: size))
    canvas.lockFocus()

    // 背景：macOS 圆角方形 + 对角渐变
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
                          xRadius: side * 0.2237, yRadius: side * 0.2237)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.36, blue: 0.98, alpha: 1.0),  // 靛蓝
        NSColor(srgbRed: 0.16, green: 0.72, blue: 0.98, alpha: 1.0)   // 青
    ])!
    gradient.draw(in: bg, angle: -60)

    // 顶部内高光，让图标有一点立体感
    NSGraphicsContext.current?.saveGraphicsState()
    bg.addClip()
    let gloss = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.24),
        NSColor(white: 1.0, alpha: 0.0)
    ])!
    gloss.draw(in: NSRect(x: inset, y: inset + side * 0.40, width: side, height: side * 0.60), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // 主体：取景框（= 截图）
    let glyphScale: CGFloat = bold ? 0.74 : 0.56
    if bold {
        // 小尺寸（16px）：SF Symbol 的四个细角括号在这个尺寸必然糊，
        // 改成**手绘四个粗角标**（经典的取景框），既清晰又有语义。
        let g = side * 0.68
        let arm = g * 0.36
        let lineW = max(size * 0.085, 1.6)
        let r = NSRect(x: size * 0.5 - g * 0.5, y: size * 0.5 - g * 0.5, width: g, height: g)
        NSColor.white.setStroke()

        let corners: [(NSPoint, NSPoint, NSPoint)] = [
            // (起点, 拐角, 终点)
            (NSPoint(x: r.minX, y: r.minY + arm), NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.minX + arm, y: r.minY)),
            (NSPoint(x: r.maxX - arm, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX, y: r.minY + arm)),
            (NSPoint(x: r.maxX, y: r.maxY - arm), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.maxX - arm, y: r.maxY)),
            (NSPoint(x: r.minX + arm, y: r.maxY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY - arm))
        ]
        for (from, corner, to) in corners {
            let p = NSBezierPath()
            p.move(to: from)
            p.line(to: corner)
            p.line(to: to)
            p.lineWidth = lineW
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
    } else if let viewfinder = symbol("viewfinder", pointSize: side * glyphScale, weight: weight, colors: [.white]) {
        let g = side * glyphScale
        viewfinder.draw(in: NSRect(x: size * 0.5 - g * 0.5 - side * 0.02,
                                   y: size * 0.5 - g * 0.5 + (includeBadge ? side * 0.10 : 0),
                                   width: g, height: g))
    }

    // 右下角：绿色对勾徽章（= 已写进提醒事项）
    if includeBadge {
        let badgeSide = side * 0.40
        if let badge = symbol("checkmark.circle.fill", pointSize: badgeSide, weight: weight,
                              colors: [NSColor(srgbRed: 0.13, green: 0.78, blue: 0.42, alpha: 1.0), .white]) {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = side * 0.030
            shadow.shadowOffset = NSSize(width: 0, height: -side * 0.010)
            shadow.shadowColor = NSColor(white: 0.0, alpha: 0.30)
            shadow.set()
            badge.draw(in: NSRect(x: size - inset - badgeSide + side * 0.055,
                                  y: inset + side * 0.055,
                                  width: badgeSide, height: badgeSide))
        }
    }

    canvas.unlockFocus()
    return canvas
}

// ── 导出各尺寸 PNG → iconset → iconutil → .icns ─────────
let iconset = NSTemporaryDirectory() + "DDLShot.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

/// (图标槽位名, 像素边长) —— 每个尺寸都原生重画，16px 用简化版（不要徽章）+ 加粗笔画
let slots: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, px) in slots {
    let isTiny = px <= 32
    let art = renderArtwork(size: CGFloat(px), includeBadge: !isTiny, bold: isTiny)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { continue }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    art.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
             from: NSRect(origin: .zero, size: NSSize(width: px, height: px)),
             operation: .copy, fraction: 1.0)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
    }
}

try? FileManager.default.removeItem(atPath: outICNS)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset, "-o", outICNS]
try? proc.run()
proc.waitUntilExit()

if FileManager.default.fileExists(atPath: outICNS) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: outICNS)
    let size = (attrs?[.size] as? Int) ?? 0
    print("图标已生成：\(outICNS)  (\(size) 字节)")
} else {
    print("图标生成失败：iconutil 没能产出 \(outICNS)")
    exit(1)
}
