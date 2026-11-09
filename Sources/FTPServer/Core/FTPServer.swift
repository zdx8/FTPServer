import Foundation
import Network

/// FTP 服务核心。职责：端口监听、连接接入与限流、会话注册表、
/// 全局字节统计与速率采样、日志分发。
final class FTPServer {

    // MARK: - 内部状态

    private let queue = DispatchQueue(label: "ftpserver.core")

    private let configLock = NSLock()
    private var currentConfig = ServerConfig()

    private let stateLock = NSLock()
    private var stateStorage: FTPServerState = .stopped

    private let sessionLock = NSLock()
    private var sessions: [UUID: FTPSession] = [:]
    private var sessionCounter = 0

    private let statsLock = NSLock()
    private var totalSessions = 0
    private var totalBytesIn: Int64 = 0
    private var totalBytesOut: Int64 = 0
    private var startedAt: Date?
    private var previousBytesIn: Int64 = 0
    private var previousBytesOut: Int64 = 0
    private var previousSampleTime = Date()
    private var uploadRate: Double = 0
    private var downloadRate: Double = 0

    private let observersLock = NSLock()
    private var observers: [ObjectIdentifier: FTPServerObserver] = [:]

    private var listener: NWListener?
    private var heartbeat: DispatchSourceTimer?

    let bannerText = "FTP Server 1.0 就绪"

    // MARK: - 对外属性

