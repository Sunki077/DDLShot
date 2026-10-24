// CropMath.swift — 截图裁剪的坐标换算（纯函数，便于单测）
//
// 坐标系约定（这是最容易搞错的地方，单独拎出来）：
//   · AppKit 全局屏幕坐标：原点在主屏左下角，y 向上，与 NSScreen.frame 一致
//   · CGImage 像素坐标：原点在图像左上角，y 向下
// 两者之间除了缩放比，还要把上下翻转。
import CoreGraphics

enum CropMath {

    /// 把「用户在屏幕框里选出的矩形」换算成「图像里要裁掉的像素矩形」
    ///
    /// - Parameters:
    ///   - rect: 选区，AppKit 全局坐标，points
    ///   - screenFrame: 该显示器在 AppKit 全局坐标里的位置，points
    ///   - imagePixelWidth: 截下来的图像像素宽
    ///   - imagePixelHeight: 截下来的图像像素高
    /// - Returns: 图像像素坐标下的矩形，原点在左上角
    static func pixelRect(for rect: CGRect,
                          screenFrame: CGRect,
                          imagePixelWidth: Int,
                          imagePixelHeight: Int) -> CGRect {
        let kx = CGFloat(imagePixelWidth) / screenFrame.width
        let ky = CGFloat(imagePixelHeight) / screenFrame.height
        return CGRect(x: (rect.minX - screenFrame.minX) * kx,
                      y: CGFloat(imagePixelHeight) - (rect.maxY - screenFrame.minY) * ky,
                      width: rect.width * kx,
                      height: rect.height * ky)
    }
}
