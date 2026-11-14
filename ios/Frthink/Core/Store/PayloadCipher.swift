import CryptoKit
import Foundation

/// 书稿落盘加密。
///
/// 原版将正文持久化于 Room，并通过 AndroidKeyStore 中的主密钥加密；iOS 端
/// 对应采用 Keychain + CryptoKit。落盘文件格式为「魔数 + nonce + 密文 + 标签」，
/// 魔数用于区分密文与迁移前的明文 JSON。
///
/// 加密项目正文与配置数据（含 `payload.json`、`source.json`、`translations.json`、`body.meta.json` 及 `body.pages/*.bin`）。
/// `project.json` 只有书名和计数，明文便于排查。
enum PayloadCipher {
    /// 文件头标识。固定 8 字节；变更该标识将视为格式变更，旧文件将按明文触发重新迁移。
    private static let magic = Data("FRTHENC1".utf8)

    private static let lock = NSLock()
    /// 主密钥在进程内单例缓存；Keychain 读写涉及跨进程系统调用，
    /// 缓存可避免高频自动保存任务产生不必要的系统调用开销。
    private static var cachedKey: SymmetricKey?

    static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    /// AES-256-GCM 加密，返回可直接落盘的字节。
    static func seal(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: try masterKey())
        guard let combined = sealed.combined else {
            throw PayloadCipherError.sealFailed
        }
        return magic + combined
    }

    /// 解密。没有魔数的文件按明文原样返回，由调用方决定是否迁移。
    static func open(_ data: Data) throws -> Data {
        guard isEncrypted(data) else { return data }
        let combined = data.dropFirst(magic.count)
        guard let box = try? AES.GCM.SealedBox(combined: combined) else {
            throw PayloadCipherError.invalidCiphertext
        }
        return try AES.GCM.open(box, using: try masterKey())
    }

    #if DEBUG
    /// 自检/模拟器没有 Keychain 权限时使用进程内密钥。
    /// 只影响带 `-runSelfCheck` 的调试进程，生产保存仍要求 Keychain 写入成功。
    static func useSelfCheckKey() {
        lock.lock()
        defer { lock.unlock() }
        if cachedKey == nil {
            cachedKey = SymmetricKey(size: .bits256)
        }
    }
    #endif

    /// 获取主密钥；若不存在则生成并持久化至 Keychain。
    ///
    /// 写入后执行回读校验：防止 Keychain 写入失败而仅使用内存临时密钥加密，
    /// 避免应用重启后导致加密数据无法解密。
    private static func masterKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        switch Keychain.readPayloadKey() {
        case .found(let stored):
            guard stored.count == SymmetricKeySize.bits256.bitCount / 8 else {
                throw PayloadCipherError.keyUnavailable
            }
            let key = SymmetricKey(data: stored)
            cachedKey = key
            return key
        case .notFound:
            let key = SymmetricKey(size: .bits256)
            let raw = key.withUnsafeBytes { Data($0) }
            let status = Keychain.setPayloadKey(raw)
            guard status == errSecSuccess, Keychain.payloadKey() == raw else {
                throw PayloadCipherError.keyUnavailable
            }
            cachedKey = key
            return key
        case .failed:
            // 锁屏或受限状态下读不到 Keychain 时绝不覆盖现有主密钥。
            throw PayloadCipherError.keyUnavailable
        }
    }
}

enum PayloadCipherError: LocalizedError {
    case keyUnavailable
    case sealFailed
    case invalidCiphertext

    var errorDescription: String? {
        switch self {
        case .keyUnavailable:
            return "无法在 Keychain 中创建书稿加密密钥"
        case .sealFailed:
            return "书稿加密失败"
        case .invalidCiphertext:
            return "书稿密文格式损坏"
        }
    }
}
