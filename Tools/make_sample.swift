// make_sample.swift — 生成一张含 DDL 文本的测试图片（CoreText 渲染，不依赖窗口服务）
// 用法: swiftc -O make_sample.swift -o make_sample && ./make_sample <输出路径>
import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sampleText = """
项目截止时间

1. 提交实验报告 — 截止 11月5日 18:00
2. 报名参加校赛 — 10月28日 前
3. 交本周周报 — 明天下午3点
4. 回复客户邮件 — 本周五 前
5. 预约导师面谈 — 下周三 上午10点
6. Deadline: Nov 5 submit the final manuscript
"""

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/sample_ddl.png"

let font = CTFontCreateWithName("PingFang SC" as CFString, 28, nil)
let attrs: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
]
let attributed = NSAttributedString(string: sampleText, attributes: attrs)
let framesetter = CTFramesetterCreateWithAttributedString(attributed)

let width = 900
let height = 520
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("无法创建位图上下文\n".utf8))
    exit(1)
}
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
ctx.textPosition = CGPoint(x: 30, y: height - 50)
CTFrameDraw(frame, ctx)

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("无法生成 PNG\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
if !CGImageDestinationFinalize(dest) {
    FileHandle.standardError.write(Data("PNG 写入失败\n".utf8))
    exit(1)
}
print("已生成 \(outPath) (\(width)x\(height))")
