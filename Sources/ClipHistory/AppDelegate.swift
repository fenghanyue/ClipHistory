import AppKit
import Carbon.HIToolbox
import ClipCore

/// ClipHistory 自用版 1.0
/// - 后台记录剪贴板历史（ClipboardWatcher → ClipStore），可暂停
/// - ⌥⌘V 在鼠标旁弹出历史列表（最近 / 收藏），选中后自动输入（PanelController）
/// - 菜单栏菜单：显示历史、暂停 / 恢复记录、开启自动输入、清空历史、退出
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var store: ClipStore?
    private var watcher: ClipboardWatcher?
    private var panelController: PanelController?

    private var isPaused: Bool {
        watcher?.isPaused == true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try Config.ensureDataDirectory()
        } catch {
            NSLog("ClipHistory: 无法创建数据目录 \(error)")
        }
        DebugLog.rotateIfNeeded()
        DebugLog.write("===== ClipHistory 启动\(Config.isTestMode ? "（测试模式）" : "")，辅助功能=\(Paster.isTrusted ? "已开启" : "未开启") =====")

        startRecording()

        // 测试模式只做后台记录：不注册快捷键、不显示菜单栏图标、不弹授权窗口
        guard !Config.isTestMode else { return }

        if let store {
            panelController = PanelController(
                store: store,
                pauseState: { [weak self] in self?.isPaused ?? false },
                onTogglePause: { [weak self] in
                    self?.togglePause()
                    return self?.isPaused ?? false
                }
            )
        }
        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | optionKey) { [weak self] in
            self?.togglePanel()
        }
        DebugLog.write("快捷键 ⌥⌘V 注册\(hotKey?.isRegistered == true ? "成功" : "失败（可能被其他 App 占用）")")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        // 首次启动未授权时，弹出系统的授权引导
        if !Paster.isTrusted {
            Paster.requestTrust()
        }
    }

    private func startRecording() {
        do {
            let store = try ClipStore(directory: Config.dataDirectory)
            let report = try store.verifyConsistency()
            DebugLog.write("启动一致性校验：\(report)")
            let watcher = ClipboardWatcher(pasteboard: SystemPasteboard(), store: store)
            watcher.start()
            self.store = store
            self.watcher = watcher
        } catch {
            DebugLog.write("❌ 存储初始化失败：\(error)")
        }
    }

    private func togglePanel() {
        guard let panelController else {
            NSSound.beep()
            return
        }
        panelController.toggle()
    }

    /// 暂停时菜单栏图标换成暂停样式，提醒现在不记录
    private func updateStatusIcon() {
        let symbol = isPaused ? "pause.circle" : "list.clipboard"
        let description = isPaused ? "ClipHistory（已暂停记录）" : "ClipHistory"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    }

    // MARK: - 菜单栏菜单（每次打开时重建，保证状态是最新的）

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(actionItem("显示剪贴板历史（⌥⌘V）", #selector(showPanel)))
        menu.addItem(actionItem(isPaused ? "▶ 恢复记录（当前已暂停）" : "暂停记录", #selector(togglePause)))
        menu.addItem(.separator())
        if let counts = try? store?.counts() {
            menu.addItem(disabledItem("已记录 \(counts.total) 条（收藏 \(counts.pinned) 条）"))
        } else {
            menu.addItem(disabledItem("❌ 存储未就绪（见调试日志）"))
        }
        if Paster.isTrusted {
            menu.addItem(disabledItem("✅ 自动输入：已开启"))
        } else {
            menu.addItem(actionItem("❌ 自动输入：未开启（点击去开启辅助功能）", #selector(openAccessibilitySettings)))
        }
        if hotKey?.isRegistered != true {
            menu.addItem(disabledItem("❌ 快捷键 ⌥⌘V 被其他 App 占用"))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("清空历史（保留收藏）…", #selector(clearHistory)))
        menu.addItem(actionItem("打开调试日志", #selector(openDebugLog)))
        menu.addItem(actionItem("退出 ClipHistory", #selector(quit)))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showPanel() {
        // 等菜单完全收起后再弹出列表，否则列表拿不到键盘焦点
        DispatchQueue.main.async { [weak self] in
            self?.panelController?.show()
        }
    }

    @objc private func togglePause() {
        guard let watcher else { return }
        if watcher.isPaused {
            watcher.resume()
        } else {
            watcher.pause()
        }
        updateStatusIcon()
    }

    @objc private func clearHistory() {
        guard let store else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "会删除所有未收藏的记录（包括图片），收藏的条目会保留。删除后无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let count = try store.clearUnpinned()
            DebugLog.write("清空历史：删除 \(count) 条，收藏保留")
        } catch {
            DebugLog.write("清空历史失败：\(error)")
        }
    }

    @objc private func openAccessibilitySettings() {
        Paster.requestTrust()
        Paster.openAccessibilitySettings()
    }

    @objc private func openDebugLog() {
        NSWorkspace.shared.open(DebugLog.fileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
