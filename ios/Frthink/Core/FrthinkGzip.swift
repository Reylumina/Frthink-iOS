import Compression
import Foundation

/// RFC 1952 gzip 容器。
///
/// Android 用 `GZIPInputStream` / `GZIPOutputStream`，两边都不认 zlib 头，所以
/// 这里自己补 10 字节头 + CRC32/ISIZE 尾，中间的压缩数据用 `Compression` 框架
/// 的 `COMPRESSION_ZLIB`（它给的是裸 DEFLATE，正好是 gzip 要的那段）。
///
/// 只处理单 member 的 gzip。Android 导出侧写出来的一定是单 member；多 member
/// 串联（`cat a.gz b.gz`）不在支持范围，会按「备份内容损坏」报错。
enum FrthinkGzip {

    /// 压缩。头部 MTIME 固定 0，同样输入产出同样字节，便于自检比对。
    static func compress(_ data: Data) throws -> Data {
        var output = Data()
        // ID1 ID2 CM FLG MTIME(4) XFL OS
        output.append(Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        output.append(try deflate(data))
        appendLittleEndian(crc32(data), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &output)
        return output
    }

    /// 解压。`maxOutputBytes` 是解压后的上限，超了抛
    /// `.outputLimitExceeded`（对应「解压后的备份超过 300 MiB」）。
    static func decompress(_ data: Data, maxOutputBytes: Int = FrthinkArchive.maxBytes) throws -> Data {
        // 最小合法 gzip：10 字节头 + 空 DEFLATE 块 + 8 字节尾。
        guard data.count >= 19 else { throw FrthinkGzipError.truncated }
        guard data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            throw FrthinkGzipError.notGzip
        }
        let method = data[data.startIndex + 2]
        guard method == 0x08 else {
            throw FrthinkGzipError.unsupportedMethod(method)
        }
        let flags = data[data.startIndex + 3]
        let end = data.endIndex
        var offset = data.startIndex + 10

        // FEXTRA：XLEN(2) + XLEN 字节。
        if flags & 0x04 != 0 {
            guard offset + 2 <= end else { throw FrthinkGzipError.truncated }
            let length = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + length
            guard offset <= end else { throw FrthinkGzipError.truncated }
        }
        // FNAME / FCOMMENT：NUL 结尾的字符串。
        if flags & 0x08 != 0 {
            while offset < end && data[offset] != 0 { offset += 1 }
            offset += 1
            guard offset <= end else { throw FrthinkGzipError.truncated }
        }
        if flags & 0x10 != 0 {
            while offset < end && data[offset] != 0 { offset += 1 }
            offset += 1
            guard offset <= end else { throw FrthinkGzipError.truncated }
        }
        // FHCRC：头校验 2 字节，跳过（正文的 CRC32 才是我们要验的）。
        if flags & 0x02 != 0 {
            offset += 2
            guard offset <= end else { throw FrthinkGzipError.truncated }
        }

        guard end - offset >= 9 else { throw FrthinkGzipError.truncated }
        let trailer = end - 8
        let expectedCRC = littleEndian32(data, at: trailer)
        let expectedSize = littleEndian32(data, at: trailer + 4)

        // 被截断的文件会把尾部的 CRC/ISIZE 读歪成天文数字。DEFLATE 的最大压缩比
        // 约 1032:1，按压缩后的字节数反推一个上限，先挡掉明显不可能的长度，
        // 免得把「文件损坏」报成「超过 300 MiB」。
        let deflateCount = trailer - offset
        let plausibleMax = deflateCount * 1100 + 4096
        guard Int(expectedSize) <= plausibleMax else { throw FrthinkGzipError.truncated }
        guard Int(expectedSize) <= maxOutputBytes else {
            throw FrthinkGzipError.outputLimitExceeded
        }

        // ISIZE 就是解压后的长度，先按它开缓冲区：解压结果显示比它长会直接
        // 解不开（不会留下被截断的内容）。
        let capacity = max(Int(expectedSize), 1)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let decodedSize: Int = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let start = base.assumingMemoryBound(to: UInt8.self) + (offset - data.startIndex)
            return compression_decode_buffer(
                destination,
                capacity,
                start,
                trailer - offset,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decodedSize == Int(expectedSize) else { throw FrthinkGzipError.inflateFailed }
        let decoded = Data(bytes: UnsafeRawPointer(destination), count: decodedSize)
        guard crc32(decoded) == expectedCRC else {
            throw FrthinkGzipError.checksumMismatch
        }
        return decoded
    }

    /// CRC-32（IEEE 802.3）。gzip 尾部的校验值就是它。
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1
                    ? (0xEDB8_8320 ^ (value >> 1))
                    : (value >> 1)
            }
            table[index] = value
        }
        return table
    }()

    /// 裸 DEFLATE（RFC 1951）。
    private static func deflate(_ data: Data) throws -> Data {
        // 空输入没有可压的内容，直接用标准的空固定块。
        guard !data.isEmpty else { return Data([0x03, 0x00]) }

        // zlib 的 compressBound 是 n + n/4096*5 + 6，这里按 n/8 留足余量；
        // 万一还不够就翻倍重试。
        var capacity = data.count + data.count / 8 + 1024
        while capacity <= data.count * 8 + 1024 {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            let written: Int = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return compression_encode_buffer(
                    destination,
                    capacity,
                    base.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            if written > 0 {
                let output = Data(bytes: UnsafeRawPointer(destination), count: written)
                destination.deallocate()
                return output
            }
            destination.deallocate()
            capacity *= 2
        }
        throw FrthinkGzipError.deflateFailed
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func littleEndian32(_ data: Data, at index: Data.Index) -> UInt32 {
        UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }
}

/// gzip 容器层错误。由存档层翻成上屏文案。
enum FrthinkGzipError: Error {
    case truncated
    case notGzip
    case unsupportedMethod(UInt8)
    case inflateFailed
    case deflateFailed
    case checksumMismatch
    case outputLimitExceeded
}
