// DDLShotKit — 截屏/文字 → 解析 DDL → 写入 macOS 系统「提醒事项」
// 本地 Vision OCR + 本地日期解析 + EventKit 写入，全程不出本机、不联网。
import Foundation
import AppKit
import Vision
import EventKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - 配置

public struct Config {
    public var listName: String = "DDL"
    public var ocrLanguages: [String] = ["zh-Hans", "en-US"]
    public var defaultHour: Int = 9
    public var defaultMinute: Int = 0
    /// 命中这些词的行优先作为任务名
    public var titleKeywords: [String] = ["截止", "deadline", "ddl", "due", "提交", "交", "完成", "报名",
                                         "汇报", "回复", "答复", "上传", "交付", "考试", "面试", "预约",
                                         "过期", "之前", "前要", "别忘", "记得", "前交"]
    public init() {}
}

// MARK: - 解析结果

public struct ParsedDDL {
    public var title: String = ""
    public var due: Date? = nil
    public var dueText: String = ""
    public var matchedLine: String = ""
    public var notes: String = ""
    public var confidence: String = "low"   // high / medium / low
    public init() {}
}

// MARK: - 日期解析

public enum DateParser {

    /// 以星期一为 0 的星期索引
    private static let cnWeekday: [String: Int] = [
        "一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6
    ]
    private static let enWeekday: [String: Int] = [
        "monday": 0, "mon": 0, "tuesday": 1, "tue": 1, "wednesday": 2, "wed": 2,
        "thursday": 3, "thu": 3, "friday": 4, "fri": 4, "saturday": 5, "sat": 5,
        "sunday": 6, "sun": 6
    ]
    private static let enMonths: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12
    ]

    public struct Hit {
        public var date: Date
        public var text: String
        public var explicitTime: Bool
    }

    // MARK: 工具

    /// 本周星期一的 00:00
    static func weekStart(_ cal: Calendar, _ now: Date) -> Date {
        let cur = cal.component(.weekday, from: now)     // 1=周日 … 7=周六
        let monIdx = (cur + 5) % 7                        // 0=周一 … 6=周日
        let base = cal.startOfDay(for: now)
        // monIdx 同时也是「今天距本周一的天数」
        return cal.date(byAdding: .day, value: -monIdx, to: base) ?? base
    }

    static func format(_ d: Date, cal: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s
        // 行首列表标记（1. / • / ① 等）
        t = t.replacingOccurrences(of: "^[\\s\\d\\.、)）\\-•·○●■▪]+\\s*", with: "", options: .regularExpression)
        // 时间片段：18:00 / 下午3点 / 上午10点
        t = t.replacingOccurrences(of: "\\d{1,2}\\s*[:：]\\s*\\d{2}(?!\\d)", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?:上午|早上|早晨|中午|下午|晚上|傍晚|凌晨)?\\s*\\d{1,2}\\s*[点时](?:\\s*\\d{1,2}\\s*分?)?",
                                   with: " ", options: .regularExpression)
        // 行首前缀标记
        for p in ["截止日期", "截止时间", "最后期限", "截止", "deadline", "due date", "due", "ddl"] {
            if t.lowercased().hasPrefix(p.lowercased()) {
                t = String(t.dropFirst(p.count))
            }
        }
        // 破折号是分隔符；OCR 常把 "—" 认成 "一"，出现在日期标记词前时还原
        t = t.replacingOccurrences(of: "[—–]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "一(?=本周|下周|上周|今天|明天|后天|大后天|截止|日期|\\d{1,2}月)",
                                   with: " ", options: .regularExpression)
        // 行中出现的日期标记词
        for p in ["截止日期", "截止时间", "最后期限", "截止", "deadline"] {
            t = t.replacingOccurrences(of: p, with: " ", options: [.caseInsensitive])
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t·•-—–:：,，.。;；|、"))
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if t.count > 60 { t = String(t.prefix(60)) }
        return t
    }

    /// 移除日期文本，以及紧随其后的截止修饰词（"前" / "之前" / "以前" / "内"）
    static func stripDate(_ line: String, hit: Hit?) -> String {
        guard let hit else { return line }
        let pattern = NSRegularExpression.escapedPattern(for: hit.text) + "\\s*(?:之前|以前|前|内)?"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return line.replacingOccurrences(of: hit.text, with: " ")
        }
        let ns = line as NSString
        return re.stringByReplacingMatches(in: line, options: [],
                                           range: NSRange(location: 0, length: ns.length),
                                           withTemplate: " ")
    }

    static func keywordScore(_ line: String, _ cfg: Config) -> Int {
        let lower = line.lowercased()
        return cfg.titleKeywords.filter { lower.contains($0) }.count
    }

    // MARK: 日期命中

    /// 在一段文本中找出所有日期候选（按出现顺序）
    public static func findHits(in text: String, now: Date = Date(), cal: Calendar = .current) -> [Hit] {
        var hits: [Hit] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let today = cal.startOfDay(for: now)

        /// 取第 idx 个捕获组，未参与匹配时返回 nil
        func cap(_ m: NSTextCheckingResult, _ idx: Int) -> String? {
            guard idx < m.numberOfRanges else { return nil }
            let r = m.range(at: idx)
            if r.location == NSNotFound || r.length == 0 { return nil }
            return ns.substring(with: r)
        }

        func add(_ pattern: String, _ build: (NSTextCheckingResult) -> (Date, Bool)?) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for m in re.matches(in: text, options: [], range: full) {
                if let (d, hasTime) = build(m) {
                    hits.append(Hit(date: d, text: ns.substring(with: m.range), explicitTime: hasTime))
                }
            }
        }

        /// 把「月/日」组合成当年日期；已过则顺延到明年
        func monthDay(_ mo: Int, _ day: Int, _ year: Int?) -> Date? {
            guard (1...12).contains(mo), (1...31).contains(day) else { return nil }
            var comps = DateComponents()
            comps.year = year ?? cal.component(.year, from: now)
            comps.month = mo
            comps.day = day
            comps.hour = 9
            comps.minute = 0
            guard var d = cal.date(from: comps) else { return nil }
            if year == nil, d < today {
                comps.year = (comps.year ?? 0) + 1
                d = cal.date(from: comps) ?? d
            }
            return d
        }

        // ---- 中文：相对日 ----
        add("(大后天|后天|明天|明日|今天|今日|今晚|今早|今晨|明早|明晚|昨晚|昨天)", { m in
            let r = ns.substring(with: m.range)
            var day = 0
            var hour = -1
            switch r {
            case "今天", "今日": day = 0
            case "今晚": day = 0; hour = 20
            case "今早", "今晨": day = 0; hour = 9
            case "明天", "明日": day = 1
            case "明早": day = 1; hour = 9
            case "明晚": day = 1; hour = 20
            case "后天": day = 2
            case "大后天": day = 3
            case "昨天", "昨晚": day = -1
            default: return nil
            }
            let base = cal.startOfDay(for: cal.date(byAdding: .day, value: day, to: now) ?? now)
            let h = hour >= 0 ? hour : 9
            let d = cal.date(bySettingHour: h, minute: 0, second: 0, of: base) ?? base
            return (d, hour >= 0)
        })

        // ---- 中文：本周/下周 + 星期 ----
        add("(下下|下|本|这)?(?:个)?(?:周|星期|礼拜)([一二三四五六日天])", { m in
            guard let wdChar = cap(m, 2), let target = cnWeekday[wdChar] else { return nil }
            let prefix = cap(m, 1) ?? ""
            let ws = weekStart(cal, now)
            var offset = target
            switch prefix {
            case "下": offset = 7 + target
            case "下下": offset = 14 + target
            default:
                // 本周该星期几已经过了 → 顺延到下周
                if target < ((cal.component(.weekday, from: now) + 5) % 7) {
                    offset = 7 + target
                }
            }
            guard let d0 = cal.date(byAdding: .day, value: offset, to: ws) else { return nil }
            let out = cal.date(bySettingHour: 9, minute: 0, second: 0, of: d0) ?? d0
            return (out, false)
        })

        // ---- 中文：X月X日[号] ----
        add("(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*[日号]", { m in
            guard let s1 = cap(m, 1), let s2 = cap(m, 2),
                  let mo = Int(s1), let day = Int(s2) else { return nil }
            guard let d = monthDay(mo, day, nil) else { return nil }
            return (d, false)
        })

        // ---- 数字：YYYY-MM-DD / YYYY年M月D日 ----
        add("(\\d{4})\\s*[-/年]\\s*(\\d{1,2})\\s*[-/月]\\s*(\\d{1,2})\\s*[日号]?", { m in
            guard let s1 = cap(m, 1), let s2 = cap(m, 2), let s3 = cap(m, 3),
                  let y = Int(s1), let mo = Int(s2), let day = Int(s3) else { return nil }
            guard let d = monthDay(mo, day, y) else { return nil }
            return (d, false)
        })

        // ---- 数字：M/D 或 M-D ----
        add("(?<![\\d.])(\\d{1,2})\\s*[/\\-]\\s*(\\d{1,2})(?![\\d.])", { m in
            guard let s1 = cap(m, 1), let s2 = cap(m, 2),
                  let mo = Int(s1), let day = Int(s2) else { return nil }
            guard let d = monthDay(mo, day, nil) else { return nil }
            return (d, false)
        })

        // ---- 英文：today / tomorrow / day after tomorrow ----
        add("(day after tomorrow|tomorrow|today|tonight|tmrw)", { m in
            let r = ns.substring(with: m.range).lowercased()
            var day = 0
            var hour = -1
            switch r {
            case "today": day = 0
            case "tonight": day = 0; hour = 20
            case "tomorrow": day = 1
            case "tmrw": day = 1
            case "day after tomorrow": day = 2
            default: return nil
            }
            let base = cal.startOfDay(for: cal.date(byAdding: .day, value: day, to: now) ?? now)
            let d = cal.date(bySettingHour: hour >= 0 ? hour : 9, minute: 0, second: 0, of: base) ?? base
            return (d, hour >= 0)
        })

        // ---- 英文：Nov 5 / November 5th ----
        add("(?<![A-Za-z])(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)(?![A-Za-z])\\.?\\s+(\\d{1,2})", { m in
            guard let s1 = cap(m, 1), let s2 = cap(m, 2),
                  let mo = enMonths[s1.lowercased()], let day = Int(s2) else { return nil }
            guard let d = monthDay(mo, day, nil) else { return nil }
            return (d, false)
        })

        // ---- 英文：next / this / by + weekday ----
        add("(next|this|by)\\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)", { m in
            guard let s1 = cap(m, 1), let s2 = cap(m, 2),
                  let target = enWeekday[s2.lowercased()] else { return nil }
            let pref = s1.lowercased()
            let ws = weekStart(cal, now)
            let curIdx = (cal.component(.weekday, from: now) + 5) % 7
            var offset = target
            switch pref {
            case "next": offset = 7 + target
            case "this": break
            default: // by
                if target < curIdx { offset = 7 + target }
            }
            guard let d0 = cal.date(byAdding: .day, value: offset, to: ws) else { return nil }
            let out = cal.date(bySettingHour: 9, minute: 0, second: 0, of: d0) ?? d0
            return (out, false)
        })

        return hits
    }

    /// 把文本里的时间（上午/下午/晚上 + N点 / HH:MM）附加到某个日期上
    public static func attachTime(_ text: String, to date: Date, cal: Calendar = .current) -> (Date, Bool) {
        let ns = text as NSString
        var hour: Int? = nil
        var minute = 0
        var pm = false
        var am = false

        if let re = try? NSRegularExpression(pattern: "(上午|早上|早晨|中午|下午|晚上|傍晚)"),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range)
            if w == "下午" || w == "晚上" || w == "傍晚" { pm = true }
            if w == "上午" || w == "早上" || w == "早晨" { am = true }
            if w == "中午" { hour = 12 }
        }
        if let re = try? NSRegularExpression(pattern: "(\\d{1,2})\\s*[点时]\\s*(\\d{1,2})?\\s*分?"),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            hour = Int(ns.substring(with: m.range(at: 1))) ?? 0
            if m.numberOfRanges >= 3, m.range(at: 2).location != NSNotFound {
                minute = Int(ns.substring(with: m.range(at: 2))) ?? 0
            }
        } else if let re = try? NSRegularExpression(pattern: "(?<![\\d:：])(\\d{1,2})\\s*[:：]\\s*(\\d{2})(?![\\d])"),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            hour = Int(ns.substring(with: m.range(at: 1))) ?? 0
            minute = Int(ns.substring(with: m.range(at: 2))) ?? 0
        }

        guard var h = hour else { return (date, false) }
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        if h > 23 { h = 23 }
        let d = cal.date(bySettingHour: h, minute: minute, second: 0, of: date) ?? date
        return (d, true)
    }

    /// 从一段文本里解析出「任务名 + 截止日期」
    public static func parse(text rawText: String,
                             cfg: Config = Config(),
                             now: Date = Date(),
                             cal: Calendar = .current) -> ParsedDDL {
        var out = ParsedDDL()
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        out.notes = String(text.prefix(2000))
        guard !text.isEmpty else { return out }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        struct LineInfo { var text: String; var hit: Hit?; var score: Int }
        var infos: [LineInfo] = []
        for line in lines {
            let hits = findHits(in: line, now: now, cal: cal)
            var score = 0
            score += keywordScore(line, cfg) * 12
            if !hits.isEmpty { score += 20 }
            score += max(0, 6 - line.count / 12)
            if line.count > 90 { score -= 8 }
            infos.append(LineInfo(text: line, hit: hits.first, score: score))
        }
        guard !infos.isEmpty else { return out }

        let bestIdx = infos.indices.max(by: { infos[$0].score < infos[$1].score }) ?? 0
        let best = infos[bestIdx]

        if let hit = best.hit {
            var d = hit.date
            let (d2, hasTime) = attachTime(best.text, to: d, cal: cal)
            if hasTime { d = d2 }
            out.due = d
            out.dueText = hit.text
            out.confidence = keywordScore(best.text, cfg) > 0 ? "high" : "medium"
        } else {
            out.confidence = "low"
        }
        out.matchedLine = best.text

        // 标题：优先取命中行去掉日期后的部分
        var title = ""
        if let hit = best.hit {
            title = cleanTitle(stripDate(best.text, hit: hit))
        }
        // 该行去掉日期就没内容了 → 就近找别的行
        if title.isEmpty {
            for offset in 1..<max(infos.count, 1) {
                let j = bestIdx - offset
                if j >= 0 {
                    let cand = cleanTitle(stripDate(infos[j].text, hit: infos[j].hit))
                    if !cand.isEmpty { title = cand; break }
                }
                let k = bestIdx + offset
                if k < infos.count {
                    let cand = cleanTitle(stripDate(infos[k].text, hit: infos[k].hit))
                    if !cand.isEmpty { title = cand; break }
                }
            }
        }
        if title.isEmpty {
            for info in infos {
                let cand = cleanTitle(info.text)
                if !cand.isEmpty { title = cand; break }
            }
        }
        out.title = title.isEmpty ? "未命名 DDL" : title
        return out
    }
}

