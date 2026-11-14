import Foundation

#if DEBUG
/// Debug 构建里的 gzip 互认自检。
///
/// 仅测试内部压缩与解压无法验证与 Android 端的互操作性，因此额外使用 `gzip(1)`
/// 生成的标准字节流进行解压验证（以下几组 base64 数据由 Python 的 `gzip.compress` 生成，
/// 其中一组包含 FEXTRA/FNAME/FCOMMENT 标志位），并比对 CRC32 标准测试向量。
/// 设置页在 Debug 构建下会自动执行该测试并展示结果，CI 模拟器构建阶段亦会覆盖此流程。
enum FrthinkArchiveSelfTest {

    /// 返回一行摘要：全项通过显示「自检通过」，否则附带首项失败原因。
    static func run() -> String {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // 1. CRC32 标准校验值：crc32("123456789") = 0xCBF43926。
        check("crc32 测试向量", FrthinkGzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)

        // 2. 外部生成的标准 gzip，必须能解开。
        let vectors: [(String, String, String)] = [
            ("empty", "", "H4sIAAAAAAAA/wMAAAAAAAAAAAA="),
            ("ascii", "hello frthink",
             "H4sIAAAAAAAA/8tIzcnJV0grKsnIzMsGACvamDoNAAAA"),
            ("cjk", "Frthink .frthink 存档测试",
             "H4sIAAAAAAAA/3MrKsnIzMtW0EuDMp6unfFs4eJnW7tfrJ8KAHduvZMdAAAA"),
            ("fancyHeader", "带 FEXTRA/FNAME/FCOMMENT 的标准 gzip",
             "H4sIHAECAwQEAwkAWFRSQWhlbGxvZnJ0aGluay50eHQA5a2Y5qGj5rWL6K+VAHu6Y5mCm2tESJCjvpufo6+rvpuzv6+vq1+IwvNZLc8WtD9tb1NIr8osAABmnuYIKAAAAA=="),
        ]

        for (name, expected, base64) in vectors {
            guard let blob = Data(base64Encoded: base64) else {
                failures.append("vector \(name) base64")
                continue
            }
            do {
                let decompressed = try FrthinkGzip.decompress(blob, maxOutputBytes: 1 << 20)
                let text = String(decoding: decompressed, as: UTF8.self)
                check("解标准 gzip \(name)", text == expected)
            } catch {
                failures.append("解标准 gzip \(name): \(error)")
            }

            do {
                let mine = try FrthinkGzip.compress(Data(expected.utf8))
                check(
                    "gzip 头 \(name)",
                    mine.count >= 19 && mine[0] == 0x1F && mine[1] == 0x8B && mine[2] == 0x08
                )
                let round = try FrthinkGzip.decompress(mine, maxOutputBytes: 1 << 20)
                check("往返 \(name)", round == Data(expected.utf8))
            } catch {
                failures.append("往返 \(name): \(error)")
            }
        }

        // 3. zlib（RFC 1950）和截断的 gzip 都必须被拒，避免把 zlib 当 gzip。
        if let zlibBlob = Data(base64Encoded: "eJzLSM3JyVdIKyrJyMzLBgAjsAUr") {
            var rejected = false
            do {
                _ = try FrthinkGzip.decompress(zlibBlob, maxOutputBytes: 1 << 20)
            } catch {
                rejected = true
            }
            check("拒收 zlib", rejected)
        }
        if let asciiBlob = Data(base64Encoded: "H4sIAAAAAAAA/8tIzcnJV0grKsnIzMsGACvamDoNAAAA") {
            var rejected = false
            do {
                _ = try FrthinkGzip.decompress(asciiBlob.dropLast(4), maxOutputBytes: 1 << 20)
            } catch {
                rejected = true
            }
            check("拒收截断 gzip", rejected)
        }

        // 4. 信封整体往返：导出 → 再导入，字段要落回来。
        do {
            let project = Project(id: "selftest", title: "自检书", synopsis: "synopsis")
            let payload = ProjectPayload(
                manuscript: "第一章\n正文",
                chapters: [Chapter(title: "第一章", location: 0)],
                world: WorldBook(longTermRules: "长期规则")
            )
            let backup = FrthinkArchive.ProjectBackup(
                project: project,
                payload: payload,
                sourceText: "原文",
                translations: [],
                universeEntries: []
            )
            let data = try FrthinkArchive.makeProjectArchive([backup])
            let isText = String(decoding: data, as: UTF8.self).contains("\"gzip+base64\"")
            check("信封字段", isText)
            let restored = try FrthinkArchive.readProjectArchive(data)
            check(
                "存档往返",
                restored.projects.count == 1
                    && restored.projects[0].projectId == "selftest"
                    && restored.projects[0].snapshot.projectPayload.manuscript == "第一章\n正文"
            )

            // 全量存档往返；书项目存档不能走全量恢复（否则会把设置清空）。
            let full = try FrthinkArchive.makeFullArchive(
                settings: AppSettings(),
                projects: [backup]
            )
            let fullBack = try FrthinkArchive.readFullBackup(full)
            check(
                "全量存档往返",
                fullBack.formatVersion == 1 && fullBack.projects.count == 1
            )
            var rejectedFull = false
            do {
                _ = try FrthinkArchive.readFullBackup(data)
            } catch FrthinkArchiveError.notAnArchive {
                rejectedFull = true
            } catch {
                // 其它错误也算拒绝。
            }
            check("书项目存档不当全量", rejectedFull)

            // version 2 必须报「不支持的 .frthink 文件格式」。
            let bad = "{\"format\":\"writing-workspace-backup\",\"version\":2,"
                + "\"compression\":\"gzip+base64\",\"createdAt\":0,\"payload\":\"\"}"
            var rejected = false
            do {
                _ = try FrthinkArchive.readProjectArchive(Data(bad.utf8))
            } catch FrthinkArchiveError.unsupportedFormat {
                rejected = true
            } catch {
                // 其他错误亦属于拒绝范畴，但本测试用例旨在专项验证版本校验分支。
            }
            check("拒绝 version 2", rejected)
        } catch {
            failures.append("存档往返: \(error)")
        }

        return failures.isEmpty
            ? "自检通过：\(vectors.count) 组标准 gzip + 信封往返"
            : "自检失败：\(failures.joined(separator: "；"))"
    }
}
#endif
