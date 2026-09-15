import Foundation

/// 所有可调参数集中在这里。改完重新运行 scripts/build_app.sh 生效。
public enum Config {
    /// 应用标识，必须和 Resources/Info.plist 里的 CFBundleIdentifier 一致
    public static let bundleID = "local.cliphistory"

    // MARK: - 采集

    /// 检查剪贴板计数器的间隔（秒）
    public static let pollInterval: TimeInterval = 0.5

    /// 单条文本上限（UTF-8 字节）：超过就整条不记，不截断
    public static let maxTextBytes = 1024 * 1024

    /// 单张图片上限（剪贴板里的原始数据字节）
    public static let maxImageBytes = 20 * 1024 * 1024

    /// 内置密码类 App：从这些 App 复制的内容一律不记（兜底：有的密码 App 不打"机密"标记）
    public static let passwordAppBundleIDs: Set<String> = [
        "com.apple.keychainaccess",   // 钥匙串访问
        "com.apple.Passwords",        // 密码（macOS 15 起）
        "com.1password.1password",    // 1Password 8
        "com.agilebits.onepassword7", // 1Password 7
        "com.bitwarden.desktop",      // Bitwarden
    ]

    // MARK: - 保留

    /// 未收藏条目的条数上限，超过删最旧的
    public static let maxUnpinnedItems = 1000

    /// 未收藏图片的总占用上限（字节），超过删最旧的图片
    public static let maxUnpinnedImageBytes = 500 * 1024 * 1024

    /// 缩略图最长边（像素）
    public static let thumbnailMaxPixels = 320

    /// 列表每页加载条数
    public static let pageSize = 50

    // MARK: - 自动输入

    /// 写入剪贴板后、模拟 ⌘V 前的等待时间（秒）。第 0 步实测 0.1 秒对飞书、微信、VS Code、Excel、Chrome 都够用
    public static let pasteDelay: TimeInterval = 0.1

    /// 等待用户松开快捷键修饰键（⌥⌘ 等）的最长时间（秒），超时后照常继续
    public static let modifierReleaseTimeout: TimeInterval = 2.0

    // MARK: - 数据目录

    /// 测试模式：设置了环境变量 CLIPHISTORY_DATA_DIR。只做后台记录，数据写到指定目录，不碰真实历史
    public static var isTestMode: Bool {
        !(ProcessInfo.processInfo.environment["CLIPHISTORY_DATA_DIR"] ?? "").isEmpty
    }

    /// 数据目录：默认 ~/Library/Application Support/ClipHistory/，测试模式下为 CLIPHISTORY_DATA_DIR
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLIPHISTORY_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipHistory", isDirectory: true)
    }

    /// 确保数据目录存在，并且权限为 700（只有本人可读写）
    public static func ensureDataDirectory() throws {
        try FileManager.default.createPrivateDirectory(at: dataDirectory)
    }
}

extension FileManager {
    /// 创建目录（已存在则跳过），并把权限设为 700
    func createPrivateDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
        try setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