// MARK: - OCR

public enum OCR {
    public static func recognize(image: CGImage, languages: [String]) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        if #available(macOS 11.0, *) {
            req.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([req])
        let obs = req.results ?? []
        let lines = obs.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    public static func recognize(url: URL, languages: [String]) throws -> String {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "DDLShot", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取图片: \(url.path)"])
        }
        return try recognize(image: cg, languages: languages)
    }
}

// MARK: - 截屏

public enum Capture {

    /// 取当前最前（z 序最靠上）的非本 App 窗口
    public static func frontmostWindow(excluding ownPID: pid_t? = nil) throws -> (id: CGWindowID, title: String) {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            throw NSError(domain: "DDLShot", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法枚举窗口"])
        }

        var candidates: [(info: [String: Any], id: CGWindowID, area: Double)] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let onscreen = info[kCGWindowIsOnscreen as String] as? Bool, onscreen else { continue }
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? -1
            if let own = ownPID, pid == own { continue }
            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let w = bounds?["Width"] as? Double ?? 0
            let h = bounds?["Height"] as? Double ?? 0
            if w < 200 || h < 140 { continue }
            candidates.append((info, id, w * h))
        }

        guard let picked = candidates.first ?? candidates.max(by: { $0.area < $1.area }) else {
            throw NSError(domain: "DDLShot", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "找不到可截取的窗口"])
        }
        let title = picked.info[kCGWindowName as String] as? String ?? ""
        return (picked.id, title)
    }

    public static func captureWindow(_ id: CGWindowID) async throws -> URL {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw NSError(domain: "DDLShot", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "窗口已经关闭或不可截取，请重试。"
            ])
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = makeConfig(points: window.frame.size,
                                screen: NSScreen.screens.first { NSIntersectionRect($0.frame, window.frame).width > 1 })
        let image = try await snapshot(filter: filter, config: config)
        return try writePNG(image)
    }

    public static func captureScreen() async throws -> URL {
        let content = try await shareableContent()
        guard let display = content.displays.first else {
            throw NSError(domain: "DDLShot", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "找不到显示器。"
            ])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = makeConfig(points: CGSize(width: display.width, height: display.height),
                                screen: NSScreen.main ?? NSScreen.screens.first)
        let image = try await snapshot(filter: filter, config: config)
        return try writePNG(image)
    }

    /// 手动框选：先拍一张全屏图铺在屏幕上，用户在上面拖拽，再把选区裁出来
    public static func captureInteractive() async throws -> URL {
        let content = try await shareableContent()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw NSError(domain: "DDLShot", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "找不到显示器。"
            ])
        }
        let sf = screen.frame
        let scale = screen.backingScaleFactor
        let display = content.displays.first { d in
            abs(d.width - Int(sf.width * scale)) <= 2 && abs(d.height - Int(sf.height * scale)) <= 2
        } ?? content.displays.first
        guard let display else {
            throw NSError(domain: "DDLShot", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "找不到对应的显示器。"
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = makeConfig(points: CGSize(width: display.width, height: display.height), screen: screen)
        let shot = try await snapshot(filter: filter, config: config)

        // 测试钩子：DDLSHOT_TEST_REGION="x,y,w,h"（AppKit 全局坐标）时跳过交互直接裁，
        // 用于自动化验证「截屏 → 裁剪」的坐标换算。正常使用不设这个变量。
        let rect: CGRect
        if let spec = ProcessInfo.processInfo.environment["DDLSHOT_TEST_REGION"] {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else {
                throw NSError(domain: "DDLShot", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "DDLSHOT_TEST_REGION 格式应为 x,y,w,h"
                ])
            }
            rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        } else {
            guard let picked = await RegionSelector.select(screen: screen, background: shot) else {
                throw NSError(domain: "DDLShot", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "已取消框选。"
                ])
            }
            rect = picked
        }

        guard let cropped = crop(shot, to: rect, screen: screen) else {
            throw NSError(domain: "DDLShot", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "裁剪选区失败，请重试。"
            ])
        }
        return try writePNG(cropped)
    }

    // MARK: 内部实现

    /// 当前可共享的窗口 / 显示器列表
    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw NSError(domain: "DDLShot", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "读取屏幕内容失败：\(error.localizedDescription)"
            ])
        }
    }

    /// 组装截图配置
    ///
    /// 关键点：ScreenCaptureKit 默认会把 Retina 屏的输出**降到 1920×1080**
    /// （实测 1470×956pt 的屏只给 1920×1080），对小字 OCR 很不友好。
    /// 这里显式要原生物理像素（points × backingScaleFactor），并关掉 scalesToFit 防止缩放。
    static func makeConfig(points: CGSize, screen: NSScreen?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.capturesAudio = false          // 只要画面，别去碰麦克风
        let scale = screen?.backingScaleFactor ?? 2
        config.width = max(1, Int(points.width * scale))
        config.height = max(1, Int(points.height * scale))
        config.scalesToFit = false
        return config
    }

    /// 按内容过滤器截一张图（整个过程在 DDLShot 进程内完成）
    ///
    /// macOS 26+ 走 `SCScreenshotConfiguration` —— 那个配置对象里**一个音频字段都没有**，
    /// 所以系统完全不会去碰麦克风。旧系统只能回退到 `SCStreamConfiguration`，
    /// 那条路径会顺带做一次麦克风权限检查（拒绝掉即可，不影响截图）。
    static func snapshot(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> NSImage {
        if #available(macOS 26.0, *) {
            let sc = SCScreenshotConfiguration()
            sc.width = config.width
            sc.height = config.height
            sc.showsCursor = config.showsCursor
            let output: SCScreenshotOutput = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<SCScreenshotOutput, Error>) in
                SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: sc) { output, error in
                    if let error {
                        cont.resume(throwing: NSError(domain: "DDLShot", code: 5, userInfo: [
                            NSLocalizedDescriptionKey: "截屏失败：\(error.localizedDescription)"
                        ]))
                    } else if let output {
                        cont.resume(returning: output)
                    } else {
                        cont.resume(throwing: NSError(domain: "DDLShot", code: 5, userInfo: [
                            NSLocalizedDescriptionKey: "截屏失败：系统没有返回画面。"
                        ]))
                    }
                }
            }
            guard let cg = output.sdrImage else {
                throw NSError(domain: "DDLShot", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "截屏失败：系统没有返回画面。"
                ])
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }

        let cg: CGImage = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let error {
                    cont.resume(throwing: NSError(domain: "DDLShot", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "截屏失败：\(error.localizedDescription)"
                    ]))
                } else if let image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: NSError(domain: "DDLShot", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "截屏失败：系统没有返回画面。"
                    ]))
                }
            }
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 按选区裁剪。全局屏幕坐标（AppKit，原点左下）→ 图像像素坐标（原点左上）
    static func crop(_ image: NSImage, to rect: CGRect, screen: NSScreen) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let px = CropMath.pixelRect(for: rect,
                                    screenFrame: screen.frame,
                                    imagePixelWidth: cg.width,
                                    imagePixelHeight: cg.height)
        guard px.width > 1, px.height > 1,
              let sub = cg.cropping(to: px.integral) else { return nil }
        return NSImage(cgImage: sub, size: NSSize(width: sub.width, height: sub.height))
    }

    /// 写成临时 PNG
    static func writePNG(_ image: NSImage) throws -> URL {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "DDLShot", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "截屏失败：画面数据为空。"
            ])
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "DDLShot", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "截屏失败：无法编码 PNG。"
            ])
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ddlshot-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }
}