    var state: FTPServerState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateStorage
    }

    var isRunning: Bool { state.isRunning }

    var config: ServerConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return currentConfig
        }
        set {
            configLock.lock()
            currentConfig = newValue
            configLock.unlock()
        }
    }

    var activeSessionCount: Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessions.count
    }

    var uptimeText: String {
        statsLock.lock()
        let start = startedAt
        statsLock.unlock()
        guard let start = start else { return "未运行" }
        let total = max(0, Int(Date().timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分 \(seconds) 秒" }
        if minutes > 0 { return "\(minutes) 分 \(seconds) 秒" }
        return "\(seconds) 秒"
    }

    var anonymousPolicy: AnonymousPolicy {
        let snapshot = config
        return AnonymousPolicy(enabled: snapshot.anonymousEnabled,
                               rootPath: snapshot.anonymousRootPath,
                               canUpload: snapshot.anonymousCanUpload,
                               canDelete: snapshot.anonymousCanDelete,
                               canCreateDirectory: snapshot.anonymousCanCreateDirectory)
    }

    func account(named username: String) -> FTPAccount? {
        let lowered = username.lowercased()
        return config.accounts.first { $0.username.lowercased() == lowered }
    }

    // MARK: - 观察者

    func addObserver(_ observer: FTPServerObserver) {
        observersLock.lock()
        observers[ObjectIdentifier(observer)] = observer
        observersLock.unlock()
    }

    func removeObserver(_ observer: FTPServerObserver) {
        observersLock.lock()
        observers.removeValue(forKey: ObjectIdentifier(observer))
        observersLock.unlock()
    }

    private func notifyOnMain(_ body: @escaping (FTPServerObserver) -> Void) {
        observersLock.lock()
        let list = Array(observers.values)
        observersLock.unlock()
        guard !list.isEmpty else { return }
        DispatchQueue.main.async {
            for observer in list { body(observer) }
        }
    }

    func log(level: LogLevel, session: String, message: String) {
        guard level.rank >= config.logLevel.rank else { return }
        let entry = FTPLogEntry(timestamp: Date(), level: level, session: session, message: message)
        notifyOnMain { $0.ftpServerDidLog(entry) }
    }

    private func setState(_ newValue: FTPServerState) {
        stateLock.lock()
        let changed = (stateStorage != newValue)
        stateStorage = newValue
        stateLock.unlock()
        guard changed else { return }
        notifyOnMain { $0.ftpServerDidChangeState(newValue) }
    }

    // MARK: - 启动 / 停止

    func start(config newConfig: ServerConfig) throws {
        guard !state.isRunning, !state.isBusy else { throw FTPError.alreadyRunning }
        setState(.starting)
        config = newConfig
        prepareDirectories()

        let port = newConfig.port
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            setState(.failed("端口号无效"))
            throw FTPError.portUnavailable(port, "端口号无效")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.connectionTimeout = 20
        }
        // 仅本机模式注意：端口必须写在 requiredLocalEndpoint 里，
        // 不能同时再给 on: 传端口——两者并存会直接抛 EINVAL 导致无法启动。
        do {
            let listener: NWListener
            if newConfig.bindAllInterfaces {
                listener = try NWListener(using: parameters, on: endpointPort)
            } else {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                             port: endpointPort)
                listener = try NWListener(using: parameters)
            }
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            listener = nil
            let detail: String
            if let nwError = error as? NWError {
                detail = describe(nwError)
            } else {
                detail = error.localizedDescription
            }
            setState(.failed(detail))
            throw FTPError.portUnavailable(port, detail)
        }
    }

    func stop() {
        guard state.isRunning else { return }
        setState(.stopping)
        stopInternal()
        setState(.stopped)
        log(level: .info, session: "服务", message: "服务已停止")
        publishStats()
    }

    private func stopInternal() {
        heartbeat?.cancel()
        heartbeat = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        sessionLock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        sessionLock.unlock()
        for session in all {
            session.stateQueue.async { session.close(reason: "服务已停止") }
        }

        statsLock.lock()
        startedAt = nil
        uploadRate = 0
        downloadRate = 0
        statsLock.unlock()

        publishSessions()
    }

    func disconnectSession(id: UUID) {
        sessionLock.lock()
        let session = sessions[id]
        sessionLock.unlock()
        guard let target = session else { return }
        target.stateQueue.async { target.close(reason: "管理员主动断开") }
    }

    func sessionSnapshots() -> [FTPSessionSnapshot] {
        sessionLock.lock()
        let all = Array(sessions.values)
        sessionLock.unlock()
        return all.map { $0.snapshot }.sorted { $0.connectedAt < $1.connectedAt }
    }

    // MARK: - 监听与接入

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            statsLock.lock()
            startedAt = Date()
            totalSessions = 0
            totalBytesIn = 0
            totalBytesOut = 0
            previousBytesIn = 0
            previousBytesOut = 0
            previousSampleTime = Date()
            uploadRate = 0
            downloadRate = 0
            statsLock.unlock()

            setState(.running)
            startHeartbeat()
            let snapshot = config
            let scope = snapshot.bindAllInterfaces ? "全部网卡" : "仅本机 127.0.0.1"
            log(level: .info, session: "服务",
                message: "服务已启动，监听端口 \(snapshot.port)（\(scope)）")
            publishStats()
            publishSessions()
        case .failed(let error):
            let detail = describe(error)
            log(level: .error, session: "服务", message: "监听失败：\(detail)")
            setState(.failed(detail))
            stopInternal()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let limit = max(1, config.maxConnections)
        if activeSessionCount >= limit {
            connection.start(queue: queue)
            let payload = Data("421 连接数已达上限（\(limit)），请稍后重试\r\n".utf8)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
            log(level: .warning, session: "服务", message: "拒绝新连接：已达最大连接数 \(limit)")
            return
        }

        sessionCounter += 1
        let session = FTPSession(connection: connection, server: self, index: sessionCounter)
        sessionLock.lock()
        sessions[session.id] = session
        sessionLock.unlock()

        statsLock.lock()
        totalSessions += 1
        statsLock.unlock()

        log(level: .info, session: session.shortID, message: "收到来自 \(session.remoteHost) 的连接")
        session.start()
        publishSessions()
    }

    // MARK: - 会话回调

    func sessionDidClose(id: UUID, reason: String) {
        sessionLock.lock()
        sessions.removeValue(forKey: id)
        sessionLock.unlock()
        publishSessions()
    }

    func recordBytesIn(_ count: Int64) {
        statsLock.lock()
        totalBytesIn += count
        statsLock.unlock()
    }

    func recordBytesOut(_ count: Int64) {
        statsLock.lock()
        totalBytesOut += count
        statsLock.unlock()
    }

    // MARK: - 心跳与统计广播

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        heartbeat = timer
        timer.resume()
    }

    private func tick() {
        let now = Date()
        statsLock.lock()
        let bytesIn = totalBytesIn
        let bytesOut = totalBytesOut
        let elapsed = max(0.2, now.timeIntervalSince(previousSampleTime))
        uploadRate = max(0, Double(bytesIn - previousBytesIn) / elapsed)
        downloadRate = max(0, Double(bytesOut - previousBytesOut) / elapsed)
        previousBytesIn = bytesIn
        previousBytesOut = bytesOut
        previousSampleTime = now
        statsLock.unlock()

        publishStats()
        publishSessions()
    }

    func publishStats() {
        sessionLock.lock()
        let active = sessions.count
        sessionLock.unlock()

        statsLock.lock()
        let snapshot = FTPServerStats(activeSessions: active,
                                      totalSessions: totalSessions,
                                      bytesIn: totalBytesIn,
                                      bytesOut: totalBytesOut,
                                      startedAt: startedAt,
                                      uploadRate: uploadRate,
                                      downloadRate: downloadRate)
        statsLock.unlock()

        notifyOnMain { $0.ftpServerDidUpdateStats(snapshot) }
    }

    func publishSessions() {
        let snapshots = sessionSnapshots()
        notifyOnMain { $0.ftpServerDidUpdateSessions(snapshots) }
    }

    // MARK: - 辅助

    private func prepareDirectories() {
        let snapshot = config
        var paths = [snapshot.defaultRootPath, snapshot.anonymousRootPath]
        paths.append(contentsOf: snapshot.accounts.map { $0.effectiveRootPath })

        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { continue }
            var directoryFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &directoryFlag) {
                continue
            }
            do {
                try FileManager.default.createDirectory(atPath: expanded,
                                                        withIntermediateDirectories: true)
                log(level: .info, session: "服务", message: "已创建共享目录：\(expanded)")
            } catch {
                log(level: .error, session: "服务",
                    message: "无法创建目录 \(expanded)：\(error.localizedDescription)")
            }
        }
    }

    private func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .EADDRINUSE:
                return "端口已被其他程序占用"
            case .EACCES:
                return "权限不足：1024 以下端口需要 root 权限，请改用 1024 以上端口"
            case .EADDRNOTAVAIL:
                return "指定的本地地址不可用"
            default:
                return "系统错误（\(code.rawValue)）"
            }
        case .dns:
            return "域名解析失败"
        case .tls:
            return "TLS 层错误"
        default:
            return error.localizedDescription
        }
    }
}
