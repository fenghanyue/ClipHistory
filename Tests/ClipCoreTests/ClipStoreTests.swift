import Foundation
import Testing
@testable import ClipCore

@Suite("存储：不去重、保留清理、收藏、搜索、一致性校验")
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
    let imageCellsHTML = Data("<table><tr><td><img src=\"https://a\"></td><td><img src=\"https://b\"></td></tr></table>".utf8)
    let htmlAndCustom = makeRichPayload([
        ("public.html", Data("<table><tr><td>改过了</td></tr></table>".utf8)),
        ("org.chromium.web-custom-data", Data(repeating: 7, count: 32)),
    ])

    func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - 不去重与原文保真

    @Test("同样内容再复制：新增独立的一条，各自按复制时间排队")
    func duplicateContentInsertsNewRow() throws {
        let store = try makeStore()
        let first = try store.recordText("A", source: feishu)
        try store.recordText("B", source: nil)
        let second = try store.recordText("A", source: feishu)

        #expect(first != second)
        let items = try store.recent()
        #expect(items.map(\.id) == [second, items[1].id, first])
        #expect(items.map(\.text) == ["A", "B", "A"])
        #expect(items[0].sourceName == "飞书")
        #expect(items[1].sourceName == nil)
    }

    @Test("一字不差存取（换行、制表符、\\0、emoji）")
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
        let pinnedID = try store.recordText("收藏", source: nil)
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

    // MARK: - 收藏、删除

    @Test("删除：收藏的删不掉，取消收藏后可以删，图片文件一起删")
    func deleteRespectsPin() throws {
        let store = try makeStore()
        let id = try store.recordImage(makeImageData(.png), format: .png, width: 4, height: 3, source: nil)
        let hash = try #require(try store.item(id: id)).contentHash

        try store.setPinned(id: id, true)
        #expect(try store.delete(id: id) == false)
        #expect(try store.item(id: id) != nil)

        try store.setPinned(id: id, false)
        #expect(try store.delete(id: id) == true)
        #expect(try store.item(id: id) == nil)
        #expect(!fileExists(store.images.imageURL(hash: hash)))
    }

    @Test("同一张图片复制两次：两条记录共享图片文件，删一条不影响另一条")
    func duplicateImagesShareFiles() throws {
        let store = try makeStore()
        let data = makeImageData(.png)
        let first = try store.recordImage(data, format: .png, width: 4, height: 3, source: nil)
        let second = try store.recordImage(data, format: .png, width: 4, height: 3, source: nil)

        #expect(first != second)
        let items = try store.recent()
        #expect(items.map(\.id) == [second, first])
        let hash = items[0].contentHash

        // 删掉一条：图片文件还在，另一条照常显示
        #expect(try store.delete(id: second) == true)
        #expect(fileExists(store.images.imageURL(hash: hash)))
        #expect(fileExists(store.images.thumbnailURL(hash: hash)))
        #expect(try store.item(id: first)?.kind == .image)

        // 最后一条也删掉：文件才真正删除
        #expect(try store.delete(id: first) == true)
        #expect(!fileExists(store.images.imageURL(hash: hash)))
    }

    @Test("收藏页按收藏先后固定排列")
    func pinnedOrder() throws {
        let store = try makeStore()
        let first = try store.recordText("先收藏", source: nil)
        let second = try store.recordText("后收藏", source: nil)
        try store.setPinned(id: second, true)
        try store.setPinned(id: first, true)
        #expect(try store.pinned().map(\.text) == ["后收藏", "先收藏"])
    }

    @Test("清空历史保留收藏")
    func clearKeepsPinned() throws {
        let store = try makeStore()
        let pinnedID = try store.recordText("收藏", source: nil)
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
        let id = try store.recordText("A1", rich: htmlTable, source: feishu)
        let item = try #require(try store.item(id: id))

        #expect(item.hasRich)
        #expect(item.richByteSize > 0)
        #expect(fileExists(store.payloads.payloadURL(hash: item.contentHash)))
        #expect(try store.richPayload(id: id) == htmlTable)
    }

    @Test("同一段文字带格式和不带格式各记一条，互不影响")
    func richAndPlainAreSeparateRows() throws {
        let store = try makeStore()
        let withRich = try store.recordText("A1", rich: htmlTable, source: feishu)
        let plain = try store.recordText("A1", source: nil)

        #expect(withRich != plain)
        #expect(try store.counts().total == 2)
        #expect(try store.item(id: withRich)?.hasRich == true)
        #expect(try store.item(id: plain)?.hasRich == false)
        // 老记录的格式副本不受后来的纯文本复制影响
        #expect(try store.richPayload(id: withRich) == htmlTable)
    }

    @Test("同内容再复制：格式副本文件同名，后存的覆盖先存的，两条记录读到的都是最新那份")
    func duplicateRichSharesLatestFile() throws {
        let store = try makeStore()
        let first = try store.recordText("A1", rich: htmlTable, source: feishu)
        let second = try store.recordText("A1", rich: htmlAndCustom, source: feishu)

        #expect(first != second)
        #expect(try store.richPayload(id: first) == htmlAndCustom)
        #expect(try store.richPayload(id: second) == htmlAndCustom)
    }

    @Test("删除共享格式副本的一条记录：文件保留给另一条，最后一条删掉时文件才删")
    func deleteSharedRichKeepsFile() throws {
        let store = try makeStore()
        let first = try store.recordText("A1", rich: htmlTable, source: feishu)
        let second = try store.recordText("A1", rich: htmlTable, source: feishu)
        let hash = try #require(try store.item(id: first)).contentHash

        #expect(try store.delete(id: second) == true)
        #expect(try store.richPayload(id: first) == htmlTable)
        #expect(fileExists(store.payloads.payloadURL(hash: hash)))

        #expect(try store.delete(id: first) == true)
        #expect(!fileExists(store.payloads.payloadURL(hash: hash)))
    }

    @Test("图片也能带格式副本（飞书表格里的图文单元格）")
    func recordsRichOnImage() throws {
        let store = try makeStore()
        let id = try store.recordImage(makeImageData(.png), format: .png, width: 4, height: 3,
                                       rich: htmlTable, source: feishu)
        #expect(try store.item(id: id)?.hasRich == true)
        #expect(try store.richPayload(id: id) == htmlTable)
    }

    @Test("删除和清空历史都会连带删掉格式副本文件")
    func deleteRemovesRichFile() throws {
        let store = try makeStore()
        let id = try store.recordText("删我", rich: htmlTable, source: nil)
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
        let first = try sizing.recordText("旧", rich: htmlTable, source: nil)
        let payloadBytes = try #require(try sizing.item(id: first)).richByteSize

        // 预算刚好够放一条：最新那条留住，更旧的只丢格式副本，记录和文字都还在
        let store = try makeStore(maxRichBytes: payloadBytes)
        let second = try store.recordText("新", rich: htmlTable, source: nil)

        #expect(try store.item(id: first)?.hasRich == false)
        #expect(try store.item(id: second)?.hasRich == true)
        #expect(try store.recent().map(\.text) == ["新", "旧"])
    }

    @Test("一致性校验：格式副本文件丢了只清引用不删记录，孤儿副本文件删掉")
    func consistencyKeepsRowWhenRichFileMissing() throws {
        let store = try makeStore()
        let id = try store.recordText("文字还在", rich: htmlTable, source: nil)
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

    @Test("老版本数据库：自动补列 + 搬表去掉去重约束，老数据一条不少、收藏保留")
    func migratesOldDatabase() throws {
        do {
            // 首版的表：没有 rich 两列，CHECK 约束只认 text / image，content_hash 带 UNIQUE，有 copy_count 列
            let old = try SQLiteDB(path: directory.appendingPathComponent("clips.sqlite").path)
            try old.execute("""
                CREATE TABLE clips (
                  id INTEGER PRIMARY KEY,
                  kind TEXT NOT NULL CHECK (kind IN ('text', 'image')),
                  text TEXT, image_file TEXT, image_w INTEGER, image_h INTEGER,
                  preview TEXT NOT NULL, content_hash TEXT NOT NULL UNIQUE,
                  byte_size INTEGER NOT NULL CHECK (byte_size > 0),
                  source_bundle_id TEXT, source_name TEXT,
                  created_at REAL NOT NULL, last_copied_at REAL NOT NULL,
                  copy_count INTEGER NOT NULL DEFAULT 1, pinned_at REAL,
                  CHECK ((kind = 'text'  AND text IS NOT NULL AND image_file IS NULL) OR
                         (kind = 'image' AND text IS NULL AND image_file IS NOT NULL AND image_w > 0 AND image_h > 0))
                );
                CREATE INDEX idx_clips_last_copied ON clips (last_copied_at DESC);
                INSERT INTO clips (kind, text, preview, content_hash, byte_size, source_name, created_at, last_copied_at, copy_count, pinned_at)
                VALUES ('text', '老数据', '老数据', 'oldhash', 9, '飞书', 1, 1, 7, 5);
                INSERT INTO clips (kind, image_file, image_w, image_h, preview, content_hash, byte_size, created_at, last_copied_at)
                VALUES ('image', 'images/oldimg.png', 4, 3, '图片 4×3', 'oldimg', 100, 2, 2);
                """)
        }

        let store = try makeStore()

        // 老数据一条不少，收藏状态、来源都保留
        let items = try store.recent()
        #expect(items.count == 2)
        let oldText = try #require(items.first { $0.text == "老数据" })
        #expect(oldText.isPinned)
        #expect(oldText.sourceName == "飞书")
        #expect(oldText.hasRich == false)
        #expect(try store.pinned().map(\.text) == ["老数据"])
        let keptImageRow = try store.recent().contains { $0.kind == .image }
        #expect(keptImageRow)

        // 补上的列能写，放宽后的约束能放下 rich 记录
        let textID = try store.recordText("新数据", rich: htmlTable, source: nil)
        #expect(try store.richPayload(id: textID) == htmlTable)
        let richID = try store.recordRich(imageCellsPayload(), text: "\t", source: nil)
        #expect(try store.item(id: richID)?.kind == .rich)

        // UNIQUE 约束已去掉：同样的内容可以再记一条
        try store.recordText("新数据", source: nil)
        #expect(try store.recent().filter { $0.text == "新数据" }.count == 2)

        // 再打开一次不会重复搬表
        let reopened = try makeStore()
        #expect(try reopened.counts().total == 5)
    }

    // MARK: - 带格式内容（正文就是格式副本）

    func imageCellsPayload(custom: Data = Data(repeating: 7, count: 8)) -> RichPayload {
        makeRichPayload([("public.html", imageCellsHTML), ("org.chromium.web-custom-data", custom)])
    }

    @Test("飞书纯图片单元格：记成 rich 条目，预览数出图片张数，空白文本原样保留")
    func recordsRichItem() throws {
        let store = try makeStore()
        let id = try store.recordRich(imageCellsPayload(), text: "\t\t\n", source: feishu)
        let item = try #require(try store.item(id: id))

        #expect(item.kind == .rich)
        #expect(item.preview == "带格式内容 · 2 张图")
        #expect(item.text == "\t\t\n")
        #expect(item.hasRich)
        #expect(item.byteSize > 0)
        #expect(try store.richPayload(id: id) == imageCellsPayload())
    }

    @Test("没有 HTML 的带格式内容：预览退回通用说法")
    func richPreviewWithoutHTML() throws {
        let store = try makeStore()
        let payload = makeRichPayload([("public.rtf", Data("{\\rtf1}".utf8))])
        let id = try store.recordRich(payload, text: nil, source: nil)
        #expect(try store.item(id: id)?.preview == "带格式内容")
        #expect(try store.item(id: id)?.text == nil)
    }

    @Test("HTML 相同就共享同一个副本文件：飞书每次复制带的自定义数据变了，文件以最新那份为准")
    func richSharesFileByHTML() throws {
        let store = try makeStore()
        let first = try store.recordRich(imageCellsPayload(custom: Data([1])), text: nil, source: feishu)
        let second = try store.recordRich(imageCellsPayload(custom: Data([2, 2, 2])), text: nil, source: feishu)

        #expect(first != second)
        #expect(try store.counts().total == 2)
        // 两条记录的正文哈希相同（只按 HTML 算），副本文件同名，后存的覆盖先存的
        #expect(try store.richPayload(id: first) == imageCellsPayload(custom: Data([2, 2, 2])))
        #expect(try store.richPayload(id: second) == imageCellsPayload(custom: Data([2, 2, 2])))
    }

    @Test("HTML 不同就是两条")
    func richDifferentHTML() throws {
        let store = try makeStore()
        try store.recordRich(makeRichPayload([("public.html", Data("<p>A</p>".utf8))]), text: nil, source: nil)
        try store.recordRich(makeRichPayload([("public.html", Data("<p>B</p>".utf8))]), text: nil, source: nil)
        #expect(try store.counts().total == 2)
    }

    @Test("一致性校验：rich 条目的副本文件丢了 → 整条删掉，不留空壳")
    func consistencyRemovesRichRowWhenFileMissing() throws {
        let store = try makeStore()
        let id = try store.recordRich(imageCellsPayload(), text: nil, source: nil)
        let hash = try #require(try store.item(id: id)).contentHash
        try FileManager.default.removeItem(at: store.payloads.payloadURL(hash: hash))

        let report = try store.verifyConsistency()

        #expect(report.removedRowsMissingRich == 1)
        #expect(try store.item(id: id) == nil)
    }

    @Test("超出格式副本预算：rich 条目整条删掉，不留没有正文的空壳")
    func richBudgetDeletesRichRows() throws {
        // 两份等长的 HTML：副本文件大小相同，预算刚好只够放一条
        let older = makeRichPayload([("public.html", Data("<p><img src=\"a\"></p>".utf8))])
        let newer = makeRichPayload([("public.html", Data("<p><img src=\"b\"></p>".utf8))])

        let sizing = try makeStore()
        let olderID = try sizing.recordRich(older, text: nil, source: nil)
        let bytes = try #require(try sizing.item(id: olderID)).byteSize

        let store = try makeStore(maxRichBytes: bytes)
        let newerID = try store.recordRich(newer, text: nil, source: nil)

        #expect(try store.item(id: newerID)?.kind == .rich)  // 最新的留住
        #expect(try store.item(id: olderID) == nil)          // 更旧的整条删掉
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

    // MARK: - 搜索

    @Test("搜索：按正文子串匹配，按复制时间倒序，分页")
    func searchByText() throws {
        let store = try makeStore()
        try store.recordText("今天天气不错", source: nil)
        try store.recordText("苹果和香蕉", source: nil)
        try store.recordText("今天的会议纪要", source: nil)

        #expect(try store.search("今天", pinnedOnly: false).map(\.text) == ["今天的会议纪要", "今天天气不错"])
        #expect(try store.search("今天", pinnedOnly: false, offset: 1, limit: 1).map(\.text) == ["今天天气不错"])
        #expect(try store.search("不存在", pinnedOnly: false).isEmpty)
    }

    @Test("搜索：LIKE 通配符按字面量处理，ASCII 不区分大小写")
    func searchEscapesWildcards() throws {
        let store = try makeStore()
        try store.recordText("进度 100% 完成", source: nil)
        try store.recordText("Hello World", source: nil)
        try store.recordText("百分之100", source: nil)

        // % 是 LIKE 通配符，转义后只匹配字面量
        #expect(try store.search("100%", pinnedOnly: false).map(\.text) == ["进度 100% 完成"])
        #expect(try store.search("hello", pinnedOnly: false).map(\.text) == ["Hello World"])
    }

    @Test("搜索：pinnedOnly 只在收藏里找")
    func searchPinnedOnly() throws {
        let store = try makeStore()
        let pinnedID = try store.recordText("收藏的苹果", source: nil)
        try store.recordText("普通的苹果", source: nil)
        try store.setPinned(id: pinnedID, true)

        #expect(try store.search("苹果", pinnedOnly: true).map(\.text) == ["收藏的苹果"])
        #expect(try store.search("苹果", pinnedOnly: false).map(\.text) == ["普通的苹果", "收藏的苹果"])
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
