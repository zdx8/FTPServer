import Foundation
import Network

enum FTPTransferType {
    case ascii
    case binary

    var label: String { self == .ascii ? "ASCII" : "二进制" }
}

enum ListMode {
    case list
    case nlst
    case mlsd

    var label: String {
        switch self {
        case .list: return "列举目录"
        case .nlst: return "列举名称"
        case .mlsd: return "列举目录(MLSD)"
        }
    }
}

/// 单个客户端会话。控制连接与数据连接共用一条串行队列，
/// 所有状态变更都发生在该队列上；传输过程完全异步链式推进，不阻塞队列。
final class FTPSession {
    let id: UUID
    let shortID: String
    let remoteHost: String
    let remotePort: UInt16

    let control: NWConnection
    let stateQueue: DispatchQueue
    unowned let server: FTPServer

    // 认证与权限
    var isLoggedIn = false
    var isAnonymous = false
    var pendingUsername = ""
    var permissions = FTPPermissions.readOnly
    var vfs: FTPVirtualFileSystem?

    // 会话状态
    var cwd = "/"
    var transferType: FTPTransferType = .binary
    var restOffset: Int64 = 0
    var renameSourcePath: String?
    var renameSourceURL: URL?

    // 数据通道
    var passiveListener: NWListener?
    var passivePort: Int = 0
    var pendingDataConnection: NWConnection?
    var activeEndpoint: NWEndpoint?
    var waitingForData: ((NWConnection?) -> Void)?
    var dataWaitToken: UUID?

    // 进行中的传输
    var activeSender: FTPDataSender?
    var activeReceiver: FTPDataReceiver?
    var transferTimer: DispatchSourceTimer?
    var isTransferring = false
    var transferAbortRequested = false

    // 控制连接读取
    var controlBuffer = Data()
    var idleTimer: DispatchSourceTimer?
    var isClosed = false
    var closingToken: UUID?
    var localHost = ""

    private let snapshotLock = NSLock()
    private var snapshotStorage: FTPSessionSnapshot