// MARK: - 提醒事项写入

public enum Reminders {

    public static func store() throws -> EKEventStore {
        let s = EKEventStore()
        var st = EKEventStore.authorizationStatus(for: .reminder)
        if st == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            s.requestFullAccessToReminders { granted, err in
                if !granted {
                    FileHandle.standardError.write(Data(
                        "DDLShot: 提醒事项授权被拒绝\(err.map { "：\($0.localizedDescription)" } ?? "")\n".utf8))
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 60)
            st = EKEventStore.authorizationStatus(for: .reminder)
        }
        guard st == .fullAccess else {
            throw NSError(domain: "DDLShot", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "没有「提醒事项」完全访问权限。请到「系统设置 → 隐私与安全性 → 提醒事项」里允许 DDLShot。"
            ])
        }
        return s
    }

    /// 找到（或创建）指定名称的提醒事项清单
    public static func ensureList(_ name: String, store: EKEventStore) throws -> EKCalendar {
        let all = store.calendars(for: .reminder)
        if let c = all.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return c }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = name
        if let src = store.defaultCalendarForNewReminders()?.source ?? all.first?.source ?? store.sources.first {
            cal.source = src
        }
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    @discardableResult
    public static func add(title: String, due: Date?, notes: String, listName: String) throws -> String {
        let store = try Reminders.store()
        let cal = try ensureList(listName, store: store)
        let rem = EKReminder(eventStore: store)
        rem.title = title.isEmpty ? "未命名 DDL" : title
        rem.calendar = cal
        if !notes.isEmpty { rem.notes = notes }
        if let due {
            var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            comps.second = 0
            rem.dueDateComponents = comps
        }
        try store.save(rem, commit: true)
        return rem.calendarItemIdentifier
    }
}

