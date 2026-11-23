import Foundation

/// 剧情因果图谱 WAL 单条增量日志记录：支持节点新增/更新与头指针推进的 O(1) 追加持久化。
enum StoryGraphWALRecord: Codable, Hashable {
    case upsertNode(PlotNode)
    case setHead(String)
}

enum StoryGraphWALError: Error {
    case invalidHeader
    case corruptedFrame
}

/// 剧情因果图谱加密预写式日志（Write-Ahead Log）：
/// 每帧格式为 `[4B 魔数 "FRWL"][4B 大端密文长度][FRTHENC1 AES-256-GCM 密文]`，
/// 支持节点 O(1) 追加写、崩溃截断尾帧自动丢弃以及达阈值自动压实回收。
enum StoryGraphWAL {
    static let magic = Data("FRWL".utf8)
    static let compactionThreshold = 40

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func append(records: [StoryGraphWALRecord], to url: URL) throws {
        guard !records.isEmpty else { return }
        let encoder = makeEncoder()
        var buffer = Data()

        for record in records {
            let plain = try encoder.encode(record)
            let sealed = try PayloadCipher.seal(plain)
            guard sealed.count <= Int(UInt32.max) else {
                throw StoryGraphWALError.corruptedFrame
            }
            var lengthBE = UInt32(sealed.count).bigEndian
            buffer.append(magic)
            withUnsafeBytes(of: &lengthBE) { buffer.append(contentsOf: $0) }
            buffer.append(sealed)
        }

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: buffer)
        try handle.synchronize()
    }

    static func frameCount(at url: URL) -> Int {
        inspect(at: url).count
    }

    static func inspect(at url: URL) -> (count: Int, hasTrailingGarbage: Bool) {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return (0, false)
        }

        var offset = 0
        var count = 0
        while offset + 8 <= data.count {
            let headerStart = data.startIndex + offset
            let headerEnd = headerStart + 4
            guard data[headerStart..<headerEnd] == magic else {
                return (count, true)
            }

            let lenStart = headerEnd
            let lenEnd = lenStart + 4
            let frameLength = Int(readBigEndianUInt32(data[lenStart..<lenEnd]))
            guard frameLength > 0, frameLength <= data.count - offset - 8 else {
                return (count, true)
            }

            count += 1
            offset += 8 + frameLength
        }
        return (count, offset < data.count)
    }

    @discardableResult
    static func replay(
        from url: URL,
        into graph: inout StoryGraph
    ) throws -> (appliedRecords: Int, truncatedTail: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (0, false)
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return (0, false)
        }
        if data.count >= 4 {
            let headEnd = data.startIndex + 4
            if data[data.startIndex..<headEnd] != magic {
                throw StoryGraphWALError.invalidHeader
            }
        }

        let decoder = makeDecoder()
        var offset = 0
        var applied = 0
        var truncatedTail = false

        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 8 else {
                truncatedTail = true
                break
            }

            let magicStart = data.startIndex + offset
            let magicEnd = magicStart + 4
            guard data[magicStart..<magicEnd] == magic else {
                truncatedTail = true
                break
            }

            let lenStart = magicEnd
            let lenEnd = lenStart + 4
            let frameLength = Int(readBigEndianUInt32(data[lenStart..<lenEnd]))
            guard frameLength > 0, frameLength <= data.count - offset - 8 else {
                truncatedTail = true
                break
            }

            let payloadStart = lenEnd
            let payloadEnd = payloadStart + frameLength
            let cipherSlice = Data(data[payloadStart..<payloadEnd])
            let isLastFrame = (offset + 8 + frameLength == data.count)

            guard let plain = try? PayloadCipher.open(cipherSlice),
                  let record = try? decoder.decode(StoryGraphWALRecord.self, from: plain) else {
                if isLastFrame {
                    truncatedTail = true
                    break
                }
                throw StoryGraphWALError.corruptedFrame
            }

            switch record {
            case .upsertNode(let node):
                graph.nodes[node.id] = node
            case .setHead(let headID):
                if graph.nodes[headID] != nil {
                    graph.headNodeID = headID
                }
            }
            applied += 1
            offset += 8 + frameLength
        }

        if truncatedTail {
            if offset == 0 {
                remove(at: url)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.truncate(atOffset: UInt64(offset))
                try? handle.synchronize()
            }
        }

        return (applied, truncatedTail)
    }

    static func remove(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func readBigEndianUInt32(_ bytes: Data.SubSequence) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
