import Foundation

/// 存档层错误。文案逐字取自 Android 的 `dex-chinese.txt`，导入失败时直接上屏。
enum FrthinkArchiveError: LocalizedError {
    case emptyOrDamaged
    case fileTooLarge(isFull: Bool)
    case notAnArchive(isFull: Bool)
    case unsupportedFormat
    case unsupportedCompression
    case decompressedTooLarge
    case corrupted(isFull: Bool)
    /// 解码失败，带上具体原因（缺哪个键、哪段类型不对）。
    case corruptedDetail(isFull: Bool, detail: String)
    case payloadVersionUnsupported
    case projectVersionUnsupported
    case duplicateProjects(isFull: Bool)
    case duplicateTranslations
    /// 项目 id 会被当成目录名，绝不能让存档用它做路径穿越。
    case invalidProjectID(String)
    case emptyProjectArchive
    case createFailed
    case writeFailed(String)
    /// 读不到用户选中的文件（权限、iCloud 未下载、文件提供方错误）。
    case importUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .emptyOrDamaged:
            return "文件为空、损坏或超过 300 MiB"
        case .fileTooLarge(let isFull):
            return isFull ? "全量备份文件超过 300 MiB" : "书项目存档文件超过 300 MiB"
        case .notAnArchive(let isFull):
            return isFull ? "不是有效的全量 .frthink 文件" : "不是有效的 .frthink 文件"
        case .unsupportedFormat:
            return "不支持的 .frthink 文件格式"
        case .unsupportedCompression:
            return "备份压缩格式无效"
        case .decompressedTooLarge:
            return "解压后的备份超过 300 MiB"
        case .corrupted(let isFull):
            return isFull ? "备份内容损坏" : "备份内容损坏或无法解压"
        case .corruptedDetail(_, let detail):
            return "备份内容无法解析：\(detail)"
        case .payloadVersionUnsupported:
            return "全量备份版本不受支持"
        case .projectVersionUnsupported:
            return "项目数据版本不受支持"
        case .duplicateProjects(let isFull):
            return isFull ? "全量备份含重复项目" : "书项目存档含重复项目"
        case .duplicateTranslations:
            return "备份含重复译文分段"
        case .invalidProjectID(let id):
            return "备份里的项目 id 无效：\(id)"
        case .emptyProjectArchive:
            return "书项目存档为空"
        case .createFailed:
            return "无法创建 .frthink 存档"
        case .writeFailed(let detail):
            return "存档写入失败：\(detail)"
        case .importUnreadable(let detail):
            return detail
        }
    }
}
