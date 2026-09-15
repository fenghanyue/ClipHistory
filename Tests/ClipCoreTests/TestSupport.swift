import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ClipCore

/// 按类型构造剪贴板快照；text 非 nil 时自动带上纯文本类型
func makeSnapshot(_ entries: [String: Data] = [:], text: String? = nil) -> PasteboardItemSnapshot {
    var types = Set(entries.keys)
    if text != nil {
        types.insert(PasteboardType.plainText)
    }
    return PasteboardItemSnapshot(
        types: types,
        string: { type in
            if type == PasteboardType.plainText { return text }
            return entries[type].flatMap { String(data: $0, encoding: .utf8) }
        },
        data: { type in
            if type == PasteboardType.plainText { return text.map { Data($0.utf8) } }
            return entries[type]
        }
    )
}

/// 生成一张纯色小图片；seed 不同颜色不同（内容哈希也不同）
func makeImageData(_ format: ImageFormat, width: Int = 4, height: Int = 3, seed: Int = 0) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let shade = CGFloat(seed % 256) / 255
    context.setFillColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let type = (format == .png ? UTType.png : UTType.tiff).identifier as CFString
    let destination = CGImageDestinationCreateWithData(output, type, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// 每个测试一个独立的临时目录
func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipCoreTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 固定起点、每次调用前进 1 秒的时钟，让排序结果可预期
final class TestClock {
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        current += 1
        return current
    }
}

/// 假剪贴板：模拟复制，以及"读取过程中剪贴板又变了"
final class FakePasteboard: PasteboardSource {
    private(set) var changeCount = 100
    private(set) var readCount = 0
    private var text: String?
    private var entries: [String: Data] = [:]
    /// 下一次读取时执行一次的回调
    var onRead: (() -> Void)?

    func copy(text: String? = nil, _ entries: [String: Data] = [:]) {
        self.text = text
        self.entries = entries
        changeCount += 1
    }

    func readFirstItem() -> PasteboardItemSnapshot? {
        readCount += 1
        if let callback = onRead {
            onRead = nil
            callback()
        }
        guard text != nil || !entries.isEmpty else { return nil }
        return makeSnapshot(entries, text: text)
    }
}

extension RecordResult {
    var insertedID: Int64? {
        if case .inserted(let id) = self { return id }
        return nil
    }
}
