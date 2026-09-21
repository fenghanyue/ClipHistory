import CoreGraphics
import Foundation

/// 记住用户拖拽调整过的面板大小，下次弹出时沿用。存在 UserDefaults 里，重启 App 也保留
public struct PanelSizeStore {
    static let widthKey = "panelWidth"
    static let heightKey = "panelHeight"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取上次保存的大小。从没保存过，或者存的值不合法（不是有限的正数）时返回 nil，由调用方用默认大小
    public func load() -> CGSize? {
        let width = defaults.double(forKey: Self.widthKey)
        let height = defaults.double(forKey: Self.heightKey)
        return Self.isValid(width: width, height: height) ? CGSize(width: width, height: height) : nil
    }

    /// 保存大小；不合法的值直接忽略，保留之前存的
    public func save(_ size: CGSize) {
        guard Self.isValid(width: Double(size.width), height: Double(size.height)) else { return }
        defaults.set(Double(size.width), forKey: Self.widthKey)
        defaults.set(Double(size.height), forKey: Self.heightKey)
    }

    private static func isValid(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
