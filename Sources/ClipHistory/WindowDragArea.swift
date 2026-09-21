import AppKit
import SwiftUI

/// 透明的拖动区：放在顶栏的背景里，按住空白处拖动就能移动整个面板。
/// 面板是无边框的，没有标题栏可拖，所以由这个 view 接管鼠标按下，交给系统去拖窗口；
/// 顶栏上的标签页和图标按钮盖在它上面，照常响应点击
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        // 悬浮模式下点过别处，面板可能已经不是 key 窗口；第一下按下就要能拖，不能只拿来激活窗口
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
