import CryptoKit
import Foundation


/// 文本哈希。Android 端 `contentHash` / `sourceHash` 用于判断内容是否变化，
/// 译文分段靠它做缓存命中；`sourceSha256` 字段要求完整 SHA-256。
enum ContentHash {
    /// 基于 CryptoKit 生成完整 SHA-256 小写十六进制字符串。
    static func of(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 协调读取文件选择器提供的安全作用域 URL，读取前校验体积上限。
enum SecurityScopedFileReader {
    static let bytesPerMiB = 1_048_576

    static func read(
        _ url: URL,
        maxBytes: Int,
        tooLargeError: (Int) -> Error
    ) throws -> Data {
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { readableURL in
            readResult = Result {
                try readBounded(readableURL, maxBytes: maxBytes, tooLargeError: tooLargeError)
            }
        }
        if let readResult {
            return try readResult.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        return try readBounded(url, maxBytes: maxBytes, tooLargeError: tooLargeError)
    }

    private static func readBounded(
        _ url: URL,
        maxBytes: Int,
        tooLargeError: (Int) -> Error
    ) throws -> Data {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxBytes {
            throw tooLargeError(size)
        }
        let data = try Data(contentsOf: url)
        if data.count > maxBytes {
            throw tooLargeError(data.count)
        }
        return data
    }
}

/// 文本导入解码与正文导出格式化工具，对齐原版 APK 编码回退与换行规范。
enum TextFileCodec {
    static let maxImportBytes = 12 * SecurityScopedFileReader.bytesPerMiB
    static let allowedExtensions: Set<String> = ["txt", "md", "markdown"]

    enum CodecError: LocalizedError {
        case unsupportedExtension(String)
        case unsupportedEncoding
        case containsNullByte

        var errorDescription: String? {
            switch self {
            case .unsupportedExtension(let ext):
                return "不支持导入 .\(ext) 文件，仅支持 txt、md、markdown。"
            case .unsupportedEncoding:
                return "无法识别文件编码，请使用 UTF-8、UTF-16 或 GBK/GB18030 纯文本。"
            case .containsNullByte:
                return "文件内容包含无效空字符，无法作为纯文本导入。"
            }
        }
    }

    static func validateExtension(_ url: URL) throws {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ext.isEmpty || allowedExtensions.contains(ext) else {
            throw CodecError.unsupportedExtension(ext)
        }
    }

    static func decode(_ data: Data) throws -> String {
        let raw: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            raw = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) {
            raw = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            raw = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            raw = utf8
        } else {
            let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            let gbEncoding = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            )
            raw = String(data: data, encoding: gbEncoding)
        }
        guard let decoded = raw else {
            throw CodecError.unsupportedEncoding
        }
        guard !decoded.contains("\0") else {
            throw CodecError.containsNullByte
        }
        return normalizeNewlines(decoded)
    }

    static func normalizeNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// 导出纯文本前剥离 Markdown 语法标记并统一换行符。
    static func plainTextForExport(from source: String) -> String {
        let lines = normalizeNewlines(source).components(separatedBy: "\n")
        var result: [String] = []
        var fenceChar: Character?
        var fenceLength = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fenceChar == nil {
                if let prefix = fencePrefix(in: trimmed) {
                    fenceChar = prefix.char
                    fenceLength = prefix.length
                    continue
                }
                if isHorizontalRule(trimmed) {
                    continue
                }
                var cleaned = stripBlockPrefix(line)
                cleaned = stripInlineMarkdown(cleaned)
                result.append(cleaned)
            } else if let active = fenceChar,
                      trimmed.count >= fenceLength,
                      trimmed.allSatisfy({ $0 == active }) {
                fenceChar = nil
                fenceLength = 0
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    static func exportFilename(title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\*?\"<>|\r\n")
        let parts = title.components(separatedBy: invalid)
        let sanitized = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "正文" : sanitized
        return "\(base).txt"
    }

    @MainActor
    static func loadPlainExport(session: ProjectSession, files: FileStore) async -> String {
        let projectID = session.project.id
        let loadedText = session.canReadByPage ? nil : session.manuscript
        return await Task.detached(priority: .userInitiated) {
            let raw = loadedText ?? files.loadBody(projectID)?.text ?? ""
            return plainTextForExport(from: raw)
        }.value
    }

    private static func fencePrefix(in trimmed: String) -> (char: Character, length: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        return (first, count)
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first,
              first == "-" || first == "*" || first == "_"
        else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func stripBlockPrefix(_ line: String) -> String {
        var text = line
        text = text.replacingOccurrences(
            of: #"^\s{0,3}#{1,6}\s+"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"^\s{0,3}(?:>\s?)+"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"^\s*[-*+]\s+"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"^\s*\d+\.\s+"#,
            with: "",
            options: .regularExpression
        )
        return text
    }

    private static func stripInlineMarkdown(_ line: String) -> String {
        var text = line
        text = text.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(\*\*|__|~~)(.*?)\1"#,
            with: "$2",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(\*|_)(.*?)\1"#,
            with: "$2",
            options: .regularExpression
        )
        return text
    }
}
