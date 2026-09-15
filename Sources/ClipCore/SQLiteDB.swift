import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    public var description: String {
        switch self {
        case .open(let message): return "打开数据库失败：\(message)"
        case .prepare(let message, let sql): return "SQL 准备失败：\(message)（\(sql)）"
        case .step(let message, let sql): return "SQL 执行失败：\(message)（\(sql)）"
        }
    }
}

public enum SQLValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    static func optionalText(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }
}

/// 查询结果的一行
public struct SQLRow {
    fileprivate let statement: OpaquePointer

    public func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    public func optionalInt(_ column: Int32) -> Int64? {
        isNull(column) ? nil : int(column)
    }

    public func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    public func optionalDouble(_ column: Int32) -> Double? {
        isNull(column) ? nil : double(column)
    }

    /// 按字节长度读取文本：文本里即使含有 \0 字符也能完整读回
    public func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }
}

/// 系统 SQLite C 接口的薄封装。本身不做线程同步，由调用方保证串行访问（见 ClipStore）
public final class SQLiteDB {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        handle = db
        // WAL 模式：写入更安全，崩溃时不容易损坏数据库
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// 执行一段或多段不带参数的 SQL
    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteError.step(message, sql: sql)
        }
    }

    /// 执行一条带参数、不返回结果的 SQL，返回受影响的行数
    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.step(lastErrorMessage, sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    /// 执行查询，把每一行转换成结果
    public func query<T>(_ sql: String, _ parameters: [SQLValue] = [], map: (SQLRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteError.step(lastErrorMessage, sql: sql)
            }
            results.append(try map(SQLRow(statement: statement)))
        }
        return results
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// 在一个事务里执行，出错时整体回滚
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(lastErrorMessage, sql: sql)
        }
        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            let status: Int32
            switch value {
            case .integer(let number):
                status = sqlite3_bind_int64(statement, position, number)
            case .real(let number):
                status = sqlite3_bind_double(statement, position, number)
            case .text(let string):
                // 显式传字节长度：文本里含 \0 字符时也能完整写入
                status = sqlite3_bind_text(statement, position, string, Int32(string.utf8.count), Self.transient)
            case .null:
                status = sqlite3_bind_null(statement, position)
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw SQLiteError.prepare(lastErrorMessage, sql: sql)
            }
        }
        return statement
    }
}
