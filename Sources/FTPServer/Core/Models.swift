import Foundation
import CryptoKit

// MARK: - 日志

enum LogLevel: String, Codable, CaseIterable, Identifiable, Comparable {
    case debug, info, warning, error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .debug:   return "调试"
        case .info:    return "信息"
        case .warning: return "警告"
        case .error:   return "错误"
        }
    }

    var rank: Int {
        switch self {
        case .debug:   return 0
        case .info:    return 1
        case .warning: return 2
        case .error:   return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

struct FTPLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let session: String
    let message: String
}

// MARK: - 口令散列（加盐 SHA256 + 恒定时间比较）

enum PasswordHasher {
    static func makeSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(password: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + password).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verify(password: String, salt: String, expected: String) -> Bool {
        let computed = Array(hash(password: password, salt: salt).utf8)
        let target = Array(expected.utf8)
        guard computed.count == target.count, !target.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in computed.indices { difference |= computed[index] ^ target[index] }
        return difference == 0
    }
}

// MARK: - 账号

struct FTPAccount: Identifiable, Hashable, Codable {
    var id: UUID
    var username: String
    var salt: String
    var passwordHash: String
    var rootPath: String
    var canDownload: Bool
    var canUpload: Bool
    var canDelete: Bool
    var canCreateDirectory: Bool
    var enabled: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, username, salt, passwordHash, rootPath
        case canDownload, canUpload, canDelete, canCreateDirectory, enabled, createdAt
    }

    init(username: String,
         password: String,
         rootPath: String,
         canDownload: Bool = true,
         canUpload: Bool = true,
         canDelete: Bool = true,
         canCreateDirectory: Bool = true,
         enabled: Bool = true) {
        let salt = PasswordHasher.makeSalt()
        self.id = UUID()
        self.username = username
        self.salt = salt
        self.passwordHash = PasswordHasher.hash(password: password, salt: salt)
        self.rootPath = rootPath
        self.canDownload = canDownload
        self.canUpload = canUpload
        self.canDelete = canDelete
        self.canCreateDirectory = canCreateDirectory
        self.enabled = enabled
        self.createdAt = Date()
    }

    /// 逐字段 decodeIfPresent：旧版配置文件缺少新字段时仍可解析，不会整份数据丢失。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        salt = try container.decodeIfPresent(String.self, forKey: .salt) ?? ""
        passwordHash = try container.decodeIfPresent(String.self, forKey: .passwordHash) ?? ""
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) ?? ""
        canDownload = try container.decodeIfPresent(Bool.self, forKey: .canDownload) ?? true
        canUpload = try container.decodeIfPresent(Bool.self, forKey: .canUpload) ?? true
        canDelete = try container.decodeIfPresent(Bool.self, forKey: .canDelete) ?? true
        canCreateDirectory = try container.decodeIfPresent(Bool.self, forKey: .canCreateDirectory) ?? true
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    mutating func setPassword(_ password: String) {
        let newSalt = PasswordHasher.makeSalt()
        salt = newSalt
        passwordHash = PasswordHasher.hash(password: password, salt: newSalt)
    }

    func verify(password: String) -> Bool {
        PasswordHasher.verify(password: password, salt: salt, expected: passwordHash)
    }

    var permissionSummary: String {
        var parts: [String] = []
        if canDownload { parts.append("下载") }
        if canUpload { parts.append("上传") }
        if canDelete { parts.append("删除") }
        if canCreateDirectory { parts.append("建目录") }
        return parts.isEmpty ? "无权限" : parts.joined(separator: "·")
    }

    var effectiveRootPath: String {
        rootPath.isEmpty ? ServerConfig.defaultRootPath() : rootPath
    }
}

// MARK: - 关闭主窗口时的行为

