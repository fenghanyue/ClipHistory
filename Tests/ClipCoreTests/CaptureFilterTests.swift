import Foundation
import Testing
@testable import ClipCore

/// 真机场景的格式组合取自第 0 步类型探针记录的日志
@Suite("采集过滤规则")
struct CaptureFilterTests {
    let png = makeImageData(.png)
    let tiff = makeImageData(.tiff)
    let blob = Data(repeating: 1, count: 16)
    let html = Data("<table><tr><td>A1</td><td>B1</td></tr></table>".utf8)
    let custom = Data(repeating: 7, count: 32)
    let rtf = Data("{\\rtf1 A1\\tab B1}".utf8)
    let sourceURL = Data("https://example.feishu.cn/sheets/abc".utf8)

    // MARK: - 第 0 步真机场景

    @Test("飞书文档文字（网页格式 + 纯文本）→ 记文本，格式副本按剪贴板原顺序存下")
    func feishuDocumentText() {
        let item = makeSnapshot(ordered: [
            ("public.html", html),
            ("org.chromium.web-custom-data", custom),
            ("org.chromium.source-url", sourceURL),
        ], text: "飞书文档里的一段文字")
        #expect(CaptureFilter.decide(item: item, source: nil) == .text("飞书文档里的一段文字", rich: .payload(
            makeRichPayload([
                ("public.html", html),
                ("org.chromium.web-custom-data", custom),
                ("org.chromium.source-url", sourceURL),
            ])
        )))
    }

    @Test("飞书表格文字单元格（网页格式 + 制表符文本 + 渲染图）→ 记文本，格式副本保留表格结构")
    func feishuSheetTextCells() {
        let item = makeSnapshot(ordered: [
            ("public.html", html),
            ("org.chromium.web-custom-data", custom),
            (PasteboardType.png, png),
        ], text: "A1\tB1\nA2\tB2")
        #expect(CaptureFilter.decide(item: item, source: nil) == .text("A1\tB1\nA2\tB2", rich: .payload(
            makeRichPayload([("public.html", html), ("org.chromium.web-custom-data", custom)])
        )))
    }

    @Test("飞书表格图文单元格（没有文字，只有渲染图 + 网页格式）→ 记图片，格式副本照样存")
    func feishuSheetImageCells() {
        let item = makeSnapshot(ordered: [
            (PasteboardType.png, png),
            ("public.html", html),
            ("org.chromium.web-custom-data", custom),
        ])
        #expect(CaptureFilter.decide(item: item, source: nil) == .image(
            png, format: .png, width: 4, height: 3,
            rich: .payload(makeRichPayload([("public.html", html), ("org.chromium.web-custom-data", custom)]))
        ))
    }

    @Test("飞书聊天图片（PNG + 临时文件路径）→ 记图片")
    func feishuChatImage() {
        let item = makeSnapshot([
            PasteboardType.png: png,
            "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn": blob,
            PasteboardType.fileURL: Data("file:///tmp/lark/image.png".utf8),
        ])
        #expect(CaptureFilter.decide(item: item, source: nil) == .image(png, format: .png, width: 4, height: 3, rich: .none))
    }

    @Test("微信聊天图片（TIFF + 临时文件路径）→ 记图片")
    func wechatChatImage() {
        let item = makeSnapshot([
            PasteboardType.fileURL: Data("file:///tmp/wechat/image.jpg".utf8),
            "com.trolltech.anymime.text--uri-list": Data(),
            PasteboardType.tiff: tiff,
            "com.trolltech.anymime.application--x-qt-image": Data(),
        ])
        #expect(CaptureFilter.decide(item: item, source: nil) == .image(tiff, format: .tiff, width: 4, height: 3, rich: .none))
    }

    @Test("Excel 单元格（纯文本 + PNG/TIFF/PDF 渲染图）→ 只记文本；PDF 和 utf16 不进格式副本")
    func excelCells() {
        let item = makeSnapshot(ordered: [
            ("public.html", html),
            ("public.rtf", rtf),
            ("public.utf16-plain-text", blob),
            ("com.adobe.pdf", blob),
            (PasteboardType.png, png),
            (PasteboardType.tiff, tiff),
        ], text: "A1\tB1\nA2\tB2\n")
        #expect(CaptureFilter.decide(item: item, source: nil) == .text("A1\tB1\nA2\tB2\n", rich: .payload(
            makeRichPayload([("public.html", html), ("public.rtf", rtf)])
        )))
    }

    @Test("Chrome 网页图片 → 记图片；只有来源网址这种附属格式，不算「含格式」")
    func chromeImage() {
        let item = makeSnapshot([
            PasteboardType.png: png,
            "org.chromium.internal.source-rfh-token": blob,
            "org.chromium.source-url": sourceURL,
        ])
        #expect(CaptureFilter.decide(item: item, source: nil) == .image(png, format: .png, width: 4, height: 3, rich: .none))
    }

    @Test("截图（只有 PNG）→ 记图片")
    func screenshot() {
        let item = makeSnapshot([PasteboardType.png: png])
        #expect(CaptureFilter.decide(item: item, source: nil) == .image(png, format: .png, width: 4, height: 3, rich: .none))
    }

    @Test("Finder 复制文件（文件路径 + 文件名文本）→ 跳过，不把文件名当文本记")
    func finderFile() {
        let item = makeSnapshot([
            PasteboardType.fileURL: Data("file:///Users/me/报告.pdf".utf8),
            "public.utf16-external-plain-text": blob,
        ], text: "报告.pdf")
        #expect(CaptureFilter.decide(item: item, source: nil) == .skip(.fileCopy))
    }

    @Test("VS Code 代码 → 原样记文本，保留缩进和换行")
    func vscodeCode() {
        let code = "    let x = 1\n\treturn x\n"
        let item = makeSnapshot(ordered: [("public.html", html), ("org.chromium.web-custom-data", custom)], text: code)
        #expect(CaptureFilter.decide(item: item, source: nil) == .text(code, rich: .payload(
            makeRichPayload([("public.html", html), ("org.chromium.web-custom-data", custom)])
        )))
    }

    // MARK: - 规则 3–5

    @Test("本 App 写回的内容 → 跳过")
    func ownWrite() {
        let item = makeSnapshot([PasteboardType.source: Data(Config.bundleID.utf8)], text: "写回的内容")
        #expect(CaptureFilter.decide(item: item, source: nil) == .skip(.ownWrite))
    }

    @Test("其他 App 的来源标记 → 正常记录")
    func otherAppMarker() {
        let item = makeSnapshot([PasteboardType.source: Data("com.other.app".utf8)], text: "内容")
        #expect(CaptureFilter.decide(item: item, source: nil) == .text("内容", rich: .none))
    }

    @Test("机密 / 临时 / 自动生成标记 → 跳过",
          arguments: [PasteboardType.concealed, PasteboardType.transient, PasteboardType.autoGenerated])
    func sensitiveMarkers(marker: String) {
        let item = makeSnapshot([marker: Data()], text: "password123")
        #expect(CaptureFilter.decide(item: item, source: nil) == .skip(.concealed))
    }

    @Test("来自密码类 App → 跳过")
    func passwordApp() {
        let item = makeSnapshot(text: "password123")
        let keychain = SourceApp(bundleID: "com.apple.keychainaccess", name: "钥匙串访问")
        #expect(CaptureFilter.decide(item: item, source: keychain) == .skip(.passwordApp))
    }

    // MARK: - 规则 6–9 边界

    @Test("只有空白（空格 / 制表符 / 换行 / 全角空格）→ 跳过", arguments: [" ", "\t\n", "\u{3000}\n  ", ""])
    func whitespaceOnly(text: String) {
        #expect(CaptureFilter.decide(item: makeSnapshot(text: text), source: nil) == .skip(.emptyText))
    }

    @Test("空白文本 + 图片 → 记图片")
    func whitespaceWithImage() {
        let item = makeSnapshot([PasteboardType.png: png], text: " \n")
        #expect(CaptureFilter.decide(item: item, source: nil) == .image(png, format: .png, width: 4, height: 3, rich: .none))
    }

    @Test("文本字节数等于上限 → 记；超过上限 → 整条跳过")
    func textSizeBoundary() {
        let limits = CaptureLimits(maxTextBytes: 9, maxImageBytes: .max)
        // 每个汉字 UTF-8 占 3 字节
        #expect(CaptureFilter.decide(item: makeSnapshot(text: "中文字"), source: nil, limits: limits) == .text("中文字", rich: .none))
        #expect(CaptureFilter.decide(item: makeSnapshot(text: "中文字a"), source: nil, limits: limits) == .skip(.textTooLarge))
    }

    @Test("图片数据等于上限 → 记；超过上限 → 跳过")
    func imageSizeBoundary() {
        let item = makeSnapshot([PasteboardType.png: png])
        let atLimit = CaptureLimits(maxTextBytes: .max, maxImageBytes: png.count)
        let belowLimit = CaptureLimits(maxTextBytes: .max, maxImageBytes: png.count - 1)
        #expect(CaptureFilter.decide(item: item, source: nil, limits: atLimit) == .image(png, format: .png, width: 4, height: 3, rich: .none))
        #expect(CaptureFilter.decide(item: item, source: nil, limits: belowLimit) == .skip(.imageTooLarge))
    }

    @Test("图片数据损坏 → 跳过")
    func corruptImage() {
        let item = makeSnapshot([PasteboardType.png: Data("not an image".utf8)])
        #expect(CaptureFilter.decide(item: item, source: nil) == .skip(.imageUndecodable))
    }

    @Test("文件路径 + 损坏的图片数据 → 跳过")
    func fileWithCorruptImage() {
        let item = makeSnapshot([PasteboardType.fileURL: blob, PasteboardType.tiff: Data("bad".utf8)])
        #expect(CaptureFilter.decide(item: item, source: nil) == .skip(.imageUndecodable))
    }

    @Test("飞书表格纯图片单元格（只有空白文本 + 网页格式，剪贴板上一张图都没有）→ 记为带格式内容")
    func feishuSheetImageOnlyCells() {
        let item = makeSnapshot(ordered: [
            ("public.html", html),
            ("org.chromium.internal.source-rfh-token", blob),
            ("org.chromium.web-custom-data", custom),
            ("org.chromium.source-url", sourceURL),
        ], text: "\t\t\n")
        #expect(CaptureFilter.decide(item: item, source: nil) == .rich(
            makeRichPayload([
                ("public.html", html),
                ("org.chromium.web-custom-data", custom),
                ("org.chromium.source-url", sourceURL),
            ]),
            text: "\t\t\n"
        ))
    }

    @Test("完全没有纯文本、只有网页格式 → 也记为带格式内容")
    func richWithoutAnyText() {
        let item = makeSnapshot(ordered: [("public.html", html)])
        #expect(CaptureFilter.decide(item: item, source: nil) == .rich(
            makeRichPayload([("public.html", html)]), text: nil
        ))
    }

    @Test("空白文本但没有格式副本 → 仍然跳过")
    func whitespaceWithoutRich() {
        let item = makeSnapshot(["com.example.private": blob], text: " \n")
        #expect(CaptureFilter.decide(item: item, source: nil) == .skip(.emptyText))
    }

    @Test("空白文本 + 超上限的格式副本 → 仍然跳过，不记空壳")
    func whitespaceWithOversizedRich() {
        let big = Data(repeating: 9, count: 100)
        let item = makeSnapshot(ordered: [("public.html", big)], text: " \n")
        #expect(CaptureFilter.decide(item: item, source: nil, limits: CaptureLimits(maxRichBytes: 99)) == .skip(.emptyText))
    }

    @Test("只有纯文本（备忘录这类）→ 没有格式副本")
    func plainTextOnly() {
        #expect(CaptureFilter.decide(item: makeSnapshot(text: "一段普通文字"), source: nil) == .text("一段普通文字", rich: .none))
    }

    @Test("白名单里的格式但数据是空的 → 跳过这一项")
    func emptyRichData() {
        let item = makeSnapshot(ordered: [("public.html", Data()), ("public.rtf", rtf)], text: "内容")
        #expect(CaptureFilter.decide(item: item, source: nil) == .text("内容", rich: .payload(
            makeRichPayload([("public.rtf", rtf)])
        )))
    }

    @Test("格式副本超过上限 → 整份丢弃，文字照记")
    func richSizeBoundary() {
        let big = Data(repeating: 9, count: 100)
        let item = makeSnapshot(ordered: [("public.html", big), ("public.rtf", big)], text: "内容")
        let atLimit = CaptureLimits(maxRichBytes: 200)
        let belowLimit = CaptureLimits(maxRichBytes: 199)
        #expect(CaptureFilter.decide(item: item, source: nil, limits: atLimit) == .text("内容", rich: .payload(
            makeRichPayload([("public.html", big), ("public.rtf", big)])
        )))
        #expect(CaptureFilter.decide(item: item, source: nil, limits: belowLimit) == .text("内容", rich: .droppedTooLarge(bytes: 200)))
    }

    @Test("图片也带格式副本时，超上限只丢格式，图片照记")
    func richTooLargeWithImage() {
        let big = Data(repeating: 9, count: 100)
        let item = makeSnapshot(ordered: [(PasteboardType.png, png), ("public.html", big)])
        let limits = CaptureLimits(maxRichBytes: 99)
        #expect(CaptureFilter.decide(item: item, source: nil, limits: limits) == .image(
            png, format: .png, width: 4, height: 3, rich: .droppedTooLarge(bytes: 100)
        ))
    }

    @Test("只有私有格式 → 跳过")
    func unsupported() {
        let item = makeSnapshot(["com.example.private": blob])
        #expect(CaptureFilter.decide(item: item, source: nil) == .skip(.unsupported))
    }

    @Test("子进程归到主 App")
    func helperBundleID() {
        #expect(SourceApp.mainBundleID(for: "com.electron.lark.helper") == "com.electron.lark")
        #expect(SourceApp.mainBundleID(for: "com.google.Chrome.helper.renderer") == "com.google.Chrome")
        #expect(SourceApp.mainBundleID(for: "com.example.helperapp") == "com.example.helperapp")
        #expect(SourceApp.mainBundleID(for: "helper") == "helper")
    }
}
