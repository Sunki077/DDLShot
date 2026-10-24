// RegionSelector.swift — 进程内手动框选
//
// 以前用 `/usr/sbin/screencapture -i` 弹系统的框选框。那个子进程会让 TCC 反复弹
// 「想要录制此电脑的屏幕和音频」的授权窗（间接请求，客户端身份解析不出来），
// 所以改成自己画：先截一张全屏图铺在屏幕上当背景，用户在上面拖拽选区，再把选区裁出来。
//
// 坐标系约定：
//   · 全局屏幕坐标用 AppKit 约定（原点在主屏左下角），与 NSScreen.frame 一致
//   · NSImage 坐标原点在左下；CGImage 像素坐标原点在左上 —— 两者互转时要注意翻面
import AppKit

enum RegionSelector {

    /// 在 screen 上铺开 background，让用户拖出一个选区。
    /// 返回全局屏幕坐标（AppKit 坐标系）的选区矩形；用户按 Esc 取消则返回 nil。
    @MainActor
    static func select(screen: NSScreen, background: NSImage) async -> CGRect? {
        await withCheckedContinuation { (cont: CheckedContinuation<CGRect?, Never>) in
            MainActor.assumeIsolated {
                let panel = Panel(screen: screen, background: background)
                panel.onFinish = { rect in cont.resume(returning: rect) }
                panel.begin()
            }
        }
    }
}

// MARK: - 选区面板

final class Panel: NSWindow {
    private let canvas: Canvas
    private var didFinish = false
    var onFinish: ((CGRect?) -> Void)?

    init(screen: NSScreen, background: NSImage) {
        canvas = Canvas(frame: CGRect(origin: .zero, size: screen.frame.size))
        canvas.image = background
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver          // 1000，盖在所有普通窗口之上
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        contentView = canvas
        canvas.panel = self
    }

    func begin() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(canvas)
    }

    /// 结束选择。rect 为全局屏幕坐标（AppKit 坐标系）；nil 表示用户取消。
    func finish(_ rect: CGRect?) {
        guard !didFinish else { return }
        didFinish = true
        orderOut(nil)
        onFinish?(rect)
    }
}

// MARK: - 画布

final class Canvas: NSView {
    var image: NSImage = NSImage(size: .zero)
    weak var panel: Panel?

    private var anchor = NSPoint.zero
    private var cursor = NSPoint.zero
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }

    private var selection: CGRect {
        CGRect(x: min(anchor.x, cursor.x),
               y: min(anchor.y, cursor.y),
               width: abs(cursor.x - anchor.x),
               height: abs(cursor.y - anchor.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        // 背景：把刚截到的全屏图铺满
        if image.size.width > 1 {
            image.draw(in: b, from: .zero, operation: .copy, fraction: 1.0)
        } else {
            NSColor.black.setFill()
            b.fill()
        }

        let sel = selection
        let hasSel = sel.width > 2 && sel.height > 2

        // 选区外压暗（even-odd 挖洞）
        let shade = NSBezierPath(rect: b)
        if hasSel { shade.appendRect(sel) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(hasSel ? 0.45 : 0.15).setFill()
        shade.fill()

        if hasSel {
            let p = NSBezierPath(rect: sel)
            p.lineWidth = 2
            NSColor.systemBlue.setStroke()
            p.stroke()
        }

        // 提示文字
        let hint = "拖动选择区域 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: hint, attributes: attrs)
        let ts = s.size()
        let box = NSRect(x: (b.width - ts.width) / 2,
                         y: b.height - ts.height - 44,
                         width: ts.width, height: ts.height)
        let bg = NSBezierPath(roundedRect: box.insetBy(dx: -12, dy: -7), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.6).setFill()
        bg.fill()
        s.draw(at: NSPoint(x: box.minX, y: box.minY))
    }

    // MARK: 拖拽

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        cursor = anchor
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true

        let sel = selection
        guard sel.width > 6, sel.height > 6 else {
            panel?.finish(nil)          // 误点，视为取消
            return
        }
        panel?.finish(globalRect(sel))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {         // Esc
            panel?.finish(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// view 坐标（左下原点）→ 全局屏幕坐标（AppKit 坐标系）
    private func globalRect(_ sel: CGRect) -> CGRect {
        guard let w = window else { return sel }
        let p0 = w.convertPoint(toScreen: convert(NSPoint(x: sel.minX, y: sel.minY), to: nil))
        let p1 = w.convertPoint(toScreen: convert(NSPoint(x: sel.maxX, y: sel.maxY), to: nil))
        return CGRect(x: min(p0.x, p1.x),
                      y: min(p0.y, p1.y),
                      width: abs(p1.x - p0.x),
                      height: abs(p1.y - p0.y))
    }
}