enum CloseBehavior: String, Codable, CaseIterable, Identifiable {
    /// 关闭主窗口即退出软件
    case quit
    /// 关闭主窗口后隐藏 Dock 图标，仅保留菜单栏入口，服务继续运行
    case minimizeToMenuBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quit:             return "退出软件"
        case .minimizeToMenuBar: return "最小化到菜单栏"
        }
    }

    var detail: String {
        switch self {
        case .quit:
            return "关闭窗口即结束进程，FTP 服务随之停止"
        case .minimizeToMenuBar:
            return "关闭窗口后隐藏 Dock 图标并继续在后台提供服务，可从菜单栏图标重新打开"
        }
    }
}

// MARK: - 服务器配置

struct ServerConfig: Codable, Equatable {
    var port: UInt16
    var bindAllInterfaces: Bool
    var defaultRootPath: String
    var anonymousEnabled: Bool
    var anonymousRootPath: String
    var anonymousCanUpload: Bool
    var anonymousCanDelete: Bool
    var anonymousCanCreateDirectory: Bool
    var maxConnections: Int
    var idleTimeout: Double
    var dataTimeout: Double
    var pasvAdvertiseHost: String
    var logLevel: LogLevel
    var accounts: [FTPAccount]
    /// 应用启动后是否自动开始监听。
    var autoStart: Bool
    /// 关闭主窗口时的行为。
    var closeBehavior: CloseBehavior

    enum CodingKeys: String, CodingKey {
        case port, bindAllInterfaces, defaultRootPath
        case anonymousEnabled, anonymousRootPath, anonymousCanUpload
        case anonymousCanDelete, anonymousCanCreateDirectory
        case maxConnections, idleTimeout, dataTimeout, pasvAdvertiseHost
        case logLevel, accounts, autoStart, closeBehavior
    }

    init() {
        port = 2121
        bindAllInterfaces = true
        defaultRootPath = ServerConfig.defaultRootPath()
        anonymousEnabled = true
        anonymousRootPath = ServerConfig.defaultAnonymousRootPath()
        anonymousCanUpload = false
        anonymousCanDelete = false
        anonymousCanCreateDirectory = false
        maxConnections = 32
        idleTimeout = 300
        dataTimeout = 45
        pasvAdvertiseHost = ""
        logLevel = .info
        accounts = []
        autoStart = false
        closeBehavior = .quit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 2121
        bindAllInterfaces = try container.decodeIfPresent(Bool.self, forKey: .bindAllInterfaces) ?? true
        defaultRootPath = try container.decodeIfPresent(String.self, forKey: .defaultRootPath) ?? ServerConfig.defaultRootPath()
        anonymousEnabled = try container.decodeIfPresent(Bool.self, forKey: .anonymousEnabled) ?? true
        anonymousRootPath = try container.decodeIfPresent(String.self, forKey: .anonymousRootPath) ?? ServerConfig.defaultAnonymousRootPath()
        anonymousCanUpload = try container.decodeIfPresent(Bool.self, forKey: .anonymousCanUpload) ?? false
        anonymousCanDelete = try container.decodeIfPresent(Bool.self, forKey: .anonymousCanDelete) ?? false
        anonymousCanCreateDirectory = try container.decodeIfPresent(Bool.self, forKey: .anonymousCanCreateDirectory) ?? false
        maxConnections = try container.decodeIfPresent(Int.self, forKey: .maxConnections) ?? 32
        idleTimeout = try container.decodeIfPresent(Double.self, forKey: .idleTimeout) ?? 300
        dataTimeout = try container.decodeIfPresent(Double.self, forKey: .dataTimeout) ?? 45
        pasvAdvertiseHost = try container.decodeIfPresent(String.self, forKey: .pasvAdvertiseHost) ?? ""
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        accounts = try container.decodeIfPresent([FTPAccount].self, forKey: .accounts) ?? []
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        closeBehavior = try container.decodeIfPresent(CloseBehavior.self, forKey: .closeBehavior) ?? .quit
    }

