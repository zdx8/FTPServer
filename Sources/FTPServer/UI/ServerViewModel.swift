import Foundation
import Combine
import AppKit

/// 把服务器回调转交给视图模型。
/// 服务器已经在主队列上派发通知，这里只做一层弱引用转发，避免观察者协议
/// 与视图模型之间产生循环引用。
private final class ServerObserverBridge: FTPServerObserver {
    weak var target: ServerViewModel?

    func ftpServerDidChangeState(_ state: FTPServerState) {
        target?.applyState(state)
    }

    func ftpServerDidLog(_ entry: FTPLogEntry) {
        target?.applyLog(entry)
    }

    func ftpServerDidUpdateSessions(_ sessions: [FTPSessionSnapshot]) {
        target?.applySessions(sessions)
    }

    func ftpServerDidUpdateStats(_ stats: FTPServerStats) {
        target?.applyStats(stats)
    }
}

final class ServerViewModel: ObservableObject {

    static let shared = ServerViewModel()

    struct RateSample: Identifiable {
        let id = UUID()
        let time: Date
        let upload: Double
        let download: Double
    }

    let server = FTPServer()

    @Published private(set) var state: FTPServerState = .stopped
    @Published private(set) var stats = FTPServerStats()
    @Published private(set) var sessions: [FTPSessionSnapshot] = []
    @Published private(set) var logEntries: [FTPLogEntry] = []
    @Published private(set) var rateHistory: [RateSample] = []

    @Published var config: ServerConfig

    /// 界面提示信息（启动失败等），展示后由界面清除。
    @Published var alertMessage: String?

    let configURL: URL
    private let bridge = ServerObserverBridge()
    private let maxLogEntries = 4000
    private let maxRateSamples = 150

    private init() {
        let url = ServerViewModel.configFileURL()
        configURL = url
        config = ServerViewModel.loadConfig(from: url)
        server.config = config
        bridge.target = self
        server.addObserver(bridge)
    }

    // MARK: - 配置持久化

    static func supportDirectory() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base.appendingPathComponent("FTPServer", isDirectory: true)
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func configFileURL() -> URL {
        supportDirectory().appendingPathComponent("config.json")
    }

    static func loadConfig(from url: URL) -> ServerConfig {
        guard let data = try? Data(contentsOf: url) else { return ServerConfig() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ServerConfig.self, from: data) else {
            // 配置损坏时保留现场，避免静默丢弃用户设置
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("config.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return ServerConfig()
        }
        return decoded
    }

    func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL, options: .atomic)
        }
        server.config = config
    }

    func resetConfig() {
        config = ServerConfig()
        saveConfig()
    }

    // MARK: - 服务控制

    func startServer() {
        guard !server.isRunning else { return }
        saveConfig()
        do {
            try server.start(config: config)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func stopServer() {
        server.stop()
    }

    func toggleServer() {
        if server.isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func disconnect(_ session: FTPSessionSnapshot) {
        server.disconnectSession(id: session.id)
    }

    func disconnectAll() {
        for session in sessions { server.disconnectSession(id: session.id) }
    }

    func clearLogs() {
        logEntries.removeAll()
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - 账号管理

    func addAccount(_ account: FTPAccount) {
        config.accounts.append(account)
        saveConfig()
    }

    func updateAccount(_ account: FTPAccount) {
        guard let index = config.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        config.accounts[index] = account
        saveConfig()
    }

    func removeAccount(id: UUID) {
        if let account = config.accounts.first(where: { $0.id == id }) {
            for session in sessions where session.username.caseInsensitiveCompare(account.username) == .orderedSame {
                server.disconnectSession(id: session.id)
            }
        }
        config.accounts.removeAll { $0.id == id }
        saveConfig()
    }

    // MARK: - 派生信息

    /// 可用的接入地址列表，用于界面展示与一键复制。
    var connectionAddresses: [(name: String, url: String)] {
        var results: [(String, String)] = [("本机", "ftp://127.0.0.1:\(config.port)")]
        var seen: Set<String> = ["127.0.0.1"]
        for interface in NetworkInterface.ipv4Addresses() {
            guard interface.address != "127.0.0.1",
                  interface.address != "0.0.0.0",
                  !seen.contains(interface.address) else { continue }
            seen.insert(interface.address)
            results.append((interface.name, "ftp://\(interface.address):\(config.port)"))
        }
        return results
    }

    var displayHost: String {
        NetworkInterface.primaryIPv4() ?? "127.0.0.1"
    }

    // MARK: - 观察者回调（主队列）

    func applyState(_ newState: FTPServerState) {
        state = newState
        if case .failed(let reason) = newState {
            alertMessage = reason
        }
    }

    func applyStats(_ newStats: FTPServerStats) {
        stats = newStats
        let sample = RateSample(time: Date(), upload: newStats.uploadRate, download: newStats.downloadRate)
        rateHistory.append(sample)
        if rateHistory.count > maxRateSamples {
            rateHistory.removeFirst(rateHistory.count - maxRateSamples)
        }
    }

    func applySessions(_ newSessions: [FTPSessionSnapshot]) {
        sessions = newSessions
    }

    func applyLog(_ entry: FTPLogEntry) {
        logEntries.append(entry)
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
    }

    /// 最近若干条日志的纯文本摘要，供菜单栏一键复制排查现场。
    var recentLogDigest: String {
        let recent = logEntries.suffix(30)
        guard !recent.isEmpty else { return "（暂无日志）" }
        return recent
            .map { "[\(ServerViewModel.digestFormatter.string(from: $0.timestamp))] [\($0.level.label)] [\($0.session)] \($0.message)" }
            .joined(separator: "\n")
    }

    private static let digestFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
