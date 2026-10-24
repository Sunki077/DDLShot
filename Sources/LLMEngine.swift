// LLMEngine.swift — 调用 Python 抽取器，把屏幕内容交给云端大模型理解
import Foundation
import AppKit
import CoreGraphics
import EventKit

// MARK: - 权限自检

public enum Permissions {
    /// 屏幕录制权限（macOS 10.15+）。返回 false = 系统没给录屏权限
    public static var screenCaptureGranted: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// 提醒事项权限
    public static var remindersStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    public static var remindersGranted: Bool {
        // macOS 14+ 用 .fullAccess；旧版的 .authorized 与它同 rawValue，已被移除
        remindersStatus == .fullAccess
    }

    public static func remindersDescription() -> String {
        switch remindersStatus {
        case .notDetermined: return "未询问"
        case .restricted: return "受限制"
        case .denied: return "已拒绝"
        case .fullAccess: return "完全访问 ✅"
        case .writeOnly: return "仅写入"
        @unknown default: return "未知（rawValue \(remindersStatus.rawValue)）"
        }
    }
}

// MARK: - 供应商预设

/// 一家大模型服务商的默认配置。
/// 选好 provider 之后，base_url / model / protocol 都能自动填好；
/// 只想换模型名的话，在配置里单独写 model 覆盖即可。
public struct LLMProviderPreset {
    public let id: String
    public let title: String
    public let protocolMode: String
    public let baseURL: String
    public let model: String
    public let note: String
}

public enum LLMProviders {
    public static let all: [LLMProviderPreset] = [
        .init(id: "minimax", title: "MiniMax（Anthropic 兼容）", protocolMode: "anthropic",
              baseURL: "https://api.minimax.cn/anthropic/v1", model: "MiniMax-M3.1-Flash",
              note: "原生多模态，直接吃截图；国内 .cn 线路"),
        .init(id: "minimax-openai", title: "MiniMax（OpenAI 兼容）", protocolMode: "openai",
              baseURL: "https://api.minimax.cn/v1", model: "MiniMax-M3.1-Flash",
              note: "同一个 key，换成 OpenAI 协议"),
        .init(id: "deepseek", title: "DeepSeek", protocolMode: "openai",
              baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
              note: "便宜好用；chat 模型读不了图，会自动降级成先 OCR 再送文本"),
        .init(id: "openai", title: "OpenAI", protocolMode: "openai",
              baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
              note: "gpt-4o 系列支持读图"),
        .init(id: "qwen", title: "阿里云百炼（通义千问）", protocolMode: "openai",
              baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-vl-max",
              note: "qwen-vl 系列支持读图"),
        .init(id: "zhipu", title: "智谱 GLM", protocolMode: "openai",
              baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4v-plus",
              note: "glm-4v 系列支持读图"),
        .init(id: "moonshot", title: "月之暗面 Kimi", protocolMode: "openai",
              baseURL: "https://api.moonshot.cn/v1", model: "kimi-k2-0905-preview",
              note: "模型名可能更新，按官网改配置里的 model 即可"),
        .init(id: "doubao", title: "火山引擎方舟（豆包）", protocolMode: "openai",
              baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: "",
              note: "必须把 model 换成你自己的 endpoint id"),
        .init(id: "siliconflow", title: "硅基流动 SiliconFlow", protocolMode: "openai",
              baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-VL-72B-Instruct",
              note: "聚合平台，一个 key 一堆模型"),
        .init(id: "gemini", title: "Google Gemini", protocolMode: "openai",
              baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-flash",
              note: "走 OpenAI 兼容端点，需要能连外网"),
        .init(id: "ollama", title: "本地 Ollama", protocolMode: "openai",
              baseURL: "http://localhost:11434/v1", model: "qwen2.5vl",
              note: "本机跑，不联网；先 `ollama pull qwen2.5vl`"),
        .init(id: "custom", title: "自定义（自己填 base_url）", protocolMode: "openai",
              baseURL: "", model: "",
              note: "任何 OpenAI 兼容接口；Anthropic 协议把 protocol 写成 anthropic")
    ]

