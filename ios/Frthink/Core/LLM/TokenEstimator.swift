import Foundation

/// Token 估算与上下文预算。
///
/// 公式照抄原版 `L1/e3.java:253-271` 与 `22-55`——**不是估个大概**，是同一套
/// 权重和同一个预算推导。两边算出来的数不一样，裁剪点就不一样，发出去的
/// 提示词就不一样。
enum TokenEstimator {

    // MARK: - 逐码点权重（`L1/e3.java:253-271`）

    /// 单个码点的权重。
    static func weight(of scalar: Unicode.Scalar) -> Double {
        let value = scalar.value

        // 汉字 / 平假名 / 片假名 / 韩文：1.0
        if isHan(value) || isKana(value) || isHangul(value) {
            return 1.0
        }
        // 空白：0.2
        if CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.whitespaces.contains(scalar) {
            return 0.2
        }
        // 其它且（≥128 或 不是字母数字且不是 `_`）：0.6
        if value >= 128 {
            if !(scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
                || value == 0x5F {
                return 0.6
            }
            return 0.6
        }
        if !isASCIISafe(value) {
            return 0.6
        }
        // ASCII 字母 / 数字 / `_`：0.28
        return 0.28
    }

    private static func isASCIISafe(_ v: UInt32) -> Bool {
        (v >= 0x30 && v <= 0x39)      // 0-9
            || (v >= 0x41 && v <= 0x5A)  // A-Z
            || (v >= 0x61 && v <= 0x7A)  // a-z
            || v == 0x5F                 // _
    }

    private static func isHan(_ v: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x2FA1F).contains(v)
    }

    private static func isKana(_ v: UInt32) -> Bool {
        (0x3040...0x309F).contains(v)     // 平假名
            || (0x30A0...0x30FF).contains(v)  // 片假名
            || (0x31F0...0x31FF).contains(v)
    }

    private static func isHangul(_ v: UInt32) -> Bool {
        (0x1100...0x11FF).contains(v)
            || (0x3130...0x318F).contains(v)
            || (0xA960...0xA97F).contains(v)
            || (0xAC00...0xD7AF).contains(v)
    }

    // MARK: - 对外

    /// `tokens(text) = ceil(sum(weights) * 1.2) + 6`
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 6 }
        var sum = 0.0
        for scalar in text.unicodeScalars {
            sum += weight(of: scalar)
        }
        return Int((sum * 1.2).rounded(.up)) + 6
    }

    /// 一组消息的估算 = 每条各自的 `tokens(content)` 之和。
    static func estimate(messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1.content) }
    }

    /// 常见模型的上下文窗。表里没有的按 64k 保守估计。
    static func contextWindow(for model: String) -> Int {
        // 目录里有确切值的先用（deepseek 系列 1M）。
        if let known = ModelCatalog.contextWindow(for: model) { return known }
        let m = model.lowercased()
        if m.contains("deepseek") { return 64_000 }
        if m.contains("claude") { return 200_000 }
        if m.contains("gemini") { return 1_000_000 }
        if m.contains("gpt-4") { return 128_000 }
        if m.contains("qwen") { return 32_000 }
        if m.contains("glm") { return 128_000 }
        return 64_000
    }

    /// 把正文裁到指定 token 预算内，从末尾保留。二分找最长可行后缀。
    static func trimTail(_ text: String, toTokens budget: Int) -> String {
        guard budget > 0 else { return "" }
        guard estimate(text) > budget else { return text }
        var low = 0
        var high = text.count
        var best = ""
        while low <= high {
            let mid = (low + high) / 2
            let start = text.index(text.endIndex, offsetBy: -mid)
            let candidate = String(text[start...])
            if estimate(candidate) <= budget {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}

/// 一次请求的预算推导（原版 `L1/e3.java:22-55`）。
struct PromptBudget {
    let inputBudget: Int
    let outputBudget: Int
    let effectiveInputBudget: Int
    let contextWindow: Int?

    /// 预算不足时抛出的错误文案，与原版逐字一致。
    struct BudgetError: LocalizedError {
        var errorDescription: String? {
            "模型上下文窗不足以同时预留输出和安全空间；没有发送请求。"
        }
    }

    static func make(
        settings: AppSettings,
        model: String,
        contextWindowOverride: Int? = nil
    ) throws -> PromptBudget {
        // 输入预算 0 = 跟随模型：用窗口减输出与 1024 安全余量。
        let window = contextWindowOverride ?? TokenEstimator.contextWindow(for: model)
        var outputBudget = min(max(settings.reservedOutputTokens, 1024), 100_000)
        let configured = settings.inputBudgetTokens
        let inputBudget: Int
        if configured <= 0 {
            inputBudget = window > 0
                ? max(1024, window - outputBudget - 1024)
                : 32_768
        } else {
            inputBudget = min(max(configured, 1024), 1_000_000)
        }

        var effective = inputBudget
        if window > 0 {
            let avail = window - (outputBudget + 1024)   // 1024 = 安全余量
            if avail < 1024 {
                throw BudgetError()
            }
            effective = min(inputBudget, avail)
            outputBudget = min(outputBudget, max(0, window))
        }

        return PromptBudget(
            inputBudget: inputBudget,
            outputBudget: outputBudget,
            effectiveInputBudget: effective,
            contextWindow: window > 0 ? window : nil
        )
    }
}

