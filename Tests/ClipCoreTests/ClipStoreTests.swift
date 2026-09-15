import Foundation
import Testing
@testable import ClipCore

@Suite("存储：去重、保留清理、收藏、一致性校验")
final class ClipStoreTests {
    let directory = makeTemporaryDirectory()
    let clock = TestClock()
    let feishu = SourceApp(bundleID: "com.electron.lark", name: "飞书")

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStore(maxItems: Int = 1000, maxImageBytes: Int = .max, maxRichBytes: Int = .max) throws -> ClipStore {
        try ClipStore(
            directory: directory,
            retention: RetentionLimits(
                maxUnpinnedItems: maxItems,
                maxUnpinnedImageBytes: maxImageBytes,
                maxUnpinnedRichBytes: maxRichBytes
            ),
            now: clock.now
        )
    }

    let htmlTable = makeRichPayload([("public.html", Data("<table><tr><td>A1</td></tr></table>".utf8))])
    let htmlAndCustom = makeRichPayload([
        ("public.html", Data("<table><tr><td>改过了</td></tr></table>".utf8)),
        ("org.chromium.web-custom-data", Data(repeating: 7, count: 32)),
    ])

    func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - 去重与原文保真

    @Test("同样内容再复制：不新增，次数 +1，排到最前")
    func dedupeBumpsToTop() throws {
        let store = try makeStore()
        let id = try #require(try store.recordText("A", source: feishu).insertedID)
        try store.recordText("B", source: nil)
        #expect(try store.recordText("A", source: feishu) == .bumped(id: id))

        let items = try store.recent()
        #expect(items.map(\.text) == ["A", "B"])
        #expect(items[0].copyCount == 2)
        #expect(items[0].sourceName == "飞书")
        #expect(items[1].sourceName == nil)
    }

    @Test("按原文精确去重、一字不差存取（换行、制表符、\\0、emoji）")
    func exactTextFidelity() throws {
        let store = try makeStore()
        let samples = ["hello", "hello\n", "  缩进\n\t制表符\r\n", "含\u{0}空字符", "emoji 👨‍👩‍👧"]
        for sample in samples {
            try store.recordText(sample, source: nil)
        }
        let stored = try store.recent().compactMap(\.text)
        #expect(stored.count == samples.count)
        #expect(Set(stored) == Set(samples))
    }

    @Test("预览：取前 2 个非空行")
    func preview() throws {
        let store = try makeStore()
        try store.recordText("\n\n  第一行  \n\n第二行\n第三行", source: nil)
        #expect(try store.recent().first?.preview == "第一行\n第二行")
    }

    // MARK: - 保留清理

    @Test("未收藏超过条数上限：删最旧的")
    func retentionByCount() throws {
        let store = try makeStore(maxItems: 3)
        for index in 1...5 {
            try store.recordText("\(index)", source: nil)
        }
        #expect(try store.recent().map(\.text) == ["5", "4", "3"])
    }

    @Test("收藏的条目不计入上限、不会被清理")
    func pinnedSurviveRetention() throws {
        let store = try makeStore(maxItems: 2)
        let pinnedID = try #require(try store.recordText("收藏", source: nil).insertedID)
        try store.setPinned(id: pinnedID, true)
        for index in 1...4 {
            try store.recordText("\(index)", source: nil)
        }
        #expect(try store.pinned().map(\.text) == ["收藏"])
        #expect(try store.recent().map(\.text) == ["4", "3", "收藏"])
        let counts = try store.counts()
        #expect(counts.total == 3)
        #expect(counts.pinned == 1)
    }

    @Test("被清理的图片记录，原图和缩略图一起删掉")
    func retentionDeletesImageFiles() throws {
        let store = try makeStore(maxItems: 1)
        try store.recordImage(makeImageData(.png), format: .png, width: 4, height: 3, source: nil)
        let image = try #require(try store.recent().first)
        try store.recordText("新的文本", source: nil)

        #expect(try store.recent().map(\.kind) == [.text])
        #expect(!fileExists(store.images.imageURL(hash: image.contentHash)))
        #expect(!fileExists(store.images.thumbnailURL(hash: image.contentHash)))
    }

