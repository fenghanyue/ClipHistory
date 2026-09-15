import AppKit
import ClipCore
import SwiftUI

enum HistoryTab {
    case recent
    case pinned
}

/// 弹出列表的数据和状态：当前标签页、条目、选中项、暂停状态
final class HistoryModel: ObservableObject {
    @Published private(set) var tab: HistoryTab = .recent
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isTrusted = Paster.isTrusted
    @Published private(set) var isPaused = false
    @Published var selectedIndex = 0

    var onPick: ((ClipItem) -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    /// 切换暂停 / 恢复记录，返回切换后是否处于暂停
    var onTogglePause: (() -> Bool)?
    /// 读取当前是否暂停
    var pauseState: () -> Bool = { false }

    private let store: ClipStore
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let iconCache = NSCache<NSString, NSImage>()
    private var lastHoverMouseLocation: NSPoint?

    init(store: ClipStore) {
        self.store = store
    }

    var selectedItem: ClipItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// 每次弹出时调用：回到"最近"页的第一条
    func prepareForShow() {
        tab = .recent
        selectedIndex = 0
        isTrusted = Paster.isTrusted
        isPaused = pauseState()
        lastHoverMouseLocation = NSEvent.mouseLocation
        loadItems(atLeast: 0)
    }

    func switchTab(_ newTab: HistoryTab) {
        guard newTab != tab else { return }
        tab = newTab
        selectedIndex = 0
        loadItems(atLeast: 0)
    }

    /// 滚动到底部时加载下一页（只有"最近"页分页）；按 id 去重，防止翻页期间有新记录导致重复
    func loadMore() {
        guard tab == .recent, hasMore else { return }
        let nextPage = (try? store.recent(offset: items.count, limit: Config.pageSize)) ?? []
        let existingIDs = Set(items.map(\.id))
        items.append(contentsOf: nextPage.filter { !existingIDs.contains($0.id) })
        hasMore = nextPage.count == Config.pageSize
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
        // 快到底时提前加载下一页
        if selectedIndex >= items.count - 5 {
            loadMore()
        }
    }

    func pickSelected() {
        pick(at: selectedIndex)
    }

    func pick(at index: Int) {
        guard items.indices.contains(index) else { return }
        onPick?(items[index])
    }

    func togglePin(_ item: ClipItem) {
        do {
            try store.setPinned(id: item.id, !item.isPinned)
        } catch {
            DebugLog.write("收藏操作失败：\(error)")
        }
        loadItems(atLeast: items.count)
    }

    /// 删除一条；收藏的条目不能删，要先取消收藏（给出提示，而不是点了没反应）
    func delete(_ item: ClipItem) {
        guard !item.isPinned else {
            Toast.show("收藏的条目要先点星星取消收藏，才能删除")
            return
        }
        do {
            try store.delete(id: item.id)
        } catch {
            DebugLog.write("删除失败：\(error)")
        }
        loadItems(atLeast: items.count)
    }

    func togglePause() {
        isPaused = onTogglePause?() ?? isPaused
    }

    /// 鼠标真的移动过才跟着悬停改变选中：键盘上下选择时列表会滚动，不能让静止的鼠标"抢"走选中
    func hover(index: Int) {
        let location = NSEvent.mouseLocation
        guard location != lastHoverMouseLocation else { return }
        lastHoverMouseLocation = location
        selectedIndex = index
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        let key = item.contentHash as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: store.images.thumbnailURL(hash: item.contentHash)) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        let key = bundleID as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    /// 读取当前标签页的数据；收藏、删除之后传入当前条数，保持列表长度和滚动位置不变
    private func loadItems(atLeast minimumCount: Int) {
        switch tab {
        case .recent:
            let limit = max(Config.pageSize, minimumCount)
            let page = (try? store.recent(offset: 0, limit: limit)) ?? []
            items = page
            hasMore = page.count == limit
        case .pinned:
            items = (try? store.pinned()) ?? []
            hasMore = false
        }
        selectedIndex = min(selectedIndex, max(items.count - 1, 0))
    }
}

/// 弹出列表：标签页和暂停按钮、状态提示、历史列表、选中条目的预览
struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isPaused {
                pausedBanner
            }
            if !model.isTrusted {
                permissionBanner
            }
            Divider()
            if model.items.isEmpty {
                emptyState
            } else {
                list
                Divider()
                if let item = model.selectedItem {
                    PreviewFooter(model: model, item: item)
                }
            }
        }
        .frame(width: PanelController.panelSize.width, height: PanelController.panelSize.height)
    }

    private var header: some View {
        HStack(spacing: 2) {
            TabButton(title: "最近", isSelected: model.tab == .recent) {
                model.switchTab(.recent)
            }
            TabButton(title: "收藏", isSelected: model.tab == .pinned) {
                model.switchTab(.pinned)
            }
            Spacer()
            Button {
                model.togglePause()
            } label: {
                Label(model.isPaused ? "恢复记录" : "暂停记录",
                      systemImage: model.isPaused ? "play.circle.fill" : "pause.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(model.isPaused ? Color.orange : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            Text("已暂停：现在复制的内容不会被记录")
                .font(.system(size: 11))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var permissionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("未开启辅助功能：选中后需要自己按 ⌘V")
                .font(.system(size: 11))
            Spacer()
            Button("去开启") {
                model.onOpenAccessibilitySettings?()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.tab == .recent ? "doc.on.clipboard" : "pin")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(model.tab == .recent ? "还没有记录，复制点东西试试" : "还没有收藏\n在「最近」里点条目右边的 ☆ 收藏")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // 编号列宽度按总条数的位数定，保证各行文字左边对齐
                    let numberWidth = CGFloat(String(model.items.count).count) * 7 + 2
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        HistoryRow(model: model, item: item, index: index, numberWidth: numberWidth,
                                   isSelected: index == model.selectedIndex)
                            .id(item.id)
                    }
                    if model.hasMore {
                        // 滚动到底部时加载下一页
                        Color.clear
                            .frame(height: 1)
                            .onAppear { model.loadMore() }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selectedIndex) { _, newIndex in
                guard model.items.indices.contains(newIndex) else { return }
                proxy.scrollTo(model.items[newIndex].id)
            }
        }
    }
}