// MARK: - 通知（命令行回退用）

public enum Notify {
    /// 菜单栏 App 可注入自己的通知通道（原生 UNUserNotificationCenter）
    public static var handler: ((String, String) -> Void)? = nil

    public static func post(_ title: String, _ body: String) {
        if let h = handler { h(title, body); return }
        let esc = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let et = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(esc)\" with title \"\(et)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}

// MARK: - CLI

public struct CLI {
    public var cfg = Config()
    public var mode: String = "menu"   // menu|window|screen|interactive|image|text|clipboard|selftest|initlist|status
    public var imagePath: String? = nil
    public var textArg: String? = nil
    public var dryRun = false
    public var jsonOut = false
    /// rule = 本地规则解析；llm = 大模型理解；auto = 配了 key 就用大模型，否则本地规则
    public var engine: String = "auto"
    /// llm 模式下优先把原图送给视觉模型（失败再降级为本地 OCR 文本）
    public var llmPrefersImage = true
    public var llmConfigPath: String = ""

    public init() {}

    public mutating func parseArgs(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--capture", "--window":
                mode = "window"
            case "--screen":
                mode = "screen"
            case "--interactive":
                mode = "interactive"
            case "--clipboard":
                mode = "clipboard"
            case "--text":
                mode = "text"
                i += 1
                if i < args.count { textArg = args[i] }
            case "--image":
                mode = "image"
                i += 1
                if i < args.count { imagePath = args[i] }
            case "--list":
                i += 1
                if i < args.count { cfg.listName = args[i] }
            case "--dry-run":
                dryRun = true
            case "--json":
                jsonOut = true
            case "--selftest":
                mode = "selftest"
            case "--init-list":
                mode = "initlist"
            case "--status":
                mode = "status"
            case "--list-providers":
                mode = "providers"
            case "--engine":
                i += 1
                if i < args.count { engine = args[i].lowercased() }
            case "--llm-config":
                i += 1
                if i < args.count { llmConfigPath = args[i] }
            case "--llm-text":
                llmPrefersImage = false
            case "--llm-image":
                llmPrefersImage = true
            case "--help", "-h":
                mode = "help"
            default:
                break
            }
            i += 1
        }
    }