    @Test("未收藏图片总大小超过上限：删最旧的图片，文本不受影响")
    func retentionByImageBytes() throws {
        let older = makeImageData(.png, seed: 1)
        let newer = makeImageData(.png, seed: 2)
        let store = try makeStore(maxImageBytes: older.count + newer.count - 1)
        try store.recordImage(older, format: .png, width: 4, height: 3, source: nil)
        try store.recordText("文本", source: nil)
        try store.recordImage(newer, format: .png, width: 4, height: 3, source: nil)

        let items = try store.recent()
        #expect(items.map(\.kind) == [.image, .text])
        #expect(items[0].contentHash == ClipStore.contentHash(kind: .image, bytes: newer))
    }

    // MARK: - 图片

    @Test("图片：原图和缩略图落盘，TIFF 转成 PNG，记录的大小等于文件大小")
    func imageFiles() throws {
        let store = try makeStore()
        try store.recordImage(makeImageData(.tiff, width: 40, height: 30), format: .tiff, width: 40, height: 30, source: nil)
        let item = try #require(try store.recent().first)

        #expect(item.kind == .image)
        #expect(item.text == nil)
        #expect(item.imageWidth == 40)
        #expect(item.imageHeight == 30)
        #expect(item.preview == "图片 40×30")
        let stored = try Data(contentsOf: store.images.imageURL(hash: item.contentHash))
        #expect(stored.starts(with: [0x89, 0x50, 0x4E, 0x47])) // PNG 文件头
        #expect(item.byteSize == stored.count)
        #expect(fileExists(store.images.thumbnailURL(hash: item.contentHash)))
    }

    // MARK: - 收藏、删除、选中输入

    @Test("删除：收藏的删不掉，取消收藏后可以删，图片文件一起删")
    func deleteRespectsPin() throws {
        let store = try makeStore()
        let id = try #require(try store.recordImage(makeImageData(.png), format: .png, width: 4, height: 3, source: nil).insertedID)
        let hash = try #require(try store.item(id: id)).contentHash

        try store.setPinned(id: id, true)
        #expect(try store.delete(id: id) == false)
        #expect(try store.item(id: id) != nil)

        try store.setPinned(id: id, false)
        #expect(try store.delete(id: id) == true)
        #expect(try store.item(id: id) == nil)
        #expect(!fileExists(store.images.imageURL(hash: hash)))
    }

    @Test("选中输入后：排到最前，次数 +1")
    func markUsed() throws {
        let store = try makeStore()
        let id = try #require(try store.recordText("A", source: nil).insertedID)
        try store.recordText("B", source: nil)
        try store.markUsed(id: id)

        let items = try store.recent()
        #expect(items.map(\.text) == ["A", "B"])
        #expect(items[0].copyCount == 2)
    }

    @Test("收藏页按收藏先后固定排列")
    func pinnedOrder() throws {
        let store = try makeStore()
        let first = try #require(try store.recordText("先收藏", source: nil).insertedID)
        let second = try #require(try store.recordText("后收藏", source: nil).insertedID)
        try store.setPinned(id: second, true)
        try store.setPinned(id: first, true)
        try store.markUsed(id: second)
        #expect(try store.pinned().map(\.text) == ["后收藏", "先收藏"])
    }

    @Test("清空历史保留收藏")
    func clearKeepsPinned() throws {
        let store = try makeStore()
        let pinnedID = try #require(try store.recordText("收藏", source: nil).insertedID)
        try store.setPinned(id: pinnedID, true)
        try store.recordText("普通", source: nil)
        try store.recordImage(makeImageData(.png), format: .png, width: 4, height: 3, source: nil)

        #expect(try store.clearUnpinned() == 2)
        #expect(try store.recent().map(\.text) == ["收藏"])
        #expect(store.images.storedFiles().isEmpty)
    }

