import AppKit
import ClipCore

/// 在鼠标旁短暂显示的提示：不抢焦点、不挡鼠标，2.5 秒后自动消失
enum Toast {
    private static var currentPanel: NSPanel?

    static func show(_ message: String) {
        currentPanel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 28, height: label.frame.height + 16)
        label.frame.origin = NSPoint(x: 14, y: 8)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = PanelController.roundedMask(radius: 8)
        background.addSubview(label)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = background

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        panel.setFrameOrigin(PanelPlacement.origin(mouse: mouse, size: size, visibleFrame: visibleFrame))
        panel.orderFrontRegardless()
        currentPanel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard currentPanel === panel else { return }
            panel.orderOut(nil)
            currentPanel = nil
        }
    }
}
