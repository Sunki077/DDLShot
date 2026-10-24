// make_chat.swift — 生成一张「微信群聊」风格的样例截图，用来对比本地规则引擎 vs 大模型
import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Msg {
    let who: String
    let text: String
    let isMe: Bool
    let time: String
}

let messages: [Msg] = [
    Msg(who: "李老师", text: "各位同学注意下这学期的安排", isMe: false, time: "10:02"),
    Msg(who: "李老师", text: "下周三之前把实验报告交到教务系统", isMe: false, time: "10:02"),
    Msg(who: "李老师", text: "格式不对的要退回来重写，务必认真", isMe: false, time: "10:03"),
    Msg(who: "我", text: "老师，实验报告的截止时间具体是几点？", isMe: true, time: "10:05"),
    Msg(who: "李老师", text: "11月5日 18:00 截止，系统 11月6日 关", isMe: false, time: "10:06"),
    Msg(who: "王同学", text: "顺便说下 校赛报名 28号 就要关了", isMe: false, time: "10:11"),
    Msg(who: "王同学", text: "去年就是没赶上，错过了好几个奖项", isMe: false, time: "10:11"),
    Msg(who: "我", text: "好的我记下了", isMe: true, time: "10:12"),
    Msg(who: "张同学", text: "晚上食堂三楼新开了，加个鸡腿", isMe: false, time: "10:20"),
]

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/chat_sample.png"
let W = 720
let bubbleMaxW = 460.0
let font = CTFontCreateWithName("PingFang SC" as CFString, 17, nil)
let nameFont = CTFontCreateWithName("PingFang SC" as CFString, 12, nil)
let timeFont = CTFontCreateWithName("PingFang SC" as CFString, 11, nil)

func makeAttr(_ s: String, _ f: CTFont, _ color: CGColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
}

let white = CGColor(gray: 1, alpha: 1)
let black = CGColor(gray: 0.12, alpha: 1)
let gray = CGColor(gray: 0.45, alpha: 1)
let green = CGColor(red: 0.60, green: 0.85, blue: 0.42, alpha: 1)

// 先量高度
struct Laid { let msg: Msg; let lines: [NSAttributedString]; let w: CGFloat; let h: CGFloat }
var laid: [Laid] = []
var totalH: CGFloat = 60
for m in messages {
    let attr = makeAttr(m.text, font, black)
    let framesetter = CTFramesetterCreateWithAttributedString(attr)
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: bubbleMaxW, height: 10000), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var lineW: CGFloat = 0
    for ln in lines {
        let w = CTLineGetTypographicBounds(ln, nil, nil, nil)
        lineW = max(lineW, CGFloat(w))
    }
    let h = CGFloat(lines.count) * 24 + 22
    laid.append(Laid(msg: m, lines: [attr], w: min(lineW + 26, bubbleMaxW), h: h))
    totalH += h + 14
}
let H = Int(totalH + 40)

guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
// 背景
ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
// 顶部标题栏
ctx.setFillColor(CGColor(gray: 0.22, alpha: 1))
ctx.fill(CGRect(x: 0, y: CGFloat(H - 48), width: CGFloat(W), height: 48))
ctx.textPosition = CGPoint(x: 24, y: CGFloat(H - 32))
CTLineDraw(CTLineCreateWithAttributedString(makeAttr("产品设计 2026 秋季班（86 人）", nameFont, white)), ctx)

var y = CGFloat(H) - 70
for item in laid {
    let m = item.msg
    let isMe = m.isMe
    let bx: CGFloat = isMe ? CGFloat(W) - item.w - 16 : 16
    let by = y - item.h
    // 气泡
    ctx.setFillColor(isMe ? green : white)
    let r: CGFloat = 8
    let rect = CGRect(x: bx, y: by, width: item.w, height: item.h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()
    // 昵称（只有别人发才显示）
    if !isMe {
        ctx.textPosition = CGPoint(x: bx + 2, y: by + item.h - 14)
        CTLineDraw(CTLineCreateWithAttributedString(makeAttr(m.who, nameFont, gray)), ctx)
    }
    // 正文
    let body = makeAttr(m.text, font, black)
    let fs = CTFramesetterCreateWithAttributedString(body)
    let path = CGPath(rect: CGRect(x: bx + 13, y: by + 10, width: item.w - 26, height: item.h - 20), transform: nil)
    let frame = CTFramesetterCreateFrame(fs, CFRange(), path, nil)
    ctx.textPosition = CGPoint(x: bx + 13, y: by + item.h - 26)
    CTFrameDraw(frame, ctx)
    // 时间
    ctx.textPosition = CGPoint(x: bx + 13, y: by + 2)
    CTLineDraw(CTLineCreateWithAttributedString(makeAttr(m.time, timeFont, gray)), ctx)
    y = by - 10
}

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("已生成 \(outPath) (\(W)x\(H))")
