import CoreGraphics

/// 弹出列表的位置：默认在鼠标右下方；靠近屏幕边缘时翻到另一侧，并始终留在屏幕可见区域内
public enum PanelPlacement {
    /// 列表和鼠标之间的间距
    public static let gap: CGFloat = 8

    /// - Parameters:
    ///   - mouse: 鼠标位置（屏幕坐标，原点在左下角）
    ///   - size: 列表尺寸
    ///   - visibleFrame: 鼠标所在屏幕的可见区域（不含菜单栏和程序坞）
    public static func origin(mouse: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        var x = mouse.x + gap
        var y = mouse.y - gap - size.height
        // 右边放不下 → 放到鼠标左边
        if x + size.width > visibleFrame.maxX {
            x = mouse.x - gap - size.width
        }
        // 下面放不下 → 放到鼠标上面
        if y < visibleFrame.minY {
            y = mouse.y + gap
        }
        // 最后夹在可见区域内；屏幕比列表还小时，优先保证左上角可见
        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - size.width))
        y = min(visibleFrame.maxY - size.height, max(y, visibleFrame.minY))
        return CGPoint(x: x, y: y)
    }
}
