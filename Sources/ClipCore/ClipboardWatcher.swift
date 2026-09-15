import Foundation

/// 剪贴板监视器：定时检查计数器（规则 1–2），有新内容就交给 CaptureFilter（规则 3–9），再写入 ClipStore。
public final class ClipboardWatcher {
    public private(set) var isPaused = false

    /// 新增或更新了记录后，在主线程回调（界面刷新用）
    public var onChange: (() -> Void)?

    private let pasteboard: PasteboardSource
    private let store: ClipStore
    private let limits: CaptureLimits
    private let frontmostApp: () -> SourceApp?
    private let appName: (String) -> String?
    private let log: (String) -> Void
    private let recordQueue = DispatchQueue(label: "local.cliphistory.record")
    private var lastChangeCount: Int
    private var timer: Timer?

    public init(
        pasteboard: PasteboardSource,
        store: ClipStore,
        limits: CaptureLimits = CaptureLimits(),
        frontmostApp: @escaping () -> SourceApp? = AppInfo.frontmost,
        appName: @escaping (String) -> String? = AppInfo.displayName(bundleID:),
        log: @escaping (String) -> Void = DebugLog.write
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.limits = limits
        self.frontmostApp = frontmostApp
        self.appName = appName
        self.log = log
        // 启动基线：启动前就在剪贴板里的内容不补记（否则每次重启都会把一条旧内容带着新时间顶到最前）
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        let timer = Timer(timeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // 加到 common 模式：打开菜单期间也继续检查
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func pause() {
        isPaused = true
        log("暂停记录")
    }

    public func resume() {
        // 恢复基线：暂停期间复制的内容不补记（否则恢复的瞬间会把暂停期间最后一条敏感内容记进去）
        lastChangeCount = pasteboard.changeCount
        isPaused = false
        log("恢复记录")
    }

    /// 检查一次剪贴板。正式运行时由定时器调用，测试时直接调用
    public func poll() {
        let changeCount = pasteboard.changeCount

        // 规则 1：计数器没变 → 什么都不做，不读内容
        guard changeCount != lastChangeCount else { return }

        // 规则 2：暂停中 → 只同步计数器，不读内容
        guard !isPaused else {
            lastChangeCount = changeCount
            return
        }

        guard let item = pasteboard.readFirstItem() else {
            lastChangeCount = changeCount
            return
        }
        let source = resolveSource(marker: item.string(forType: PasteboardType.source))
        let decision = CaptureFilter.decide(item: item, source: source, limits: limits)

        // 读取过程中剪贴板又变了 → 丢弃本次结果、不更新基线，下一轮读最新内容
        guard pasteboard.changeCount == changeCount else { return }
        lastChangeCount = changeCount

        let sourceDesc = source.map { "\($0.name ?? "?")(\($0.bundleID ?? "-"))" } ?? "未知"
        let header = "剪贴板变化 #\(changeCount)  来源=\(sourceDesc)  类型=[\(item.types.joined(separator: ", "))]"
        switch decision {
        case .skip(let reason):
            log("\(header)\n  → 跳过：\(reason.rawValue)")
        case .text(let text, let rich):
            record("\(header)\n  → 记为文本 \(text.utf8.count) 字节，格式副本=\(rich)") {
                try $0.recordText(text, rich: rich.payload, source: source)
            }
        case .image(let data, let format, let width, let height, let rich):
            record("\(header)\n  → 记为图片 \(width)×\(height) \(format.rawValue) \(data.count) 字节，格式副本=\(rich)") {
                try $0.recordImage(data, format: format, width: width, height: height, rich: rich.payload, source: source)
            }
        }
    }

    /// 等待后台写入全部完成（测试用）
    public func waitUntilIdle() {
        recordQueue.sync {}
    }

    /// 来源 App：优先用写入者声明的来源标记，没有就用检测到变化时的前台 App（近似值）
    private func resolveSource(marker: String?) -> SourceApp? {
        if let marker, !marker.isEmpty {
            let mainID = SourceApp.mainBundleID(for: marker)
            return SourceApp(bundleID: mainID, name: appName(mainID))
        }
        return frontmostApp()
    }

    private func record(_ description: String, _ write: @escaping (ClipStore) throws -> RecordResult) {
        recordQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try write(self.store)
                self.log("\(description)，\(result)")
                DispatchQueue.main.async { self.onChange?() }
            } catch {
                self.log("\(description)，写入失败：\(error)")
            }
        }
    }
}
