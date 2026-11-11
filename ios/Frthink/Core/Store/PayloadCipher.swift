import CryptoKit
import Foundation

/// 书稿落盘加密。
///
/// 原版把正文放在 Room 里，并用 AndroidKeyStore 里的主密钥加密；iOS 这边
/// 对应 Keychain + CryptoKit。落盘文件是「魔数 + nonce + 密文 + 标签」，
/// 魔数用来区分密文和迁移前的明文 JSON。
///
/// 只加密 `payload.json`、`source.json` 和 `translations.json`。
/// `project.json` 只有书名和计数，明文便于排查。
enum PayloadCipher {
    /// 文件头。长度固定 8 字节，改动它就等于换格式，旧文件会按明文重新迁移。
    private static let magic = Data("FRTHENC1".utf8)

    private static let lock = NSLock()
    /// 主密钥只在进程内缓存一次；Keychain 每次读写都要进系统调用，
    /// 而书稿保存是每 2 秒一次的后台任务，不值得每次都查。
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

    /// 取主密钥，没有就生成一个并存进 Keychain。
    ///
    /// 写回后要再读一次：如果 Keychain 写入失败却继续用只存在于内存里的
    /// 密钥加密，重启后这本书就再也解不开了。宁可这次保存失败。
    private static func masterKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        if let stored = Keychain.payloadKey(), stored.count == 32 {
            let key = SymmetricKey(data: stored)
            cachedKey = key
            return key
        }

        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        Keychain.setPayloadKey(raw)
        guard Keychain.payloadKey() == raw else {
            throw PayloadCipherError.keyUnavailable
        }
        cachedKey = key
        return key
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