    var snapshot: FTPSessionSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotStorage
    }

    func mutateSnapshot(_ body: (inout FTPSessionSnapshot) -> Void) {
        snapshotLock.lock()
        body(&snapshotStorage)
        snapshotLock.unlock()
    }

    // MARK: - 初始化

    init(connection: NWConnection, server: FTPServer, index: Int) {
        let identifier = UUID()
        self.id = identifier
        self.control = connection
        self.server = server
        self.stateQueue = DispatchQueue(label: "ftpserver.session.\(index)")
        self.shortID = String(format: "S%03d", index)

        var host = "未知地址"
        var port: UInt16 = 0
        if case let .hostPort(endpointHost, endpointPort) = connection.endpoint {
            host = FTPSession.hostString(endpointHost)
            port = endpointPort.rawValue
        }
        self.remoteHost = host
        self.remotePort = port

        let address = port > 0 ? "\(host):\(port)" : host
        self.snapshotStorage = FTPSessionSnapshot(
            id: identifier,
            remoteAddress: address,
            username: "未登录",
            currentDirectory: "/",
            isTransferring: false,
            transferSummary: "",
            bytesIn: 0,
            bytesOut: 0,
            connectedAt: Date(),
            lastCommand: "—"
        )
    }

    static func hostString(_ host: NWEndpoint.Host) -> String {
        let text = String(describing: host)
        if text.hasPrefix("::ffff:") { return String(text.dropFirst(7)) }
        return text
    }

    // MARK: - 生命周期

    func start() {
        control.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.captureLocalHost()
                self.send("220 \(self.server.bannerText)")
                self.log(.info, "连接已建立")
                self.armIdleTimer()
                self.readControl()
            case .failed(let error):
                self.close(reason: "连接失败：\(error.localizedDescription)")
            case .cancelled:
                self.close(reason: "连接已关闭")
            default:
                break
            }
        }
        control.start(queue: stateQueue)
    }

    private func captureLocalHost() {
        if let endpoint = control.currentPath?.localEndpoint,
           case let .hostPort(host, _) = endpoint {
            localHost = FTPSession.hostString(host)
        }
    }

    func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        cancelTransferWatchdog()
        idleTimer?.cancel()
        idleTimer = nil
        activeSender?.abort()
        activeReceiver?.abort()
        teardownDataChannel()
        control.stateUpdateHandler = nil
        control.cancel()
        log(.info, "会话结束（\(reason)）")
        server.sessionDidClose(id: id, reason: reason)
    }

    // MARK: - 控制连接读取

    func readControl() {
        control.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.appendControlData(data)
            }
            if let error = error {
                self.close(reason: "读取失败：\(error.localizedDescription)")
                return
            }
            if isComplete {
                self.close(reason: "客户端关闭连接")
                return
            }
            self.readControl()
        }
    }

    private func appendControlData(_ data: Data) {
        guard !isClosed else { return }
        controlBuffer.append(data)
        if controlBuffer.count > 8192 {
            sendAndClose("500 命令行过长", reason: "命令行超过长度限制")
            return
        }
        while let newlineIndex = controlBuffer.firstIndex(of: 0x0A) {
            let lineData = controlBuffer[controlBuffer.startIndex..<newlineIndex]
            controlBuffer.removeSubrange(controlBuffer.startIndex...newlineIndex)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handleLine(line)
            if isClosed { return }
        }
    }

    private func handleLine(_ line: String) {
        resetIdleTimer()
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let command = pieces[0].uppercased()
        let argument = pieces.count > 1 ? String(pieces[1]) : ""

        log(.debug, "→ \(command)\(argument.isEmpty ? "" : " " + FTPSession.maskArgument(command, argument))")
        mutateSnapshot { $0.lastCommand = command }
        dispatch(command: command, argument: argument)
    }

    /// PASS / ACCT 的参数不写入日志。
    private static func maskArgument(_ command: String, _ argument: String) -> String {
        switch command {
        case "PASS", "ACCT": return "••••••"
        default: return argument
        }
    }

    private func dispatch(command: String, argument: String) {
        do {
            try route(command: command, argument: argument)
        } catch let error as FTPError {
            if FTPSession.transferCommands.contains(command) { teardownDataChannel() }
            send("\(error.replyCode) \(error.message)")
        } catch let error as NSError {
            log(.error, "\(command) 执行失败：\(error.localizedDescription)")
            if FTPSession.transferCommands.contains(command) { teardownDataChannel() }
            send("550 操作失败：\(error.localizedDescription)")
        } catch {
            send("451 操作失败：\(error.localizedDescription)")
        }
    }

    /// 需要数据通道的命令。这些命令失败时必须回收客户端已建立的数据连接，
    /// 否则会留下一个无人读取的半开连接。
    static let transferCommands: Set<String> = ["RETR", "STOR", "APPE", "LIST", "NLST", "MLSD"]

    // MARK: - 回复与日志

    /// 发送一行或多行回复。多行回复内部自带 CRLF，此处只在末尾补一个。
    /// completion 在数据真正写出后于会话队列上回调，用于「先回复再断开」的场景。
    func send(_ text: String, completion: (() -> Void)? = nil) {
        guard !isClosed else {
            completion?()
            return
        }
        guard let data = (text + "\r\n").data(using: .utf8) else {
            completion?()
            return
        }
        let firstLine = text.split(separator: "\r\n").first.map(String.init) ?? text
        log(.debug, "← \(firstLine)")
        control.send(content: data,
                     contentContext: .defaultMessage,
                     isComplete: false,
                     completion: .contentProcessed { _ in completion?() })
    }

    /// 回复最后一条消息后再关闭连接。
    /// 必须等发送完成才能断开，否则客户端会读到 EOF 而不是响应码
    /// （QUIT 的 221、超时的 421 都属于这类收尾回复）。
    /// 额外设置一个兜底超时，防止客户端不读数据导致发送永不完成。
    func sendAndClose(_ text: String, reason: String) {
        let token = UUID()
        closingToken = token
        send(text) { [weak self] in
            guard let self = self, self.closingToken == token else { return }
            self.close(reason: reason)
        }
        stateQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.closingToken == token, !self.isClosed else { return }
            self.close(reason: reason)
        }
    }

    func log(_ level: LogLevel, _ message: String) {
        server.log(level: level, session: shortID, message: message)
    }

    func addBytesIn(_ count: Int64) {
        mutateSnapshot { $0.bytesIn += count }
        server.recordBytesIn(count)
    }

    func addBytesOut(_ count: Int64) {
        mutateSnapshot { $0.bytesOut += count }
        server.recordBytesOut(count)
    }

    func requireVFS() throws -> FTPVirtualFileSystem {
        guard let fs = vfs else { throw FTPError.permissionDenied("会话尚未登录") }
        return fs
    }

    // MARK: - 超时

    func armIdleTimer() {
        guard server.config.idleTimeout > 0 else { return }
        if idleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.setEventHandler { [weak self] in
                guard let self = self, !self.isClosed else { return }
                self.log(.info, "空闲超时（超过 \(Int(self.server.config.idleTimeout)) 秒无活动）")
                self.sendAndClose("421 空闲超时，连接即将关闭", reason: "空闲超时")
            }
            idleTimer = timer
            timer.resume()
        }
        resetIdleTimer()
    }

    func resetIdleTimer() {
        guard server.config.idleTimeout > 0, let timer = idleTimer else { return }
        timer.schedule(deadline: .now() + server.config.idleTimeout)
    }

    func beginTransferWatchdog() {
        cancelTransferWatchdog()
        guard server.config.dataTimeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isClosed, self.isTransferring else { return }
            self.log(.warning, "数据传输停滞超过 \(Int(self.server.config.dataTimeout)) 秒，已中止")
            self.transferAbortRequested = true
            self.activeSender?.abort()
            self.activeReceiver?.abort()
            self.cancelTransferWatchdog()
            self.isTransferring = false
            self.mutateSnapshot { $0.isTransferring = false; $0.transferSummary = "" }
            self.teardownDataChannel()
            self.send("426 数据连接超时，传输已中止")
        }
        transferTimer = timer
        timer.resume()
        timer.schedule(deadline: .now() + server.config.dataTimeout)
    }

    func touchTransferWatchdog() {
        guard server.config.dataTimeout > 0 else { return }
        transferTimer?.schedule(deadline: .now() + server.config.dataTimeout)
        resetIdleTimer()
    }

    func cancelTransferWatchdog() {
        transferTimer?.cancel()
        transferTimer = nil
    }

    // MARK: - 命令路由

    private func route(command: String, argument: String) throws {
        // 登录前可用
        switch command {
        case "USER": try handleUSER(argument); return
        case "PASS": try handlePASS(argument); return
        case "QUIT": sendAndClose("221 再见", reason: "客户端主动断开"); return
        case "FEAT": handleFEAT(); return
        case "SYST": send("215 UNIX Type: L8"); return
        case "NOOP": send("200 NOOP 执行成功"); return
        case "OPTS": handleOPTS(argument); return
        case "HELP": handleHELP(); return
        case "AUTH": send("502 本服务器不支持加密传输，请使用明文 FTP"); return
        case "PBSZ", "PROT", "CCC": send("503 未启用安全传输通道"); return
        case "ACCT": send("202 ACCT 未使用"); return
        default: break
        }

        guard isLoggedIn else {
            send("530 请先使用 USER / PASS 登录")
            return
        }

        switch command {
        case "CWD":  try handleCWD(argument); return
        case "XCWD": try handleCWD(argument); return
        case "CDUP": try handleCWD(".."); return
        case "XCUP": try handleCWD(".."); return
        case "PWD":  handlePWD(); return
        case "XPWD": handlePWD(); return
        case "MKD":  try handleMKD(argument); return
        case "XMKD": try handleMKD(argument); return
        case "RMD":  try handleRMD(argument); return
        case "XRMD": try handleRMD(argument); return
        case "DELE": try handleDELE(argument); return
        case "RNFR": try handleRNFR(argument); return
        case "RNTO": try handleRNTO(argument); return
        case "SIZE": try handleSIZE(argument); return
        case "MDTM": try handleMDTM(argument); return
        case "TYPE": try handleTYPE(argument); return
        case "STRU": handleSTRU(argument); return
        case "MODE": handleMODE(argument); return
        case "REST": try handleREST(argument); return
        case "ALLO": send("202 无需预分配空间"); return
        case "PORT": try handlePORT(argument); return
        case "PASV": startPassiveListener(extended: false); return
        case "EPSV": handleEPSV(argument); return
        case "LIST": try handleList(argument: argument, mode: .list); return
        case "NLST": try handleList(argument: argument, mode: .nlst); return
        case "MLSD": try handleList(argument: argument, mode: .mlsd); return
        case "MLST": try handleMLST(argument); return
        case "RETR": try handleRETR(argument); return
        case "STOR": try handleSTOR(argument, append: false); return
        case "APPE": try handleSTOR(argument, append: true); return
        case "ABOR": handleABOR(); return
        case "STAT": handleSTAT(argument); return
        case "STOU", "REIN", "SMNT", "SITE": send("502 本服务器未实现该命令"); return
        default:
            send("500 无法识别的命令：\(command)")
            return
        }
    }

    // MARK: - 认证

    private static func isAnonymousName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "anonymous" || lowered == "ftp"
    }

    private func handleUSER(_ argument: String) throws {
        let name = argument.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            send("501 缺少用户名")
            return
        }
        // 重复 USER 视为重新登录，先清空既有身份
        isLoggedIn = false
        permissions = .readOnly
        vfs = nil
        cwd = "/"
        restOffset = 0
        renameSourcePath = nil
        renameSourceURL = nil
        pendingUsername = name
        mutateSnapshot { $0.username = "未登录"; $0.currentDirectory = "/" }

        if FTPSession.isAnonymousName(name) {
            if server.anonymousPolicy.enabled {
                send("331 请输入电子邮件地址作为口令")
            } else {
                send("530 匿名访问已禁用")
            }
            return
        }
        // 账号存在与否都返回同一响应，避免账号枚举
        send("331 需要口令")
    }

    private func handlePASS(_ argument: String) throws {
        guard !pendingUsername.isEmpty else {
            send("503 请先发送 USER")
            return
        }
        if FTPSession.isAnonymousName(pendingUsername) {
            let policy = server.anonymousPolicy
            guard policy.enabled else {
                send("530 匿名访问已禁用")
                return
            }
            establishSession(
                rootPath: policy.rootPath,
                displayName: "anonymous",
                permissions: FTPPermissions(canDownload: true,
                                            canUpload: policy.canUpload,
                                            canDelete: policy.canDelete,
                                            canCreateDirectory: policy.canCreateDirectory),
                isAnonymous: true
            )
            return
        }
        guard let account = server.account(named: pendingUsername) else {
            log(.warning, "登录失败：账号不存在（\(pendingUsername)）")
            send("530 用户名或口令错误")
            return
        }
        guard account.enabled else {
            log(.warning, "登录失败：账号已禁用（\(pendingUsername)）")
            send("530 该账号已被禁用")
            return
        }
        guard account.verify(password: argument) else {
            log(.warning, "登录失败：口令错误（\(pendingUsername)）")
            send("530 用户名或口令错误")
            return
        }
        establishSession(
            rootPath: account.effectiveRootPath,
            displayName: account.username,
            permissions: FTPPermissions(canDownload: account.canDownload,
                                        canUpload: account.canUpload,
                                        canDelete: account.canDelete,
                                        canCreateDirectory: account.canCreateDirectory),
            isAnonymous: false
        )
    }

    private func establishSession(rootPath: String,
                                  displayName: String,
                                  permissions: FTPPermissions,
                                  isAnonymous: Bool) {
        let fileSystem = FTPVirtualFileSystem(rootPath: rootPath)
        var directoryFlag: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileSystem.rootURL.path,
                                                    isDirectory: &directoryFlag)
        guard exists, directoryFlag.boolValue else {
            log(.error, "账号根目录不可访问：\(fileSystem.rootURL.path)")
            send("530 账号根目录不可访问，请联系管理员")
            return
        }
        vfs = fileSystem
        self.permissions = permissions
        self.isLoggedIn = true
        self.isAnonymous = isAnonymous
        cwd = "/"
        mutateSnapshot { $0.username = displayName; $0.currentDirectory = "/" }
        log(.info, "登录成功：\(displayName)（根目录 \(fileSystem.rootURL.path)）")
        send("230 登录成功，欢迎使用")
    }

    // MARK: - 目录操作

    private func handlePWD() {
        send("257 \"\(cwd)\" 是当前目录")
    }

    private func handleCWD(_ argument: String) throws {
        let fileSystem = try requireVFS()
        let target = argument.isEmpty ? "/" : argument
        let normalized = try fileSystem.normalize(target, relativeTo: cwd)
        let url = fileSystem.fileURL(for: normalized)
        try fileSystem.ensureInsideRoot(url)
        guard fileSystem.exists(url) else { throw FTPError.notFound }
        guard fileSystem.isDirectory(url) else { throw FTPError.notADirectory }
        cwd = normalized
        mutateSnapshot { $0.currentDirectory = normalized }
        log(.debug, "切换目录 → \(normalized)")
        send("250 目录已切换至 \(normalized)")
    }

    private func handleMKD(_ argument: String) throws {
        guard permissions.canCreateDirectory else { throw FTPError.permissionDenied("禁止创建目录") }
        let name = argument.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw FTPError.invalidPath }
        let fileSystem = try requireVFS()
        let normalized = try fileSystem.normalize(name, relativeTo: cwd)
        guard normalized != "/" else { throw FTPError.alreadyExists }
        let url = fileSystem.fileURL(for: normalized)
        let parent = url.deletingLastPathComponent()
        try fileSystem.ensureInsideRoot(parent)
        guard fileSystem.isDirectory(parent) else { throw FTPError.notFound }
        guard !fileSystem.exists(url) else { throw FTPError.alreadyExists }
        // 悬空软链接的 exists 为 false，但 mkdir 会顺着链接在根目录之外创建目录
        try fileSystem.ensureTargetNotEscapingLink(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        log(.info, "创建目录 \(normalized)")
        send("257 \"\(normalized)\" 目录已创建")
    }

    private func handleRMD(_ argument: String) throws {
        guard permissions.canDelete else { throw FTPError.permissionDenied("禁止删除") }
        let fileSystem = try requireVFS()
        let normalized = try fileSystem.normalize(argument, relativeTo: cwd)
        guard normalized != "/" else { throw FTPError.permissionDenied("不能删除根目录") }
        let url = fileSystem.fileURL(for: normalized)
        try fileSystem.ensureInsideRoot(url)
        guard fileSystem.exists(url) else { throw FTPError.notFound }
        guard fileSystem.isDirectory(url) else { throw FTPError.notADirectory }
        try FileManager.default.removeItem(at: url)
        log(.info, "删除目录 \(normalized)")
        send("250 目录已删除")
    }

    private func handleDELE(_ argument: String) throws {
        guard permissions.canDelete else { throw FTPError.permissionDenied("禁止删除") }
        let fileSystem = try requireVFS()
        let normalized = try fileSystem.normalize(argument, relativeTo: cwd)
        let url = fileSystem.fileURL(for: normalized)
        try fileSystem.ensureInsideRoot(url)
        guard fileSystem.exists(url) else { throw FTPError.notFound }
        guard !fileSystem.isDirectory(url) else { throw FTPError.isADirectory }
        try FileManager.default.removeItem(at: url)
        log(.info, "删除文件 \(normalized)")
        send("250 文件已删除")
    }

    private func handleRNFR(_ argument: String) throws {
        guard permissions.canDelete else { throw FTPError.permissionDenied("禁止重命名") }
        let fileSystem = try requireVFS()
        let normalized = try fileSystem.normalize(argument, relativeTo: cwd)
        guard normalized != "/" else { throw FTPError.permissionDenied("不能重命名根目录") }
        let url = fileSystem.fileURL(for: normalized)
        try fileSystem.ensureInsideRoot(url)
        guard fileSystem.exists(url) else { throw FTPError.notFound }
        renameSourcePath = normalized
        renameSourceURL = url
        send("350 已记录源名称，请发送 RNTO")
    }

    private func handleRNTO(_ argument: String) throws {
        guard permissions.canDelete else { throw FTPError.permissionDenied("禁止重命名") }
        guard let sourcePath = renameSourcePath, let sourceURL = renameSourceURL else {
            send("503 请先发送 RNFR")
            return
        }
        defer {
            renameSourcePath = nil
            renameSourceURL = nil
        }
        let fileSystem = try requireVFS()
        let normalized = try fileSystem.normalize(argument, relativeTo: cwd)
        guard normalized != "/" else { throw FTPError.permissionDenied("目标名称无效") }
        let target = fileSystem.fileURL(for: normalized)
        let parent = target.deletingLastPathComponent()
        try fileSystem.ensureInsideRoot(parent)
        guard fileSystem.isDirectory(parent) else { throw FTPError.notFound }
        guard !fileSystem.exists(target) else { throw FTPError.alreadyExists }
        try FileManager.default.moveItem(at: sourceURL, to: target)
        log(.info, "重命名 \(sourcePath) → \(normalized)")
        send("250 重命名完成")
    }

    // MARK: - 元数据

    private func handleSIZE(_ argument: String) throws {
        let fileSystem = try requireVFS()
        let url = try fileSystem.resolveForRead(argument, relativeTo: cwd)
        guard fileSystem.exists(url) else { throw FTPError.notFound }
        guard !fileSystem.isDirectory(url) else { throw FTPError.isADirectory }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        send("213 \(size)")
    }

    private func handleMDTM(_ argument: String) throws {
        let fileSystem = try requireVFS()
        let url = try fileSystem.resolveForRead(argument, relativeTo: cwd)
        guard fileSystem.exists(url) else { throw FTPError.notFound }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        send("213 \(FTPVirtualFileSystem.utcTimestamp(modified))")
    }

    private func handleSTAT(_ argument: String) {
        if argument.isEmpty {
            let lines = [
                "211-服务器状态：",
                " 运行时长 \(server.uptimeText)",
                " 活动连接 \(server.activeSessionCount)",
                " 会话 \(shortID) 当前目录 \(cwd)",
                "211 结束",
            ]
            send(lines.joined(separator: "\r\n"))
            return
        }
        do {
            let fileSystem = try requireVFS()
            let normalized = try fileSystem.normalize(argument, relativeTo: cwd)
            let url = fileSystem.fileURL(for: normalized)
            try fileSystem.ensureInsideRoot(url)
            guard fileSystem.exists(url) else { throw FTPError.notFound }
            if fileSystem.isDirectory(url) {
                let entries = try fileSystem.list(normalized)
                var lines = ["213-\(normalized) 的状态："]
                for item in entries { lines.append(" " + FTPVirtualFileSystem.listLine(for: item)) }
                lines.append("213 结束")
                send(lines.joined(separator: "\r\n"))
            } else {
                let item = try fileSystem.entry(for: url)
                send("213-\(normalized) 的状态：\r\n \(FTPVirtualFileSystem.listLine(for: item))\r\n213 结束")
            }
        } catch let error as FTPError {
            send("\(error.replyCode) \(error.message)")
        } catch {
            send("550 操作失败")
        }
    }

    // MARK: - 传输参数

    private func handleTYPE(_ argument: String) throws {
        let value = argument.uppercased().trimmingCharacters(in: .whitespaces)
        switch value {
        case "A", "A N":
            transferType = .ascii
            send("200 已切换为 ASCII 传输模式")
        case "I", "L 8", "L8":
            transferType = .binary
            send("200 已切换为二进制传输模式")
        default:
            send("504 不支持的类型参数：\(value)")
        }
    }

    private func handleSTRU(_ argument: String) {
        let value = argument.uppercased().trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == "F" {
            send("200 文件结构已确认为 F")
        } else {
            send("504 仅支持文件结构 F")
        }
    }

    private func handleMODE(_ argument: String) {
        let value = argument.uppercased().trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == "S" {
            send("200 流模式已确认")
        } else {
            send("504 仅支持流模式 S")
        }
    }

    private func handleREST(_ argument: String) throws {
        let text = argument.trimmingCharacters(in: .whitespaces)
        // 偏移量非法属于参数问题，按 RFC 959 应答 501 而不是 550
        guard let value = Int64(text), value >= 0 else {
            throw FTPError.invalidArgument("REST 需要一个非负整数偏移量")
        }
        restOffset = value
        send("350 已记录起始位置 \(value)")
    }

    // MARK: - 主动模式

    private func handlePORT(_ argument: String) throws {
        let parts = argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 6,
              let h1 = UInt8(parts[0]), let h2 = UInt8(parts[1]),
              let h3 = UInt8(parts[2]), let h4 = UInt8(parts[3]),
              let p1 = UInt8(parts[4]), let p2 = UInt8(parts[5]) else {
            send("501 PORT 参数格式错误")
            return
        }
        let host = "\(h1).\(h2).\(h3).\(h4)"
        let port = UInt16(p1) * 256 + UInt16(p2)
        guard port > 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            send("501 PORT 端口无效")
            return
        }
        // FTP bounce 防护：仅允许回连控制连接的来源地址
        if !remoteHost.isEmpty, remoteHost != "未知地址", host != remoteHost {
            log(.warning, "拒绝 PORT 到 \(host)：与控制连接来源 \(remoteHost) 不一致")
            send("501 拒绝 PORT：目标地址必须与控制连接来源一致")
            return
        }
        teardownDataChannel()
        activeEndpoint = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        send("200 PORT 命令成功")
    }

    private func handleEPSV(_ argument: String) {
        let value = argument.uppercased().trimmingCharacters(in: .whitespaces)
        switch value {
        case "", "1", "ALL":
            startPassiveListener(extended: true)
        case "2":
            send("522 本服务器使用 IPv4，请使用 EPSV 或 EPSV 1")
        default:
            send("501 EPSV 参数无效")
        }
    }

    // MARK: - 特性与帮助

    private func handleFEAT() {
        let features = [
            " SIZE",
            " MDTM",
            " MLSD",
            " MLST type*;size*;modify*;perm*;UNIX.mode*;UNIX.owner*;UNIX.group*;",
            " REST STREAM",
            " UTF8",
            " TVFS",
            " EPSV",
        ]
        send("211-扩展特性：\r\n" + features.joined(separator: "\r\n") + "\r\n211 结束")
    }

    private func handleOPTS(_ argument: String) {
        let upper = argument.uppercased()
        if upper.hasPrefix("UTF8") {
            send("200 UTF8 已启用")
            return
        }
        if upper.hasPrefix("MLST") {
            send("200 MLST 选项已接受")
            return
        }
        send("501 无法识别的选项")
    }

    private func handleHELP() {
        let commands = [
            "USER PASS QUIT SYST NOOP FEAT OPTS HELP",
            "PWD CWD CDUP MKD RMD DELE RNFR RNTO",
            "TYPE STRU MODE REST ALLO PORT PASV EPSV",
            "LIST NLST MLSD MLST RETR STOR APPE SIZE MDTM",
            "ABOR STAT",
        ]
        send("214-支持的命令：\r\n " + commands.joined(separator: "\r\n ") + "\r\n214 结束")
    }
}
