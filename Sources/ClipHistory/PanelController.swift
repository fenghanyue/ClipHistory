import AppKit
import Carbon.HIToolbox
import ClipCore
import SwiftUI

/// 弹出列表的窗口：不激活本 App（输入框所在的 App 一直保持在前台），但能接收键盘操作
final class HistoryPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        // 在所有桌面空间、全屏 App 上都能弹出
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 管理弹出列表：显示位置、键盘操作、点外面关闭、选中后自动输入
final class PanelController: NSObject, NSWindowDelegate {
    static let panelSize = NSSize(width: 400, height: 460)

    private let store: ClipStore
    private let model: HistoryModel
    private let panel = HistoryPanel(size: PanelController.panelSize)
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// 呼出列表前的前台 App：选中的内容要输入到它的输入框里
    private var targetApp: NSRunningApplication?

    /// - Parameters:
    ///   - pauseState: 读取当前是否暂停记录
    ///   - onTogglePause: 切换暂停 / 恢复记录，返回切换后是否处于暂停
    init(store: ClipStore, pauseState: @escaping () -> Bool, onTogglePause: @escaping () -> Bool) {
        self.store = store
        model = HistoryModel(store: store)
        model.pauseState = pauseState
        model.onTogglePause = onTogglePause
        super.init()
        panel.delegate = self

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        background.material = .popover
        background.blendingMode = .behindWindow
        // 本 App 不在前台时也保持正常外观（否则会变灰）
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 10)
        let hostingView = NSHostingView(rootView: HistoryView(model: model))
        hostingView.frame = background.bounds
        hostingView.autoresizingMask = [.width, .height]
        background.addSubview(hostingView)
        panel.contentView = background

        model.onPick = { [weak self] item in
            self?.pick(item)
        }
        model.onOpenAccessibilitySettings = { [weak self] in
            self?.close()
            Paster.requestTrust()
            Paster.openAccessibilitySettings()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        targetApp = NSWorkspace.shared.frontmostApplication
        model.prepareForShow()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: Self.panelSize)
        panel.setFrameOrigin(PanelPlacement.origin(mouse: mouse, size: Self.panelSize, visibleFrame: visibleFrame))
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        startMonitors()
    }

    func close() {
        stopMonitors()
        panel.orderOut(nil)
    }

    // 点了列表外面（其他 App、桌面）→ 列表失去键盘焦点 → 关闭
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - 键盘与鼠标

    private func startMonitors() {
        stopMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            self.handleKey(event)
            // 列表打开期间吞掉所有按键，避免系统"咚"的提示音
            return nil
        }
        // 兜底：点击其他 App 的窗口时关闭（监听鼠标点击不需要额外权限）
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func stopMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    private func handleKey(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_DownArrow:
            model.moveSelection(by: 1)
        case kVK_UpArrow:
            model.moveSelection(by: -1)
        case kVK_LeftArrow:
            model.switchTab(.recent)
        case kVK_RightArrow:
            model.switchTab(.pinned)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.pickSelected()
        default:
            // 其他按键（包括数字键）不做任何操作
            break
        }
    }

    // MARK: - 选中后自动输入

    private func pick(_ listedItem: ClipItem) {
        // 按 id 重新读取完整记录：列表里的数据可能已经过时（比如刚被清理）
        guard let item = try? store.item(id: listedItem.id) else {
            NSSound.beep()
            return
        }
        let target = targetApp
        close()

        let rich = try? store.richPayload(id: item.id)
        guard Paster.write(item: item, images: store.images, rich: rich) else {
            NSSound.beep()
            DebugLog.write("选中输入失败：条目 #\(item.id) 无法写入剪贴板（图片文件可能丢失）")
            return
        }
        try? store.markUsed(id: item.id)

        guard Paster.isTrusted else {
            Toast.show("已复制，按 ⌘V 粘贴（开启辅助功能后可自动输入）")
            DebugLog.write("选中条目 #\(item.id)：辅助功能未开启，只复制到剪贴板")
            return
        }

        Paster.waitForModifierRelease {
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.pasteDelay) {
                // 原 App 不在前台（极少见）→ 先切回去再输入
                if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                    target.activate(options: [])
                    DispatchQueue.main.asyncAfter(deadline: .now() + Config.pasteDelay) {
                        Paster.sendCommandV()
                    }
                } else {
                    Paster.sendCommandV()
                }
            }
        }
        DebugLog.write("选中条目 #\(item.id)（\(item.kind.rawValue)，格式副本 \(rich?.representations.count ?? 0) 项），"
            + "输入到 \(target?.localizedName ?? "未知")")
    }

    // MARK: - 外观

    /// 圆角遮罩：让毛玻璃背景有圆角
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