    // MARK: - 格式副本（富文本）

    @Test("带格式副本的文本：记录标记为含格式，副本文件落盘，内容能原样读回")
    func recordsRichPayload() throws {
        let store = try makeStore()
        let id = try #require(try store.recordText("A1", rich: htmlTable, source: feishu).insertedID)
        let item = try #require(try store.item(id: id))

        #expect(item.hasRich)
        #expect(item.richByteSize > 0)
        #expect(fileExists(store.payloads.payloadURL(hash: item.contentHash)))
        #expect(try store.richPayload(id: id) == htmlTable)
    }

    @Test("去重不受格式影响：同一段文字带格式和不带格式仍然是一条")
    func richDoesNotAffectDedupe() throws {
        let store = try makeStore()
        let id = try #require(try store.recordText("A1", rich: htmlTable, source: feishu).insertedID)
        #expect(try store.recordText("A1", source: nil) == .bumped(id: id))
        #expect(try store.counts().total == 1)
    }

    @Test("再复制一次：格式副本被新的覆盖")
    func richReplacedOnBump() throws {
        let store = try makeStore()
        let id = try #require(try store.recordText("A1", rich: htmlTable, source: feishu).insertedID)
        try store.recordText("A1", rich: htmlAndCustom, source: feishu)
        #expect(try store.richPayload(id: id) == htmlAndCustom)
    }

    @Test("再复制一次但这次没有格式：旧的格式副本被清掉，文件也删掉")
    func richClearedOnPlainBump() throws {
        let store = try makeStore()
        let id = try #require(try store.recordText("A1", rich: htmlTable, source: feishu).insertedID)
        let hash = try #require(try store.item(id: id)).contentHash

        try store.recordText("A1", source: nil)

        #expect(try store.item(id: id)?.hasRich == false)
        #expect(try store.richPayload(id: id) == nil)
        #expect(!fileExists(store.payloads.payloadURL(hash: hash)))
    }