    public static func preset(_ id: String) -> LLMProviderPreset? {
        let key = id.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.id == key }
    }

    public static func title(_ id: String) -> String {
        preset(id)?.title ?? id
    }
}

// MARK: - 配置

public struct LLMConfig {
    /// 配置文件路径（默认 ~/.config/ddlshot/config.json）
    public var configPath: String = ""
    /// 供应商预设 id（minimax / deepseek / openai / …）；为空则完全按下面几项自定义
    public var provider: String = ""
    /// 大模型协议：auto / openai / anthropic
    public var protocolMode: String = "auto"
    public var baseURL: String = ""
    public var apiKey: String = ""
    public var model: String = ""
    public var timeout: Int = 120
    public var defaultHour: Int = 9
    /// 送图给模型时，失败是否自动降级成「先本地 OCR 再送文本」
    public var fallbackToText: Bool = true
    /// Python 解释器路径（空 = 自动找）
    public var pythonPath: String = ""

    public init() {}

    public static let defaultConfigPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ddlshot/config.json").path

    /// 读配置文件；不存在返回 nil
    public static func load(path: String? = nil) -> LLMConfig? {
        let p = path ?? defaultConfigPath
        guard let data = FileManager.default.contents(atPath: p),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let llm = (raw["llm"] as? [String: Any]) ?? raw
        var c = LLMConfig()
        c.configPath = p
        if let v = llm["provider"] as? String { c.provider = v }
        if let v = llm["protocol"] as? String { c.protocolMode = v }
        if let v = llm["base_url"] as? String { c.baseURL = v }
        if let v = llm["api_key"] as? String { c.apiKey = v }
        if let v = llm["model"] as? String { c.model = v }
        if let v = llm["timeout"] as? Int { c.timeout = v }
        if let v = llm["default_hour"] as? Int { c.defaultHour = v }
        if let v = llm["python"] as? String { c.pythonPath = v }
        if let v = llm["fallback_to_text"] as? Bool { c.fallbackToText = v }

        // 供应商预设：配置里没写的项用预设补上（显式写的优先）
        if let preset = LLMProviders.preset(c.provider) {
            if c.baseURL.isEmpty { c.baseURL = preset.baseURL }
            if c.model.isEmpty { c.model = preset.model }
            if llm["protocol"] == nil { c.protocolMode = preset.protocolMode }
        }
        return c
    }

    /// 是否配齐了可以直接调 API 的三项
    public var isConfigured: Bool {
        !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty
    }

    /// 人类可读的供应商名
    public var providerTitle: String {
        if !provider.isEmpty { return LLMProviders.title(provider) }
        if baseURL.contains("minimax") { return "MiniMax" }
        if baseURL.contains("deepseek") { return "DeepSeek" }
        if baseURL.contains("openai.com") { return "OpenAI" }
        return "自定义"
    }
}

// MARK: - 引擎

public enum LLMEngine {

