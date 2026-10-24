// Tools/test_crop.swift — CropMath 坐标换算单测
//
// 框选裁剪最容易出的错是把 AppKit 坐标（左下原点）和图像像素坐标（左上原点）搞混，
// 结果裁出来的位置上下颠倒。这里把换算单独拎成纯函数，用几组典型屏幕布局验证。
//
// 编译：swiftc Sources/CropMath.swift Tools/test_crop.swift -o /tmp/test_crop
import CoreGraphics

var passed = 0
var failed = 0

func check(_ name: String, _ got: CGRect, _ want: CGRect) {
    let ok = abs(got.origin.x - want.origin.x) < 0.001
        && abs(got.origin.y - want.origin.y) < 0.001
        && abs(got.width - want.width) < 0.001
        && abs(got.height - want.height) < 0.001
    if ok {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name)")
        print("      期望 \(want)")
        print("      实际 \(got)")
    }
}

print("CropMath 坐标换算自检")

// 1. 主屏，2 倍 Retina
let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
//    选区顶边在 AppKit y=600 → 距屏幕顶部 480pt → 像素 960
check("主屏 2x：任意选区",
      CropMath.pixelRect(for: CGRect(x: 100, y: 200, width: 300, height: 400),
                         screenFrame: main, imagePixelWidth: 3840, imagePixelHeight: 2160),
      CGRect(x: 200, y: 960, width: 600, height: 800))

// 2. 整个屏幕
check("主屏 2x：整屏",
      CropMath.pixelRect(for: main,
                         screenFrame: main, imagePixelWidth: 3840, imagePixelHeight: 2160),
      CGRect(x: 0, y: 0, width: 3840, height: 2160))

// 3. 右侧副屏（origin.x 非零），2x
let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
//    选区 (2020,100) 相对副屏是 (100,100)，顶边相对 300 → 像素 2160-600
check("右侧副屏 2x：任意选区",
      CropMath.pixelRect(for: CGRect(x: 2020, y: 100, width: 100, height: 200),
                         screenFrame: right, imagePixelWidth: 3840, imagePixelHeight: 2160),
      CGRect(x: 200, y: 1560, width: 200, height: 400))

// 4. 上方副屏（origin.y 非零），1x
let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
//    选区 (100, 1180) 相对屏幕是 y=100，顶边相对 200 → 像素 1080-200
check("上方副屏 1x：任意选区",
      CropMath.pixelRect(for: CGRect(x: 100, y: 1180, width: 200, height: 100),
                         screenFrame: above, imagePixelWidth: 1920, imagePixelHeight: 1080),
      CGRect(x: 100, y: 880, width: 200, height: 100))

// 5. 屏幕在主屏上方 200pt 的布局，2x
let shifted = CGRect(x: 0, y: 200, width: 1920, height: 1080)
//    选区 (0,300,100,100) 相对 y=100，顶边相对 200 → 像素 2160-400
check("纵向偏移的屏幕 2x：任意选区",
      CropMath.pixelRect(for: CGRect(x: 0, y: 300, width: 100, height: 100),
                         screenFrame: shifted, imagePixelWidth: 3840, imagePixelHeight: 2160),
      CGRect(x: 0, y: 1760, width: 200, height: 200))

print("\n通过 \(passed)，失败 \(failed)")
if failed > 0 { exit(1) }