    static func defaultRootPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("FTP Share", isDirectory: true).path
    }

    static func defaultAnonymousRootPath() -> String {
        URL(fileURLWithPath: defaultRootPath())
            .appendingPathComponent("Public", isDirectory: true).path
    }
}

struct AnonymousPolicy {
    var enabled: Bool
    var rootPath: String
    var canUpload: Bool
    var canDelete: Bool
    var canCreateDirectory: Bool
}

// MARK: - 运行时状态

enum FTPServerState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isBusy: Bool {
        switch self {
        case .starting, .stopping: return true
        default: return false
        }
    }
    var label: String {
        switch self {
        case .stopped:  return "已停止"
        case .starting: return "启动中"
        case .running:  return "运行中"
        case .stopping: return "停止中"
        case .failed:   return "启动失败"
        }
    }
    var failureReason: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

struct FTPSessionSnapshot: Identifiable, Equatable {
    let id: UUID
    var remoteAddress: String
    var username: String
    var currentDirectory: String
    var isTransferring: Bool
    var transferSummary: String
    var bytesIn: Int64
    var bytesOut: Int64
    var connectedAt: Date
    var lastCommand: String
}

struct FTPServerStats: Equatable {
    var activeSessions: Int = 0
    var totalSessions: Int = 0
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var startedAt: Date?
    var uploadRate: Double = 0
    var downloadRate: Double = 0

    var uploadTotalText: String { ByteFormat.text(bytesIn) }
    var downloadTotalText: String { ByteFormat.text(bytesOut) }
}

enum ByteFormat {
    static func text(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[index])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        text(Int64(bytesPerSecond)) + "/s"
    }
}

// MARK: - 观察者

protocol FTPServerObserver: AnyObject {
    func ftpServerDidChangeState(_ state: FTPServerState)
    func ftpServerDidLog(_ entry: FTPLogEntry)
    func ftpServerDidUpdateSessions(_ sessions: [FTPSessionSnapshot])
    func ftpServerDidUpdateStats(_ stats: FTPServerStats)
}

extension FTPServerObserver {
    func ftpServerDidChangeState(_ state: FTPServerState) {}
    func ftpServerDidLog(_ entry: FTPLogEntry) {}
    func ftpServerDidUpdateSessions(_ sessions: [FTPSessionSnapshot]) {}
    func ftpServerDidUpdateStats(_ stats: FTPServerStats) {}
}

// MARK: - 错误

enum FTPError: Error, LocalizedError {
    case invalidPath
    case invalidArgument(String)
    case escapesRoot
    case notFound
    case notADirectory
    case isADirectory
    case permissionDenied(String)
    case alreadyExists
    case noDataConnection
    case io(String)
    case notSupported
    case portUnavailable(UInt16, String)
    case alreadyRunning

    var message: String {
        switch self {
        case .invalidPath:            return "路径无效"
        case .invalidArgument(let d): return "参数错误：\(d)"
        case .escapesRoot:            return "拒绝访问：路径超出允许的根目录"
        case .notFound:               return "文件或目录不存在"
        case .notADirectory:          return "不是目录"
        case .isADirectory:           return "目标是目录"
        case .permissionDenied(let w): return "权限不足：\(w)"
        case .alreadyExists:          return "目标已存在"
        case .noDataConnection:       return "无法建立数据连接"
        case .io(let detail):         return "文件操作失败：\(detail)"
        case .notSupported:           return "服务器不支持该命令"
        case .portUnavailable(let p, let detail):
            return "无法监听端口 \(p)：\(detail)"
        case .alreadyRunning:         return "服务已在运行"
        }
    }

    var replyCode: Int {
        switch self {
        case .noDataConnection: return 425
        case .io:               return 451
        case .notSupported:     return 502
        case .invalidArgument:  return 501
        case .invalidPath, .escapesRoot, .notFound, .notADirectory,
             .isADirectory, .permissionDenied, .alreadyExists:
            return 550
        case .portUnavailable, .alreadyRunning:
            return 421
        }
    }

    var errorDescription: String? { message }
}