    public func run() async -> Int32 {
        switch mode {
        case "help":
            print(Self.helpText)
            return 0
        case "selftest":
            return SelfTest.run()
        case "initlist":
            do {
                let store = try Reminders.store()
                let cal = try Reminders.ensureList(cfg.listName, store: store)
                print("清单「\(cal.title)」已就绪（\(cal.calendarIdentifier)）")
                return 0
            } catch {
                fail("创建清单失败：\(error.localizedDescription)")
                return 2
            }
        case "providers":
            print("可用的大模型供应商预设（写进配置的 provider 字段即可切换）：")
            for p in LLMProviders.all {
                print("  \(p.id.padding(toLength: 15, withPad: " ", startingAt: 0))  \(p.title)")
                print("      地址：\(p.baseURL.isEmpty ? "（自己填）" : p.baseURL)")
                print("      模型：\(p.model.isEmpty ? "（自己填）" : p.model)   协议：\(p.protocolMode)")
                print("      \(p.note)")
            }
            print("\n用法：在 ~/.config/ddlshot/config.json 里写 {\"llm\": {\"provider\": \"deepseek\", \"api_key\": \"...\"}}")
            return 0
        case "status":
            print("提醒事项权限：\(Permissions.remindersDescription())")
            let lists = EKEventStore().calendars(for: .reminder).map { $0.title }
            print("可见清单　：\(lists.isEmpty ? "(无 / 尚无权限)" : lists.joined(separator: "、"))")
            print("屏幕录制权限：\(Permissions.screenCaptureGranted ? "已授权 ✅" : "未授权 ✗（系统设置 → 隐私与安全性 → 录屏与系统录音）")")
            let lcfg = loadLLMConfig()
            if let c = lcfg {
                if c.isConfigured {
                    print("大模型：已配置（\(c.providerTitle) · \(c.model) @ \(c.baseURL)）")
                } else {
                    var missing: [String] = []
                    if c.baseURL.isEmpty { missing.append("base_url") }
                    if c.apiKey.isEmpty { missing.append("api_key") }
                    if c.model.isEmpty { missing.append("model") }
                    print("大模型：配置不完整（缺 \(missing.joined(separator: "/"))）"
                          + "　→ 编辑 \(c.configPath)")
                }
            } else {
                print("大模型：未配置（找不到 \(llmConfigPath.isEmpty ? LLMConfig.defaultConfigPath : llmConfigPath)）")
            }
            return 0
        default:
            break
        }

        // ── 取内容 ──
        var ocrText = ""
        var captured: URL? = nil
        var tempFiles: [URL] = []
        do {
            switch mode {
            case "text":
                ocrText = textArg ?? ""
            case "clipboard":
                ocrText = NSPasteboard.general.string(forType: .string) ?? ""
            case "image":
                guard let p = imagePath else {
                    throw NSError(domain: "DDLShot", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "--image 缺少路径"])
                }
                captured = URL(fileURLWithPath: p)
            case "window":
                let w = try Capture.frontmostWindow()
                let url = try await Capture.captureWindow(w.id)
                tempFiles.append(url)
                captured = url
            case "screen":
                let url = try await Capture.captureScreen()
                tempFiles.append(url)
                captured = url
            case "interactive":
                let url = try await Capture.captureInteractive()
                tempFiles.append(url)
                captured = url
            default:
                break
            }
        } catch {
            fail("抓取失败：\(error.localizedDescription)")
            if !Permissions.screenCaptureGranted {
                fail("→ 屏幕录制权限未授权：系统设置 → 隐私与安全性 → 录屏与系统录音 → 打开 DDLShot")
            }
            return 1
        }
        // 调试钩子：DDLSHOT_KEEP_CAPTURE=1 时保留截屏文件并打印路径，方便排查
        let keepCapture = ProcessInfo.processInfo.environment["DDLSHOT_KEEP_CAPTURE"] == "1"
        defer {
            for f in tempFiles {
                if keepCapture { print("已保留截屏：\(f.path)") }
                else { try? FileManager.default.removeItem(at: f) }
            }
        }

