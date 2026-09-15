import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClipCore

/// 负责"把内容输入到当前输入框"：写回剪贴板 + 模拟按 ⌘V。
/// 模拟按键需要"辅助功能"权限；没有权限时系统会静默丢弃按键，所以调用前要先检查 isTrusted。
enum Paster {
    /// nspasteboard.org 约定的"来源 App"标记。写回时带上本 App 的 Bundle ID，采集时据此跳过自己写的内容
    static let sourceMarkerType = NSPasteboard.PasteboardType(PasteboardType.source)

    /// 当前剪贴板里图片的 TIFF 按需生成器；剪贴板不持有它，需要自己保留到下一次写入
    private static var currentTIFFProvider: TIFFProvider?

    /// 是否已获得辅助功能权限
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的辅助功能授权引导（只在未授权时弹出）
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 直接打开"系统设置 → 隐私与安全性 → 辅助功能"
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 把一条历史记录写回剪贴板，并附带本 App 的来源标记。
    /// 图片同时提供 PNG 和 TIFF：部分 App 只认 TIFF，但 TIFF 体积大，等对方真正要时才生成。
    ///
    /// rich 是复制当时一起存下来的格式副本（HTML/RTF 等），原样写回去，
    /// 粘贴方（飞书文档、微信）自己挑认识的那一份，只认纯文本的目标（终端、编辑器）会自动降级。
    /// plainOnly = true 时完全不写格式副本，等于本 App 一直以来的行为，也是出问题时的兜底
    @discardableResult
    static func write(item: ClipItem, images: ImageStore, rich: RichPayload?, plainOnly: Bool) -> Bool {
        let pasteboardItem = NSPasteboardItem()
        // 格式副本排在前面：少数 App 会遍历类型列表取第一个认识的，多数 App 按自己的优先级挑，与顺序无关
        if !plainOnly, let rich {
            for representation in rich.representations {
                pasteboardItem.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.uti))
            }
        }
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pasteboardItem.setString(text, forType: .string)
            currentTIFFProvider = nil
        case .image:
            guard let png = try? Data(contentsOf: images.imageURL(hash: item.contentHash)) else { return false }
            pasteboardItem.setData(png, forType: .png)
            let provider = TIFFProvider(png: png)
            pasteboardItem.setDataProvider(provider, forTypes: [.tiff])
            currentTIFFProvider = provider
        }
        pasteboardItem.setString(Config.bundleID, forType: sourceMarkerType)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([pasteboardItem])
    }

    /// 等用户松开 ⌥⌘ 等修饰键后再执行，避免目标 App 收到的是 ⌥⌘V 而不是 ⌘V
    static func waitForModifierRelease(then action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(Config.modifierReleaseTimeout)
        func check() {
            let held = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
            if held.isEmpty || Date() >= deadline {
                action()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
            }
        }
        check()
    }

    /// 模拟按下并松开 ⌘V
    static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        // 0x08 是左 Command 键的设备位，部分 App 只认带设备位的 ⌘
        let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        keyDown?.flags = commandFlags
        keyUp?.flags = commandFlags
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

/// 按需把 PNG 转成 TIFF：只有粘贴目标请求 TIFF 格式时才转换
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = NSImage(data: png)?.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }
}
