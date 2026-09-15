import Foundation
import Testing
@testable import ClipCore

@Suite("监视器：启动和暂停不补记、自身写回跳过、读取中变化重读")
final class ClipboardWatcherTests {
    let directory: URL
    let store: ClipStore
    let pasteboard = FakePasteboard()

    init() throws {
        let directory = makeTemporaryDirectory()
        self.directory = directory
        store = try ClipStore(directory: directory, now: TestClock().now)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeWatcher(frontmost: SourceApp? = nil) -> ClipboardWatcher {
        ClipboardWatcher(
            pasteboard: pasteboard,
            store: store,
            frontmostApp: { frontmost },
            appName: { _ in "某 App" },
            log: { _ in }
        )
    }

    func recordedTexts(_ watcher: ClipboardWatcher) throws -> [String?] {
        watcher.waitUntilIdle()
        return try store.recent().map(\.text)
    }

    @Test("启动前已在剪贴板里的内容：不补记，也不读取")
    func startupBaseline() throws {
        pasteboard.copy(text: "启动前的内容")
        let watcher = makeWatcher()
        watcher.poll()
        #expect(try recordedTexts(watcher) == [])
        #expect(pasteboard.readCount == 0)
    }

    @Test("新复制的内容被记录，来源取前台 App")
    func recordsNewCopy() throws {
        let watcher = makeWatcher(frontmost: SourceApp(bundleID: "com.microsoft.VSCode", name: "Code"))
        pasteboard.copy(text: "let x = 1")
        watcher.poll()
        #expect(try recordedTexts(watcher) == ["let x = 1"])
        #expect(try store.recent().first?.sourceName == "Code")
    }

    @Test("计数器没变：不读取剪贴板")
    func unchangedDoesNotRead() {
        let watcher = makeWatcher()
        watcher.poll()
        watcher.poll()
        #expect(pasteboard.readCount == 0)
    }

    @Test("暂停期间复制的内容：不读取，恢复后也不补记")
    func pauseAndResume() throws {
        let watcher = makeWatcher()
        watcher.pause()
        pasteboard.copy(text: "secret")
        watcher.poll()
        #expect(pasteboard.readCount == 0)

        watcher.resume()
        watcher.poll()
        #expect(try recordedTexts(watcher) == [])

        pasteboard.copy(text: "恢复后复制的")
        watcher.poll()
        #expect(try recordedTexts(watcher) == ["恢复后复制的"])
    }

    @Test("暂停期间定时器一次都没触发：恢复后也不补记")
    func resumeWithoutPollDuringPause() throws {
        let watcher = makeWatcher()
        watcher.pause()
        pasteboard.copy(text: "secret")
        watcher.resume()
        watcher.poll()
        #expect(try recordedTexts(watcher) == [])
        #expect(pasteboard.readCount == 0)
    }

    @Test("本 App 写回的内容不重复记录")
    func ownWriteSkipped() throws {
        let watcher = makeWatcher()
        pasteboard.copy(text: "写回的内容", [PasteboardType.source: Data(Config.bundleID.utf8)])
        watcher.poll()
        #expect(try recordedTexts(watcher) == [])
    }

    @Test("来源标记优先于前台 App，子进程归到主 App")
    func markerSourceWins() throws {
        let watcher = makeWatcher(frontmost: SourceApp(bundleID: "com.google.Chrome", name: "Chrome"))
        pasteboard.copy(text: "内容", [PasteboardType.source: Data("com.electron.lark.helper".utf8)])
        watcher.poll()
        watcher.waitUntilIdle()
        let item = try #require(try store.recent().first)
        #expect(item.sourceBundleID == "com.electron.lark")
        #expect(item.sourceName == "某 App")
    }

    @Test("带网页格式的复制：文本和格式副本一起落库")
    func recordsRichPayload() throws {
        let watcher = makeWatcher(frontmost: SourceApp(bundleID: "com.electron.lark", name: "飞书"))
        let html = Data("<table><tr><td>A1</td></tr></table>".utf8)
        pasteboard.copy(text: "A1\tB1", ["public.html": html])
        watcher.poll()
        watcher.waitUntilIdle()

        let item = try #require(try store.recent().first)
        #expect(item.text == "A1\tB1")
        #expect(item.hasRich)
        #expect(try store.richPayload(id: item.id) == makeRichPayload([("public.html", html)]))
    }

    @Test("读取过程中剪贴板又变了：本轮丢弃，下一轮只记最新内容")
    func changeDuringRead() throws {
        let watcher = makeWatcher()
        pasteboard.copy(text: "旧内容")
        pasteboard.onRead = { [pasteboard] in pasteboard.copy(text: "新内容") }
        watcher.poll()
        #expect(try recordedTexts(watcher) == [])

        watcher.poll()
        #expect(try recordedTexts(watcher) == ["新内容"])
    }
}