        // ── 解析 ──
        var parsed: [ParsedDDL] = []
        var engineUsed = "rule"

        // 决定用哪个引擎
        var useLLM = false
        if engine == "llm" {
            useLLM = true
        } else if engine == "auto" {
            useLLM = loadLLMConfig()?.isConfigured == true
        }

        if useLLM {
            engineUsed = "llm"
            let lcfg = loadLLMConfig()
            if let c = lcfg, c.isConfigured {
                do {
                    parsed = try LLMEngine.extract(
                        imageURL: llmPrefersImage ? captured : nil,
                        textProvider: { try self.ocrTextOnly(text: ocrText, image: captured) },
                        cfg: c)
                } catch {
                    fail("大模型识别失败：\(error.localizedDescription)")
                    return 3
                }
                if parsed.isEmpty {
                    fail("画面已经拿到了，但里面没有识别出带截止时间的待办。")
                    fail("→ 这不是权限问题。常见原因：截到的窗口里确实没有 DDL；"
                         + "或者 DDL 写得太含糊（没有日期/时间线索）。")
                    fail("→ 换一张有明确日期的截图再试，或先跑 --dry-run 看识别结果。")
                    return 1
                }
            } else {
                if engine == "llm" {
                    fail("大模型配置不完整：需要 base_url / api_key / model 三项。"
                         + "配置文件：\(LLMConfig.defaultConfigPath)")
                    return 3
                }
                // auto 模式：配置不全 → 安静回落到本地规则
                engineUsed = "rule"
                useLLM = false
            }
        }