    @Test("图片也能带格式副本（飞书表格里的图文单元格）")
    func recordsRichOnImage() throws {
        let store = try makeStore()
        let id = try #require(try store.recordImage(makeImageData(.png), format: .png, width: 4, height: 3,
                                                    rich: htmlTable, source: feishu).insertedID)
        #expect(try store.item(id: id)?.hasRich == true)
        #expect(try store.richPayload(id: id) == htmlTable)
    }

    @Test("删除和清空历史都会连带删掉格式副本文件")
    func deleteRemovesRichFile() throws {
        let store = try makeStore()
        let id = try #require(try store.recordText("删我", rich: htmlTable, source: nil).insertedID)
        let hash = try #require(try store.item(id: id)).contentHash
        #expect(try store.delete(id: id) == true)
        #expect(!fileExists(store.payloads.payloadURL(hash: hash)))

        try store.recordText("再来一条", rich: htmlTable, source: nil)
        #expect(try store.clearUnpinned() == 1)
        #expect(store.payloads.storedFiles().isEmpty)
    }

    @Test("格式副本超出总预算：只丢最旧的格式副本，记录本身保留")
    func richBudgetDropsPayloadsNotRows() throws {
        let sizing = try makeStore()
        let first = try #require(try sizing.recordText("旧", rich: htmlTable, source: nil).insertedID)
        let payloadBytes = try #require(try sizing.item(id: first)).richByteSize

        // 预算刚好够放一条：最新那条留住，更旧的只丢格式副本，记录和文字都还在
        let store = try makeStore(maxRichBytes: payloadBytes)
        let second = try #require(try store.recordText("新", rich: htmlTable, source: nil).insertedID)

        #expect(try store.item(id: first)?.hasRich == false)
        #expect(try store.item(id: second)?.hasRich == true)
        #expect(try store.recent().map(\.text) == ["新", "旧"])
    }

    @Test("一致性校验：格式副本文件丢了只清引用不删记录，孤儿副本文件删掉")
    func consistencyKeepsRowWhenRichFileMissing() throws {
        let store = try makeStore()
        let id = try #require(try store.recordText("文字还在", rich: htmlTable, source: nil).insertedID)
        let hash = try #require(try store.item(id: id)).contentHash
        try FileManager.default.removeItem(at: store.payloads.payloadURL(hash: hash))
        let orphan = store.payloads.directory.appendingPathComponent("deadbeef.plist")
        try Data([1, 2, 3]).write(to: orphan)

        let report = try store.verifyConsistency()

        #expect(report.clearedMissingRich == 1)
        #expect(report.removedOrphanFiles == 1)
        #expect(try store.item(id: id)?.text == "文字还在")
        #expect(try store.item(id: id)?.hasRich == false)
        #expect(!fileExists(orphan))
    }

    @Test("老版本数据库：打开时自动补上格式副本的列，老数据完好")
    func migratesOldDatabase() throws {
        do {
            let old = try SQLiteDB(path: directory.appendingPathComponent("clips.sqlite").path)
            try old.execute("""
                CREATE TABLE clips (
                  id INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT, image_file TEXT,
                  image_w INTEGER, image_h INTEGER, preview TEXT NOT NULL, content_hash TEXT NOT NULL UNIQUE,
                  byte_size INTEGER NOT NULL, source_bundle_id TEXT, source_name TEXT,
                  created_at REAL NOT NULL, last_copied_at REAL NOT NULL,
                  copy_count INTEGER NOT NULL DEFAULT 1, pinned_at REAL
                );
                INSERT INTO clips (kind, text, preview, content_hash, byte_size, created_at, last_copied_at)
                VALUES ('text', '老数据', '老数据', 'oldhash', 9, 1, 1);
                """)
        }

        let store = try makeStore()
        let item = try #require(try store.recent().first)
        #expect(item.text == "老数据")
        #expect(item.hasRich == false)

        // 补上的列能正常写入
        let id = try #require(try store.recordText("新数据", rich: htmlTable, source: nil).insertedID)
        #expect(try store.richPayload(id: id) == htmlTable)
    }

    // MARK: - 读取与持久化

    @Test("分页读取")
    func paging() throws {
        let store = try makeStore()
        for index in 1...5 {
            try store.recordText("\(index)", source: nil)
        }
        #expect(try store.recent(offset: 1, limit: 2).map(\.text) == ["4", "3"])
    }

    @Test("重新打开数据库，历史还在")
    func persistence() throws {
        try makeStore().recordText("持久化", source: nil)
        #expect(try makeStore().recent().map(\.text) == ["持久化"])
    }

    // MARK: - 启动一致性校验

    @Test("一致性校验：缺原图的记录删掉、孤儿文件删掉、缺缩略图重建")
    func consistency() throws {
        let store = try makeStore()
        try store.recordImage(makeImageData(.png, seed: 1), format: .png, width: 4, height: 3, source: nil)
        try store.recordImage(makeImageData(.png, seed: 2), format: .png, width: 4, height: 3, source: nil)
        let items = try store.recent()
        let losesThumbnail = items[0]
        let losesImage = items[1]
        try FileManager.default.removeItem(at: store.images.imageURL(hash: losesImage.contentHash))
        try FileManager.default.removeItem(at: store.images.thumbnailURL(hash: losesThumbnail.contentHash))
        let orphan = store.images.imagesDirectory.appendingPathComponent("deadbeef.png")
        try Data([1, 2, 3]).write(to: orphan)

        let report = try store.verifyConsistency()

        #expect(report.removedRowsMissingImage == 1)
        #expect(report.regeneratedThumbnails == 1)
        // 孤儿文件 2 个：手工放的 deadbeef.png + 缺原图那条记录遗留的缩略图
        #expect(report.removedOrphanFiles == 2)
        #expect(try store.recent().map(\.id) == [losesThumbnail.id])
        #expect(!fileExists(orphan))
        #expect(fileExists(store.images.thumbnailURL(hash: losesThumbnail.contentHash)))
    }
}
