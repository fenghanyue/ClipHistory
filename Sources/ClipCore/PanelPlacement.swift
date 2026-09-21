import CoreGraphics

/// 弹出列表的位置：默认在鼠标右下方；靠近屏幕边缘时翻到另一侧，并始终留在屏幕可见区域内
public enum PanelPlacement {
    /// 列表和鼠标之间的间距
    public static let gap: CGFloat = 8

    /// 面板尺寸夹在"最小尺寸"和"屏幕可见区域"之间：在大显示器上调大的尺寸换到小屏幕上时，不会超出屏幕。
    /// 屏幕比最小尺寸还小时以屏幕为准（宁可小一点，也要整个在屏幕里）
    public static func clampedSize(_ size: CGSize, minimum: CGSize, visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(max(size.width, minimum.width), visibleFrame.width),
            height: min(max(size.height, minimum.height), visibleFrame.height)
        )
    }

    /// 弹出时面板的位置和大小：大小用上次拖拽调整后保存的（从没调整过就用默认大小），
    /// 夹在最小尺寸和这块屏幕之间，再按鼠标位置摆放
    public static func frame(
        mouse: CGPoint, savedSize: CGSize?, defaultSize: CGSize, minimumSize: CGSize, visibleFrame: CGRect
    ) -> CGRect {
        let size = clampedSize(savedSize ?? defaultSize, minimum: minimumSize, visibleFrame: visibleFrame)
        return CGRect(origin: origin(mouse: mouse, size: size, visibleFrame: visibleFrame), size: size)
    }

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
