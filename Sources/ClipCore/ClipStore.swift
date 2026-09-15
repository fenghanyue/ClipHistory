import CryptoKit
import Foundation

public enum ClipKind: String, Equatable {
    case text
    case image
}

/// 一条剪贴板历史（对应 clips 表的一行）
public struct ClipItem: Identifiable, Equatable {
    public let id: Int64
    public let kind: ClipKind
    /// 仅文本条目非空：原文
    public let text: String?
    /// 仅图片条目非空：像素宽高
    public let imageWidth: Int?
    public let imageHeight: Int?
    /// 列表展示用的摘要：文本前 2 行 / "图片 1920×1080"
    public let preview: String
    public let contentHash: String
    public let byteSize: Int
    /// 是否带格式副本（HTML/RTF 等原样保存的表示）
    public let hasRich: Bool
    /// 格式副本文件大小；没有时为 0
    public let richByteSize: Int
    /// 来源 App；都为 nil 表示来源未知
    public let sourceBundleID: String?
    public let sourceName: String?
    public let createdAt: Date
    public let lastCopiedAt: Date
    public let copyCount: Int
    /// nil 表示未收藏
    public let pinnedAt: Date?

    public var isPinned: Bool { pinnedAt != nil }
}

public struct RetentionLimits: Equatable {
    public var maxUnpinnedItems: Int
    public var maxUnpinnedImageBytes: Int
    public var maxUnpinnedRichBytes: Int

    public init(
        maxUnpinnedItems: Int = Config.maxUnpinnedItems,
        maxUnpinnedImageBytes: Int = Config.maxUnpinnedImageBytes,
        maxUnpinnedRichBytes: Int = Config.maxUnpinnedRichBytes
    ) {
        self.maxUnpinnedItems = maxUnpinnedItems
        self.maxUnpinnedImageBytes = maxUnpinnedImageBytes
        self.maxUnpinnedRichBytes = maxUnpinnedRichBytes
    }
}

public enum RecordResult: Equatable {
    /// 新增了一条记录
    case inserted(id: Int64)
    /// 已有同样内容：只更新了时间和次数
    case bumped(id: Int64)
}

public struct ConsistencyReport: Equatable, CustomStringConvertible {
    public var removedRowsMissingImage = 0
    public var removedOrphanFiles = 0
    public var regeneratedThumbnails = 0
    public var clearedMissingRich = 0

    public var description: String {
        "删除缺图记录 \(removedRowsMissingImage) 条，删除孤儿文件 \(removedOrphanFiles) 个，"
            + "重建缩略图 \(regeneratedThumbnails) 个，清理失效格式副本 \(clearedMissingRich) 条"
    }
}

/// 剪贴板历史的存储：SQLite 记录 + 图片文件。
/// 所有公开方法都在内部串行队列上执行，可以从任意线程调用。
public final class ClipStore {
    public let images: ImageStore
    public let payloads: PayloadStore
    private let db: SQLiteDB
    private let retention: RetentionLimits
    private let now: () -> Date
    private let queue = DispatchQueue(label: "local.cliphistory.store")

    public init(directory: URL, retention: RetentionLimits = RetentionLimits(), now: @escaping () -> Date = Date.init) throws {
        try FileManager.default.createPrivateDirectory(at: directory)
        images = try ImageStore(rootDirectory: directory)
        payloads = try PayloadStore(rootDirectory: directory)
        db = try SQLiteDB(path: directory.appendingPathComponent("clips.sqlite").path)
        self.retention = retention
        self.now = now
        try db.execute(Self.schema)
        try migrateColumns()
    }