        if !useLLM {
            let text = try? ocrTextOnly(text: ocrText, image: captured)
            guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("没有可解析的文字（截图中没识别到文本？）")
                return 1
            }
            parsed = [DateParser.parse(text: t, cfg: cfg)]
            ocrText = t
        }

        // ── 输出 ──
        if jsonOut {
            let items: [[String: Any]] = parsed.map { p -> [String: Any] in
                var o: [String: Any] = [
                    "title": p.title,
                    "dueText": p.dueText,
                    "matchedLine": p.matchedLine,
                    "confidence": p.confidence,
                    "notes": p.notes,
                ]
                o["due"] = p.due.map { DateParser.format($0) } ?? NSNull()
                return o
            }
            let obj: [String: Any] = [
                "engine": engineUsed,
                "count": parsed.count,
                "items": items,
                "ocrText": String(ocrText.prefix(2000)),
                "dryRun": dryRun,
                "list": cfg.listName,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: d, encoding: .utf8) {
                print(s)
            }
        } else {
            print("引擎　：\(engineUsed == "llm" ? "大模型" : "本地规则")　共识别 \(parsed.count) 条")
            for (i, p) in parsed.enumerated() {
                let dueStr = p.due.map { fmtDate($0) } ?? "(未识别到日期)"
                let src = p.dueText.isEmpty ? "" : "　[识别自「\(p.dueText)」]"
                print("\(i + 1). \(p.title)")
                print("   截止：\(dueStr)\(src)　置信度：\(p.confidence)")
            }
            print("清单　：\(cfg.listName)")
        }

        if dryRun { return 0 }

        // ── 写入 ──
        do {
            var ids: [String] = []
            for p in parsed {
                let id = try Reminders.add(title: p.title, due: p.due, notes: p.notes, listName: cfg.listName)
                ids.append(id)
            }
            Notify.post("已加入 \(cfg.listName)",
                        parsed.count == 1
                        ? parsed[0].title + (parsed[0].due.map { " · \(fmtDate($0))" } ?? "")
                        : "\(parsed.count) 条待办")
            if !jsonOut { print("状态　：✅ 已写入 \(parsed.count) 条到提醒事项") }
            return 0
        } catch {
            fail("写入提醒事项失败：\(error.localizedDescription)")
            if !Permissions.remindersGranted {
                fail("→ 提醒事项权限不足：系统设置 → 隐私与安全性 → 提醒事项 → 打开 DDLShot")
            }
            return 2
        }
    }

    /// 需要文本时：已有文本直接用，否则对图片做本地 OCR
    func ocrTextOnly(text: String, image: URL?) throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let image {
            return try OCR.recognize(url: image, languages: cfg.ocrLanguages)
        }
        return ""
    }

    func loadLLMConfig() -> LLMConfig? {
        let path = llmConfigPath.isEmpty ? LLMConfig.defaultConfigPath : llmConfigPath
        var c = LLMConfig.load(path: path) ?? LLMConfig()
        c.configPath = path
        // 命令行覆盖
        if let env = ProcessInfo.processInfo.environment["DDLSHOT_LLM_API_KEY"], !env.isEmpty {
            c.apiKey = env
        }
        if let env = ProcessInfo.processInfo.environment["DDLSHOT_LLM_BASE_URL"], !env.isEmpty {
            c.baseURL = env
        }
        if let env = ProcessInfo.processInfo.environment["DDLSHOT_LLM_MODEL"], !env.isEmpty {
            c.model = env
        }
        return c
    }

    public func fmtDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return f.string(from: d)
    }

    public func fail(_ msg: String) {
        CLI.lastError = (CLI.lastError ?? "") + msg + "\n"
        FileHandle.standardError.write(Data("DDLShot: \(msg)\n".utf8))
    }

    /// 最近一次失败的原因（菜单栏弹窗直接展示，避免用户猜）
    public static var lastError: String? = nil

    public static let helpText = """
    DDLShot — 截屏/文字 → 解析 DDL → 写入系统「提醒事项」

    用法：
      ddlshot                     启动菜单栏 App（默认）
      ddlshot --capture           截取最前窗口并解析写入
      ddlshot --screen            截取整个屏幕并解析写入
      ddlshot --interactive        手动框选区域后解析写入
      ddlshot --image <路径>       对图片做 OCR 后解析写入
      ddlshot --clipboard          解析剪贴板文字
      ddlshot --text "<文本>"      直接解析给定文本
      ddlshot --init-list         只创建提醒事项清单
      ddlshot --status            查看权限 / 清单 / 大模型配置
      ddlshot --selftest          运行解析器自检

    引擎：
      --engine rule|llm|auto  auto=默认：配了大模型 key 就用大模型，否则用本地规则
                             rule=本地规则（快、离线）；llm=大模型理解（准、能一次抽多条）
      --llm-image           llm 模式下优先把原图送视觉模型（默认）
      --llm-text            llm 模式下只送本地 OCR 出来的文本
      --llm-config <路径>   大模型配置文件（默认 ~/.config/ddlshot/config.json）

    选项：
      --list <名称>   目标清单名（默认 DDL）
      --dry-run       只解析不写入
      --json          以 JSON 输出结果
    """
}

