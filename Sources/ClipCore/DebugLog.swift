import Foundation

/// 调试日志：追加写入 数据目录/debug.log，用于排查问题。
/// 约定：只写类型名、大小、App 名等元信息，绝不写剪贴板内容本身。
public enum DebugLog {
    public static var fileURL: URL {
        Config.dataDirectory.appendingPathComponent("debug.log")
    }

    private static let queue = DispatchQueue(label: "local.cliphistory.debuglog")

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public static func write(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(timestampFormatter.string(from: now))  \(message)\n"
            let path = fileURL.path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// 启动时调用：日志超过上限就改名为 debug.old.log（覆盖更早的旧日志），避免无限增长
    public static func rotateIfNeeded(maxBytes: Int = 2 * 1024 * 1024) {
        queue.sync {
            let path = fileURL.path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
                  size > maxBytes else { return }
            let oldURL = fileURL.deletingLastPathComponent().appendingPathComponent("debug.old.log")
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.moveItem(atPath: path, toPath: oldURL.path)
        }
    }
}
