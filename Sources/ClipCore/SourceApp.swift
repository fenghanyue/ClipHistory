import AppKit

/// 内容的来源 App
public struct SourceApp: Equatable {
    /// nil 表示没有 Bundle ID（极少见，比如命令行进程）
    public let bundleID: String?
    /// App 显示名，如"飞书"
    public let name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }

    /// 子进程归到主 App：com.electron.lark.helper → com.electron.lark
    ///（第 0 步实测：在飞书里复制聊天图片时，前台 App 是飞书的子进程 "Lark Helper"）
    public static func mainBundleID(for bundleID: String) -> String {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let helperIndex = parts.firstIndex(where: { $0.lowercased() == "helper" }), helperIndex > 0 else {
            return bundleID
        }
        return parts[..<helperIndex].joined(separator: ".")
    }
}

/// 查询系统里的 App 信息
public enum AppInfo {
    /// 当前前台 App，子进程归到主 App 名下
    public static func frontmost() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let bundleID = app.bundleIdentifier else {
            return app.localizedName.map { SourceApp(bundleID: nil, name: $0) }
        }
        let mainID = SourceApp.mainBundleID(for: bundleID)
        return SourceApp(bundleID: mainID, name: displayName(bundleID: mainID) ?? app.localizedName)
    }

    /// App 显示名（如 com.electron.lark → 飞书）；系统里找不到该 App 时返回 nil
    public static func displayName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