    /// 抽取器脚本位置：打包后放在 Contents/Resources，开发时用源码目录
    public static func scriptURL() -> URL? {
        if let u = Bundle.main.url(forResource: "ddlshot_llm", withExtension: "py") {
            return u
        }
        // 开发态：源码目录
        let env = ProcessInfo.processInfo.environment["DDLSHOT_SRC_DIR"]
        if let env { return URL(fileURLWithPath: env).appendingPathComponent("ddlshot_llm.py") }
        // 从可执行文件位置反推
        //   打包态: DDLShot.app/Contents/MacOS/DDLShot → Contents/Resources/ddlshot_llm.py
        //   开发态: DDLShot/build/ddlshot             → DDLShot/Sources/ddlshot_llm.py
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("ddlshot_llm.py"),
            exeDir.deletingLastPathComponent().appendingPathComponent("Resources/ddlshot_llm.py"),
            exeDir.deletingLastPathComponent().appendingPathComponent("Sources/ddlshot_llm.py"),
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c }
        return nil
    }

    /// 找一个可用的 Python 解释器（优先带 httpx/requests 的）
    public static func resolvePython(preferred: String = "") -> String? {
        var candidates: [String] = []
        if !preferred.isEmpty { candidates.append(preferred) }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/python3" }
        }
        candidates += [
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        var seen = Set<String>()
        var plain: String?
        for c in candidates {
            guard !seen.contains(c) else { continue }
            seen.insert(c)
            guard FileManager.default.isExecutableFile(atPath: c) else { continue }
            if plain == nil { plain = c }
            // 有 httpx 最好（连接复用、超时可控）
            if pythonHasModule(c, "httpx") { return c }
        }
        return plain
    }

    private static func pythonHasModule(_ python: String, _ module: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "import \(module)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    /// 调抽取器。
    /// - Parameters:
    ///   - imageURL: 截图文件（可空）
    ///   - textProvider: 需要文本时的惰性来源（一般是本地 Vision OCR）
    ///   - preferImage: 优先送图给视觉模型
    public static func extract(imageURL: URL?,
                               textProvider: (() throws -> String)?,
                               cfg: LLMConfig) throws -> [ParsedDDL] {
        guard let script = scriptURL() else {
            throw LLMError.message("找不到抽取器脚本 ddlshot_llm.py")
        }
        guard let python = resolvePython(preferred: cfg.pythonPath) else {
            throw LLMError.message("找不到 Python 解释器（brew install python 或在配置里指定 python 路径）")
        }

        var lastErr: Error?
        // 优先送图（视觉模型）；失败则降级成「本地 OCR 文本」
        if let imageURL {
            do {
                return try run(python: python, script: script, args: ["--image", imageURL.path],
                               cfg: cfg)
            } catch {
                lastErr = error
                if !cfg.fallbackToText { throw error }
            }
        }
        guard let provider = textProvider else {
            if let e = lastErr { throw e }
            throw LLMError.message("没有可送模型的文本")
        }
        let text = try provider()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let e = lastErr { throw e }
            throw LLMError.message("没有可送模型的文本")
        }
        do {
            return try run(python: python, script: script, args: ["--text", text], cfg: cfg)
        } catch {
            if let e = lastErr { throw e }
            throw error
        }
    }

    private static func run(python: String, script: URL, args: [String], cfg: LLMConfig) throws -> [ParsedDDL] {
        var pArgs: [String] = [script.path] + args
        if !cfg.configPath.isEmpty { pArgs += ["--config", cfg.configPath] }
        if !cfg.baseURL.isEmpty { pArgs += ["--base-url", cfg.baseURL] }
        if !cfg.model.isEmpty { pArgs += ["--model", cfg.model] }
        if !cfg.protocolMode.isEmpty { pArgs += ["--protocol", cfg.protocolMode] }
        if !cfg.provider.isEmpty { pArgs += ["--provider", cfg.provider] }
        pArgs += ["--default-hour", String(cfg.defaultHour)]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = pArgs
        // key 走环境变量，不出现在进程参数里（ps 可见）
        var env = ProcessInfo.processInfo.environment
        if !cfg.apiKey.isEmpty { env["DDLSHOT_LLM_API_KEY"] = cfg.apiKey }
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do { try p.run() } catch {
            throw LLMError.message("启动 Python 失败: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(Double(cfg.timeout))
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
        }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            throw LLMError.message("调用大模型超时（\(cfg.timeout)s）")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        guard p.terminationStatus == 0 else {
            let msg = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LLMError.message(msg.isEmpty ? "抽取器退出码 \(p.terminationStatus)" : msg)
        }
        guard let data = outStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LLMError.message("抽取器输出无法解析为数组: \(outStr.prefix(300))")
        }
        return arr.compactMap { item -> ParsedDDL? in
            var d = ParsedDDL()
            d.title = (item["title"] as? String) ?? ""
            if d.title.isEmpty { return nil }
            d.due = LLMEngine.parseISODue(item["due"] as? String)
            d.dueText = (item["dueText"] as? String) ?? ""
            d.notes = (item["notes"] as? String) ?? ""
            d.confidence = (item["confidence"] as? String) ?? "medium"
            d.matchedLine = d.notes
            return d
        }
    }

    static func parseISODue(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

public enum LLMError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