/// 标签页按钮："最近" / "收藏"
struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 列表里的一行：编号（只做显示）、文本前 2 行或缩略图、来源 App 和时间；
/// 右侧星星收藏 / 取消收藏、叉叉删除
struct HistoryRow: View {
    let model: HistoryModel
    let item: ClipItem
    let index: Int
    let numberWidth: CGFloat
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: numberWidth, alignment: .trailing)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    content
                    SourceLine(model: model, item: item, text: TimeText.describe(item.lastCopiedAt))
                }
            }
            Spacer(minLength: 0)
            // 按钮自己处理点击，不会触发整行的"选中输入"
            RowActionButton(systemImage: item.isPinned ? "star.fill" : "star",
                            color: item.isPinned ? .orange : .secondary) {
                model.togglePin(item)
            }
            RowActionButton(systemImage: "xmark", color: .secondary) {
                model.delete(item)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { model.hover(index: index) }
        }
        .onTapGesture {
            model.pick(at: index)
        }
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .image, let thumbnail = model.thumbnail(for: item) {
            ImageThumbnail(image: thumbnail, item: item, maxSize: CGSize(width: 220, height: 56))
        } else {
            Text(item.preview)
                .font(.system(size: 13))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 行右侧的小图标按钮，鼠标移上去时加深颜色并显示圆形底色
struct RowActionButton: View {
    let systemImage: String
    let color: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color.opacity(isHovering ? 1 : 0.7))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// 列表底部：选中条目的更多内容，方便认出长文本
struct PreviewFooter: View {
    let model: HistoryModel
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item.kind {
            case .text:
                Text(Self.previewText(item.text ?? ""))
                    .font(.system(size: 12))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .image:
                if let thumbnail = model.thumbnail(for: item) {
                    ImageThumbnail(image: thumbnail, item: item, maxSize: CGSize(width: 360, height: 64))
                }
            case .rich:
                // 正文是 HTML 等格式数据，没有可读的纯文字，也不渲染 HTML（会去下载远程图片）
                Text(item.preview)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            SourceLine(model: model, item: item, text: details)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 112)
    }

    private var details: String {
        var parts: [String] = []
        switch item.kind {
        case .text: parts.append("共 \((item.text ?? "").count) 字")
        case .image: parts.append(item.preview)
        case .rich: parts.append("\(item.richByteSize / 1024) KB 格式数据")
        }
        parts.append("复制 \(item.copyCount) 次")
        parts.append("首次 \(TimeText.describe(item.createdAt))")
        return parts.joined(separator: " · ")
    }

    /// 取前 400 个字符用于预览（只显示 4 行，没必要渲染整段长文本）
    static func previewText(_ text: String) -> String {
        text.count > 400 ? String(text.prefix(400)) + "…" : text
    }
}

/// 来源 App 图标 + 名称 + 附加文字；带格式副本的条目额外显示一个"含格式"小标记
struct SourceLine: View {
    let model: HistoryModel
    let item: ClipItem
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            if let icon = model.appIcon(bundleID: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text("\(item.sourceName ?? "未知来源") · \(text)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if item.hasRich {
                Image(systemName: "textformat")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("含格式：粘贴时会保留表格 / 图片 / 样式")
            }
        }
    }
}

/// 按原始比例缩放、不放大的缩略图
struct ImageThumbnail: View {
    let image: NSImage
    let item: ClipItem
    let maxSize: CGSize

    var body: some View {
        let width = CGFloat(item.imageWidth ?? 1)
        let height = CGFloat(item.imageHeight ?? 1)
        let scale = min(1, maxSize.width / width, maxSize.height / height)
        Image(nsImage: image)
            .resizable()
            .frame(width: max(width * scale, 1), height: max(height * scale, 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