// MARK: - 自检

public enum SelfTest {
    public static func run() -> Int32 {
        var pass = 0, fail = 0
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 10, minute: 0))!

        func check(_ name: String, _ got: String?, _ want: String?) {
            if let g = got, let w = want, g == w {
                pass += 1
                print("  ✅ \(name)")
            } else {
                fail += 1
                print("  ❌ \(name)  got=\(got ?? "nil") want=\(want ?? "nil")")
            }
        }
        func fmt(_ s: String) -> String? {
            guard let d = DateParser.parse(text: s, now: now, cal: cal).due else { return nil }
            return DateParser.format(d, cal: cal)
        }
        func title(_ s: String) -> String {
            DateParser.parse(text: s, now: now, cal: cal).title
        }

        print("DDLShot 解析器自检（基准时间 2026-10-23 10:00 周五）")

        check("明天", fmt("明天 交周报"), "2026-10-24 09:00")
        check("后天", fmt("后天 交周报"), "2026-10-25 09:00")
        check("11月5日", fmt("截止 11月5日 提交实验报告"), "2026-11-05 09:00")
        check("跨年顺延", fmt("截止 1月8日 交材料"), "2027-01-08 09:00")
        check("下周三", fmt("下周三 面试"), "2026-10-28 09:00")
        check("本周五", fmt("本周五 前回复"), "2026-10-23 09:00")
        check("明天下午3点", fmt("明天下午3点 开会"), "2026-10-24 15:00")
        check("YYYY-MM-DD", fmt("deadline 2026-12-01 交稿"), "2026-12-01 09:00")
        check("M/D", fmt("11/8 报名"), "2026-11-08 09:00")
        check("英文 Nov 5", fmt("Deadline: Nov 5 submit report"), "2026-11-05 09:00")

        check("标题-同行", title("截止 11月5日 提交实验报告"), "提交实验报告")
        check("标题-上一行", title("交实验报告\n截止 11月5日"), "交实验报告")
        check("标题-英文", title("Deadline: Nov 5 submit report"), "submit report")
        check("标题-下一行", title("截止 11月5日\n提交实验报告"), "提交实验报告")

        print("\n通过 \(pass)，失败 \(fail)")
        return fail == 0 ? 0 : 1
    }
}
