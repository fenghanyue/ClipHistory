import Foundation
import Testing
@testable import ClipCore

@Suite("格式副本存取：原样往返、顺序保持、删除与孤儿文件")
final class PayloadStoreTests {
    let directory = makeTemporaryDirectory()

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStore() throws -> PayloadStore {
        try PayloadStore(rootDirectory: directory)
    }

    let payload = makeRichPayload([
        ("public.html", Data("<table><tr><td>A1</td></tr></table>".utf8)),
        ("org.chromium.web-custom-data", Data([0, 1, 2, 255, 0, 128])),
        ("public.rtf", Data(repeating: 9, count: 1024)),
    ])

    @Test("写入再读回：字节和顺序都一字不差")
    func roundTrip() throws {
        let store = try makeStore()
        let bytes = try store.save(payload, hash: "abc")

        #expect(bytes > 0)
        let loaded = try #require(store.load(hash: "abc"))
        #expect(loaded == payload)
        #expect(loaded.representations.map(\.uti) == ["public.html", "org.chromium.web-custom-data", "public.rtf"])
    }

    @Test("同一个哈希再写入：覆盖旧内容")
    func overwrite() throws {
        let store = try makeStore()
        try store.save(payload, hash: "abc")
        let replacement = makeRichPayload([("public.html", Data("<p>新的</p>".utf8))])
        try store.save(replacement, hash: "abc")
        #expect(store.load(hash: "abc") == replacement)
    }

    @Test("文件不存在或内容损坏 → 返回 nil，不崩")
    func missingOrCorrupt() throws {
        let store = try makeStore()
        #expect(store.load(hash: "没写过") == nil)

        try Data("这不是 plist".utf8).write(to: store.payloadURL(hash: "坏的"))
        #expect(store.load(hash: "坏的") == nil)
    }

    @Test("删除：文件不存在也不报错")
    func delete() throws {
        let store = try makeStore()
        try store.save(payload, hash: "abc")
        store.delete(hash: "abc")
        store.delete(hash: "abc")
        #expect(store.load(hash: "abc") == nil)
        #expect(store.storedFiles().isEmpty)
    }

    @Test("列出目录里的副本文件")
    func storedFiles() throws {
        let store = try makeStore()
        try store.save(payload, hash: "aaa")
        try store.save(payload, hash: "bbb")
        #expect(Set(store.storedFiles().map { $0.deletingPathExtension().lastPathComponent }) == ["aaa", "bbb"])
    }

    @Test("字节数统计只算各表示本身")
    func byteSize() {
        #expect(payload.byteSize == 35 + 6 + 1024)
        #expect(payload.typeSummary == "html, web-custom-data, rtf")
    }
}
