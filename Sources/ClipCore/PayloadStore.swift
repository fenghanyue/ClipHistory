import Foundation

/// 一份"格式表示"：剪贴板类型名 + 原始字节。
/// 不解析、不转换、不理解内容，原样存下来、原样写回去，保证和直接复制粘贴效果一致
public struct RichRepresentation: Equatable {
    public let uti: String
    public let data: Data

    public init(uti: String, data: Data) {
        self.uti = uti
        self.data = data
    }
}

/// 一条记录附带的格式副本。顺序就是复制时剪贴板上的类型顺序，写回时原样保持
public struct RichPayload: Equatable {
    public let representations: [RichRepresentation]

    public init(representations: [RichRepresentation]) {
        self.representations = representations
    }

    public var isEmpty: Bool { representations.isEmpty }

    /// 各表示的字节数之和（不含 plist 自身开销）
    public var byteSize: Int {
        representations.reduce(0) { $0 + $1.data.count }
    }

    /// 日志用的类型短名列表，例如 "html, web-custom-data"
    public var typeSummary: String {
        representations.map { $0.uti.components(separatedBy: ".").last ?? $0.uti }.joined(separator: ", ")
    }
}

public enum PayloadStoreError: Error {
    case encodeFailed
}

/// 格式副本的文件存取：一条记录一个文件 rich/<哈希>.plist。
/// 文件名用记录的 content_hash，和 ImageStore 一样，孤儿文件靠启动校验清理
public final class PayloadStore {
    public let directory: URL

    public init(rootDirectory: URL) throws {
        directory = rootDirectory.appendingPathComponent("rich", isDirectory: true)
        try FileManager.default.createPrivateDirectory(at: directory)
    }

    public func payloadURL(hash: String) -> URL {
        directory.appendingPathComponent("\(hash).plist")
    }

    /// 数据库里存的相对路径
    public static func relativePath(hash: String) -> String {
        "rich/\(hash).plist"
    }

    /// 写入（已存在则覆盖），返回文件大小（字节）。二进制 plist，数组顺序即类型顺序
    @discardableResult
    public func save(_ payload: RichPayload, hash: String) throws -> Int {
        let entries = payload.representations.map { ["uti": $0.uti, "data": $0.data] as [String: Any] }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) else {
            throw PayloadStoreError.encodeFailed
        }
        try data.write(to: payloadURL(hash: hash), options: .atomic)
        return data.count
    }

    /// 读取；文件不存在或内容损坏时返回 nil
    public func load(hash: String) -> RichPayload? {
        guard let data = try? Data(contentsOf: payloadURL(hash: hash)),
              let entries = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [[String: Any]]
        else { return nil }
        let representations = entries.compactMap { entry -> RichRepresentation? in
            guard let uti = entry["uti"] as? String, let bytes = entry["data"] as? Data else { return nil }
            return RichRepresentation(uti: uti, data: bytes)
        }
        return representations.isEmpty ? nil : RichPayload(representations: representations)
    }

    /// 删除（文件不存在也不报错）
    public func delete(hash: String) {
        try? FileManager.default.removeItem(at: payloadURL(hash: hash))
    }

    /// 目录下所有 .plist 文件
    public func storedFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "plist" }
    }
}