    /// 给老版本的数据库补上后加的列。按列名检查，天然幂等，不需要版本号
    private func migrateColumns() throws {
        let existing = Set(try db.query("PRAGMA table_info(clips)") { $0.text(1) ?? "" })
        if !existing.contains("rich_file") {
            try db.run("ALTER TABLE clips ADD COLUMN rich_file TEXT")
        }
        if !existing.contains("rich_size") {
            try db.run("ALTER TABLE clips ADD COLUMN rich_size INTEGER NOT NULL DEFAULT 0")
        }
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS clips (
          id               INTEGER PRIMARY KEY,
          kind             TEXT    NOT NULL CHECK (kind IN ('text', 'image')),
          text             TEXT,              -- 仅文本非空；存原文，不 trim、不改换行，保证输入回去一字不差
          image_file       TEXT,              -- 仅图片非空；数据目录下的相对路径 images/<哈希>.png
          image_w          INTEGER,           -- 仅图片非空
          image_h          INTEGER,           -- 仅图片非空
          preview          TEXT    NOT NULL,  -- 列表展示：文本前 2 行 / "图片 1920×1080"
          content_hash     TEXT    NOT NULL UNIQUE, -- SHA256(类型 + 原始字节)，去重依据
          byte_size        INTEGER NOT NULL CHECK (byte_size > 0), -- 文本 UTF-8 字节数 / 图片 PNG 文件大小
          source_bundle_id TEXT,              -- NULL = 来源未知
          source_name      TEXT,              -- NULL = 来源未知
          created_at       REAL    NOT NULL,  -- 首次记录时间（Unix 秒）
          last_copied_at   REAL    NOT NULL,  -- 最近一次复制或选中输入的时间，"最近"页按它倒序
          copy_count       INTEGER NOT NULL DEFAULT 1,
          pinned_at        REAL,              -- NULL = 未收藏；非 NULL = 收藏时间，"收藏"页按它升序
          rich_file        TEXT,              -- NULL = 没有格式副本；否则数据目录下的相对路径 rich/<哈希>.plist
          rich_size        INTEGER NOT NULL DEFAULT 0, -- 格式副本文件大小；没有时为 0
          CHECK ((kind = 'text'  AND text IS NOT NULL AND image_file IS NULL) OR
                 (kind = 'image' AND text IS NULL AND image_file IS NOT NULL AND image_w > 0 AND image_h > 0))
        );
        CREATE INDEX IF NOT EXISTS idx_clips_last_copied ON clips (last_copied_at DESC);
        """

    // MARK: - 写入

    /// 记录一条文本：已有同样内容时只更新时间和次数（并用这次的格式副本覆盖旧的），否则新增并执行保留清理。
    /// 去重只认文本本身，格式副本是挂在记录上的附属，不参与 content_hash
    @discardableResult
    public func recordText(_ text: String, rich: RichPayload? = nil, source: SourceApp?) throws -> RecordResult {
        let rich = Self.normalized(rich)
        return try queue.sync {
            let hash = Self.contentHash(kind: .text, bytes: Data(text.utf8))
            let timestamp = now().timeIntervalSince1970
            if let id = try bumpIfExists(hash: hash, timestamp: timestamp) {
                try replaceRich(id: id, hash: hash, rich: rich)
                return .bumped(id: id)
            }
            // 先写文件再写记录：中途崩溃最多留下孤儿文件（启动校验会清掉）
            let richSize = try rich.map { try payloads.save($0, hash: hash) } ?? 0
            do {
                try db.run("""
                    INSERT INTO clips (kind, text, preview, content_hash, byte_size, rich_file, rich_size, source_bundle_id, source_name, created_at, last_copied_at)
                    VALUES ('text', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        .text(text), .text(Self.textPreview(text)), .text(hash), .integer(Int64(text.utf8.count)),
                        Self.richFileValue(hash: hash, rich: rich), .integer(Int64(richSize)),
                        .optionalText(source?.bundleID), .optionalText(source?.name), .real(timestamp), .real(timestamp),
                    ])
            } catch {
                payloads.delete(hash: hash)
                throw error
            }
            let id = db.lastInsertRowID
            try enforceRetention()
            return .inserted(id: id)
        }
    }

    /// 记录一张图片（data 为剪贴板里的原始数据）
    @discardableResult
    public func recordImage(
        _ data: Data, format: ImageFormat, width: Int, height: Int,
        rich: RichPayload? = nil, source: SourceApp?
    ) throws -> RecordResult {
        let rich = Self.normalized(rich)
        return try queue.sync {
            let hash = Self.contentHash(kind: .image, bytes: data)
            let timestamp = now().timeIntervalSince1970
            if let id = try bumpIfExists(hash: hash, timestamp: timestamp) {
                // 图片文件意外丢失时补存，保证记录一定有对应的图
                if !FileManager.default.fileExists(atPath: images.imageURL(hash: hash).path) {
                    _ = try images.save(data: data, format: format, hash: hash)
                }
                try replaceRich(id: id, hash: hash, rich: rich)
                return .bumped(id: id)
            }
            // 先写文件再写记录：中途崩溃最多留下孤儿文件（启动校验会清掉），不会出现记录指向不存在的图
            let storedBytes = try images.save(data: data, format: format, hash: hash)
            let richSize = try rich.map { try payloads.save($0, hash: hash) } ?? 0
            do {
                try db.run("""
                    INSERT INTO clips (kind, image_file, image_w, image_h, preview, content_hash, byte_size, rich_file, rich_size, source_bundle_id, source_name, created_at, last_copied_at)
                    VALUES ('image', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        .text("images/\(hash).png"), .integer(Int64(width)), .integer(Int64(height)),
                        .text("图片 \(width)×\(height)"), .text(hash), .integer(Int64(storedBytes)),
                        Self.richFileValue(hash: hash, rich: rich), .integer(Int64(richSize)),
                        .optionalText(source?.bundleID), .optionalText(source?.name), .real(timestamp), .real(timestamp),
                    ])
            } catch {
                images.delete(hash: hash)
                payloads.delete(hash: hash)
                throw error
            }
            let id = db.lastInsertRowID
            try enforceRetention()
            return .inserted(id: id)
        }
    }

    /// 选中某条输入之后调用：更新时间（排到最前）并增加次数
    public func markUsed(id: Int64) throws {
        try queue.sync {
            _ = try db.run("UPDATE clips SET last_copied_at = ?, copy_count = copy_count + 1 WHERE id = ?",
                           [.real(now().timeIntervalSince1970), .integer(id)])
        }
    }

    /// 收藏或取消收藏。取消收藏不立即清理，等下次新增记录时按保留策略处理
    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try queue.sync {
            let value: SQLValue = pinned ? .real(now().timeIntervalSince1970) : .null
            try db.run("UPDATE clips SET pinned_at = ? WHERE id = ?", [value, .integer(id)])
        }
    }

    /// 删除一条。收藏的条目不删（要先取消收藏），返回是否真的删除了
    @discardableResult
    public func delete(id: Int64) throws -> Bool {
        try queue.sync {
            let rows = try db.query("SELECT kind, content_hash, pinned_at FROM clips WHERE id = ?", [.integer(id)]) {
                (kind: $0.text(0), hash: $0.text(1) ?? "", isPinned: !$0.isNull(2))
            }
            guard let row = rows.first, !row.isPinned else { return false }
            try db.run("DELETE FROM clips WHERE id = ?", [.integer(id)])
            payloads.delete(hash: row.hash)
            if row.kind == ClipKind.image.rawValue {
                images.delete(hash: row.hash)
            }
            return true
        }
    }

    /// 清空历史（保留收藏），返回删除的条数
    @discardableResult
    public func clearUnpinned() throws -> Int {
        try queue.sync {
            let victims = try db.query("SELECT id, kind, content_hash FROM clips WHERE pinned_at IS NULL") {
                Victim(id: $0.int(0), kind: $0.text(1), hash: $0.text(2) ?? "")
            }
            try deleteVictims(victims)
            return victims.count
        }
    }

    // MARK: - 读取

    /// "最近"页：全部条目按最近复制时间倒序，分页
    public func recent(offset: Int = 0, limit: Int = Config.pageSize) throws -> [ClipItem] {
        try queue.sync {
            try db.query("SELECT \(Self.itemColumns) FROM clips ORDER BY last_copied_at DESC, id DESC LIMIT ? OFFSET ?",
                         [.integer(Int64(limit)), .integer(Int64(offset))], map: Self.makeItem)
        }
    }

    /// "收藏"页：按收藏先后顺序固定排列
    public func pinned() throws -> [ClipItem] {
        try queue.sync {
            try db.query("SELECT \(Self.itemColumns) FROM clips WHERE pinned_at IS NOT NULL ORDER BY pinned_at ASC, id ASC",
                         map: Self.makeItem)
        }
    }

    public func item(id: Int64) throws -> ClipItem? {
        try queue.sync {
            try db.query("SELECT \(Self.itemColumns) FROM clips WHERE id = ?", [.integer(id)], map: Self.makeItem).first
        }
    }

    /// 读取某条记录的格式副本；没有或文件已丢失时返回 nil
    public func richPayload(id: Int64) throws -> RichPayload? {
        try queue.sync {
            let hashes = try db.query("SELECT content_hash FROM clips WHERE id = ? AND rich_file IS NOT NULL",
                                      [.integer(id)]) { $0.text(0) ?? "" }
            guard let hash = hashes.first else { return nil }
            return payloads.load(hash: hash)
        }
    }

    public func counts() throws -> (total: Int, pinned: Int) {
        try queue.sync {
            let row = try db.query("SELECT COUNT(*), COUNT(pinned_at) FROM clips") { (Int($0.int(0)), Int($0.int(1))) }
            return row.first ?? (0, 0)
        }
    }

    // MARK: - 启动一致性校验

    /// 记录在但原图丢了 → 删记录；缩略图丢了 → 用原图重建；文件在但没有记录引用 → 删文件
    public func verifyConsistency() throws -> ConsistencyReport {
        try queue.sync {
            var report = ConsistencyReport()
            let imageRows = try db.query("SELECT id, content_hash FROM clips WHERE kind = 'image'") {
                (id: $0.int(0), hash: $0.text(1) ?? "")
            }
            var referencedHashes = Set<String>()
            try db.transaction {
                for row in imageRows {
                    if FileManager.default.fileExists(atPath: images.imageURL(hash: row.hash).path) {
                        referencedHashes.insert(row.hash)
                    } else {
                        try db.run("DELETE FROM clips WHERE id = ?", [.integer(row.id)])
                        report.removedRowsMissingImage += 1
                    }
                }
            }
            for hash in referencedHashes where !FileManager.default.fileExists(atPath: images.thumbnailURL(hash: hash).path) {
                if (try? images.regenerateThumbnail(hash: hash)) != nil {
                    report.regeneratedThumbnails += 1
                }
            }
            for file in images.storedFiles() where !referencedHashes.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
                report.removedOrphanFiles += 1
            }

            // 格式副本：文件丢了只清掉引用，记录本身保留（文字还在，不该整条删）；没人引用的文件删掉。
            // 放在删缺图记录之后：那些记录带的格式副本这时已经变成孤儿，正好一起清掉
            let richRows = try db.query("SELECT id, content_hash FROM clips WHERE rich_file IS NOT NULL") {
                (id: $0.int(0), hash: $0.text(1) ?? "")
            }
            var referencedRichHashes = Set<String>()
            try db.transaction {
                for row in richRows {
                    if FileManager.default.fileExists(atPath: payloads.payloadURL(hash: row.hash).path) {
                        referencedRichHashes.insert(row.hash)
                    } else {
                        try clearRich(id: row.id)
                        report.clearedMissingRich += 1
                    }
                }
            }
            for file in payloads.storedFiles() where !referencedRichHashes.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
                report.removedOrphanFiles += 1
            }
            return report
        }
    }

    // MARK: - 内部实现（调用方已在 queue 上）

    private struct Victim {
        let id: Int64
        let kind: String?
        let hash: String
    }

    /// 空的格式副本等于没有：统一按 nil 处理，避免出现"标着含格式却读不出东西"的记录
    private static func normalized(_ rich: RichPayload?) -> RichPayload? {
        guard let rich, !rich.isEmpty else { return nil }
        return rich
    }

    private static func richFileValue(hash: String, rich: RichPayload?) -> SQLValue {
        rich == nil ? .null : .text(PayloadStore.relativePath(hash: hash))
    }

    /// 命中已有记录时刷新格式副本：后一次复制覆盖前一次；这次没带格式就把旧的清掉
    private func replaceRich(id: Int64, hash: String, rich: RichPayload?) throws {
        guard let rich else {
            try clearRich(id: id)
            payloads.delete(hash: hash)
            return
        }
        let size = try payloads.save(rich, hash: hash)
        try db.run("UPDATE clips SET rich_file = ?, rich_size = ? WHERE id = ?",
                   [.text(PayloadStore.relativePath(hash: hash)), .integer(Int64(size)), .integer(id)])
    }

    /// 只解除记录对格式副本的引用，不动文件（文件由调用方决定删不删）
    private func clearRich(id: Int64) throws {
        try db.run("UPDATE clips SET rich_file = NULL, rich_size = 0 WHERE id = ?", [.integer(id)])
    }

    /// 已有同样内容：更新时间和次数，返回其 id；没有则返回 nil
    private func bumpIfExists(hash: String, timestamp: Double) throws -> Int64? {
        guard let id = try db.query("SELECT id FROM clips WHERE content_hash = ?", [.text(hash)], map: { $0.int(0) }).first else {
            return nil
        }
        try db.run("UPDATE clips SET last_copied_at = ?, copy_count = copy_count + 1 WHERE id = ?", [.real(timestamp), .integer(id)])
        return id
    }

    /// 保留策略：未收藏的超过条数上限删最旧的；未收藏图片总大小超过上限，从新到旧累加，超出部分删掉
    private func enforceRetention() throws {
        var victims = try db.query("""
            SELECT id, kind, content_hash FROM clips WHERE pinned_at IS NULL
            ORDER BY last_copied_at DESC, id DESC LIMIT -1 OFFSET ?
            """, [.integer(Int64(retention.maxUnpinnedItems))]) {
                Victim(id: $0.int(0), kind: $0.text(1), hash: $0.text(2) ?? "")
            }

        let unpinnedImages = try db.query("""
            SELECT id, content_hash, byte_size FROM clips WHERE pinned_at IS NULL AND kind = 'image'
            ORDER BY last_copied_at DESC, id DESC
            """) { (victim: Victim(id: $0.int(0), kind: ClipKind.image.rawValue, hash: $0.text(1) ?? ""), bytes: Int($0.int(2))) }
        var totalBytes = 0
        let alreadyChosen = Set(victims.map(\.id))
        for image in unpinnedImages {
            totalBytes += image.bytes
            if totalBytes > retention.maxUnpinnedImageBytes, !alreadyChosen.contains(image.victim.id) {
                victims.append(image.victim)
            }
        }
        try deleteVictims(victims)
        try enforceRichBudget()
    }

    /// 格式副本预算：未收藏条目从新到旧累加，超出的只丢格式副本，记录本身保留。
    /// 文字很小又有用，不该因为附件超预算被整条删掉
    private func enforceRichBudget() throws {
        let rows = try db.query("""
            SELECT id, content_hash, rich_size FROM clips WHERE pinned_at IS NULL AND rich_file IS NOT NULL
            ORDER BY last_copied_at DESC, id DESC
            """) { (id: $0.int(0), hash: $0.text(1) ?? "", bytes: Int($0.int(2))) }
        var totalBytes = 0
        for row in rows {
            totalBytes += row.bytes
            guard totalBytes > retention.maxUnpinnedRichBytes else { continue }
            try clearRich(id: row.id)
            payloads.delete(hash: row.hash)
        }
    }

    /// 先删记录（事务）再删文件：中途崩溃只会留下孤儿文件，不会出现记录指向不存在的图
    private func deleteVictims(_ victims: [Victim]) throws {
        guard !victims.isEmpty else { return }
        try db.transaction {
            for victim in victims {
                try db.run("DELETE FROM clips WHERE id = ?", [.integer(victim.id)])
            }
        }
        for victim in victims {
            payloads.delete(hash: victim.hash)
            if victim.kind == ClipKind.image.rawValue {
                images.delete(hash: victim.hash)
            }
        }
    }

    static func contentHash(kind: ClipKind, bytes: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: bytes)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 文本摘要：前 2 个非空行，最多 200 字
    static func textPreview(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let joined = lines.prefix(2).joined(separator: "\n")
        return joined.count > 200 ? String(joined.prefix(200)) + "…" : joined
    }

    private static let itemColumns = """
        id, kind, text, image_w, image_h, preview, content_hash, byte_size, \
        source_bundle_id, source_name, created_at, last_copied_at, copy_count, pinned_at, \
        rich_file, rich_size
        """

    private static func makeItem(_ row: SQLRow) -> ClipItem {
        ClipItem(
            id: row.int(0),
            kind: ClipKind(rawValue: row.text(1) ?? "") ?? .text,
            text: row.text(2),
            imageWidth: row.optionalInt(3).map { Int($0) },
            imageHeight: row.optionalInt(4).map { Int($0) },
            preview: row.text(5) ?? "",
            contentHash: row.text(6) ?? "",
            byteSize: Int(row.int(7)),
            hasRich: row.text(14) != nil,
            richByteSize: Int(row.int(15)),
            sourceBundleID: row.text(8),
            sourceName: row.text(9),
            createdAt: Date(timeIntervalSince1970: row.double(10)),
            lastCopiedAt: Date(timeIntervalSince1970: row.double(11)),
            copyCount: Int(row.int(12)),
            pinnedAt: row.optionalDouble(13).map { Date(timeIntervalSince1970: $0) }
        )
    }
}
