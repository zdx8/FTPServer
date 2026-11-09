import Foundation
import Network

/// 内存数据源，用于 LIST / NLST / MLSD 这类已经在内存中构造好的载荷。
final class FTPMemorySource {
    private let payload: Data
    private var offset = 0

    init(payload: Data) { self.payload = payload }

    func nextChunk() -> Data? {
        guard offset < payload.count else { return nil }
        let end = min(offset + 65536, payload.count)
        let slice = payload[payload.startIndex + offset..<payload.startIndex + end]
        offset = end
        return Data(slice)
    }
}

extension FTPSession {

    // MARK: - 数据通道管理

    func teardownDataChannel() {
        waitingForData = nil
        dataWaitToken = nil
        passiveListener?.cancel()
        passiveListener = nil
        passivePort = 0
        pendingDataConnection?.cancel()
        pendingDataConnection = nil
        activeEndpoint = nil
    }

    func startPassiveListener(extended: Bool) {
        teardownDataChannel()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener: NWListener
            if server.config.bindAllInterfaces {
                listener = try NWListener(using: parameters, on: .any)
            } else {
                // 「仅本机」时数据端口必须与控制端口保持同一绑定范围，
                // 否则 PASV 会在所有网卡上开出一个预期之外的监听套接字。
                //
                // 注意：`requiredInterfaceType = .loopback` 对**监听**套接字无效
                // （实测仍绑定到 *），必须用 requiredLocalEndpoint 指定回环地址。
                // 端口写 .any 让系统分配：这里若同时给 on: 传端口并无冲突，
                // 但端口只写一处更不易出错，因此不再传 on:。
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                            port: .any)
                listener = try NWListener(using: parameters)
            }
            // 立即登记，确保后续 teardown 一定能回收该监听器
            passiveListener = listener

            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else {
                    connection.cancel()
                    return
                }
                self.handleIncomingDataConnection(connection)
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    let port = Int(listener.port?.rawValue ?? 0)
                    guard port > 0 else {
                        self.send("425 无法分配数据端口")
                        self.passiveListener?.cancel()
                        self.passiveListener = nil
                        return
                    }
                    self.passivePort = port
                    if extended {
                        self.send("229 进入扩展被动模式 (|||\(port)|)")
                    } else {
                        self.replyPassiveAddress(port: port)
                    }
                case .failed(let error):
                    listener.cancel()
                    if self.passiveListener === listener { self.passiveListener = nil }
                    self.send("425 数据端口监听失败：\(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.start(queue: stateQueue)
        } catch {
            passiveListener = nil
            send("425 无法启动数据监听：\(error.localizedDescription)")
        }
    }

    private func replyPassiveAddress(port: Int) {
        let host = advertiseHost()
        guard NetworkInterface.isIPv4(host) else {
            teardownDataChannel()
            send("425 无法确定可回连的服务器地址，请在设置中填写 PASV 对外地址")
            return
        }
        let octets = host.split(separator: ".").map(String.init).joined(separator: ",")
        send("227 进入被动模式 (\(octets),\(port / 256),\(port % 256))")
    }

    /// 被动模式下向客户端通告的服务器地址。
    /// 优先级：手工配置 > 回环连接 > 控制连接的本地地址 > 主网卡地址。
    func advertiseHost() -> String {
        let configured = server.config.pasvAdvertiseHost.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }
        if remoteHost == "127.0.0.1" || remoteHost == "::1" || remoteHost.hasPrefix("127.") {
            return "127.0.0.1"
        }
        if NetworkInterface.isIPv4(localHost), localHost != "0.0.0.0" { return localHost }
        if let primary = NetworkInterface.primaryIPv4() { return primary }
        return "127.0.0.1"
    }

    private func handleIncomingDataConnection(_ connection: NWConnection) {
        if let waiter = waitingForData {
            waitingForData = nil
            dataWaitToken = nil
            connection.start(queue: stateQueue)
            waiter(connection)
            return
        }
        if pendingDataConnection == nil {
            connection.start(queue: stateQueue)
            pendingDataConnection = connection
        } else {
            connection.cancel()
        }
    }

    /// 取得本次传输可用的数据连接。
    /// - 已就绪的被动连接直接使用；
    /// - 主动模式则向客户端地址发起连接；
    /// - 被动监听已建立但连接尚未到达时等待（超时后回复 425）。
    /// completion 收到 nil 表示「未配置任何数据通道」。
    func obtainDataConnection(timeout: Double, completion: @escaping (NWConnection?) -> Void) {
        if let ready = pendingDataConnection {
            pendingDataConnection = nil
            completion(ready)
            return
        }

        if let endpoint = activeEndpoint {
            activeEndpoint = nil
            let connection = NWConnection(to: endpoint, using: NWParameters.tcp)
            var settled = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self, !settled else { return }
                switch state {
                case .ready:
                    settled = true
                    self.log(.debug, "主动模式数据连接已建立 → \(self.remoteHost)")
                    completion(connection)
                case .failed(let error):
                    settled = true
                    connection.cancel()
                    self.send("425 无法连接客户端数据端口：\(error.localizedDescription)")
                case .cancelled:
                    settled = true
                    self.send("425 客户端数据端口连接被取消")
                default:
                    break
                }
            }
            connection.start(queue: stateQueue)
            if timeout > 0 {
                stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self = self, !settled else { return }
                    settled = true
                    connection.cancel()
                    self.send("425 连接客户端数据端口超时")
                }
            }
            return
        }

        guard passiveListener != nil else {
            completion(nil)
            return
        }

        let token = UUID()
        dataWaitToken = token
        waitingForData = completion
        if timeout > 0 {
            stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self, self.dataWaitToken == token else { return }
                self.waitingForData = nil
                self.dataWaitToken = nil
                self.teardownDataChannel()
                self.send("425 等待客户端建立数据连接超时")
            }
        }
    }

    // MARK: - 传输收尾

    func concludeTransfer(error: Error?, action: String, name: String, started: Date, bytes: Int64) {
        cancelTransferWatchdog()
        isTransferring = false
        activeSender = nil
        activeReceiver = nil
        mutateSnapshot { $0.isTransferring = false; $0.transferSummary = "" }
        teardownDataChannel()

        if transferAbortRequested {
            transferAbortRequested = false
            return
        }

        let elapsed = max(0.001, Date().timeIntervalSince(started))
        if let error = error {
            log(.warning, "\(action) \(name) 中断：\(error.localizedDescription)")
            send("426 传输中断：\(error.localizedDescription)")
            return
        }
        let rate = Double(bytes) / elapsed
        log(.info, "\(action)完成 \(name)：\(ByteFormat.text(bytes))，耗时 \(String(format: "%.1f", elapsed)) 秒（\(ByteFormat.rate(rate))）")
        send("226 传输完成")
    }

    // MARK: - RETR

    func handleRETR(_ argument: String) throws {
        guard permissions.canDownload else { throw FTPError.permissionDenied("禁止下载") }
        let fileSystem = try requireVFS()
        let url = try fileSystem.resolveForRead(argument, relativeTo: cwd)
        guard fileSystem.exists(url) else { throw FTPError.notFound }
        guard !fileSystem.isDirectory(url) else { throw FTPError.isADirectory }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let name = url.lastPathComponent

        obtainDataConnection(timeout: server.config.dataTimeout) { [weak self] connection in
            guard let self = self else {
                connection?.cancel()
                return
            }
            guard let connection = connection else {
                self.send("425 \(FTPError.noDataConnection.message)")
                return
            }
            self.performDownload(url: url, size: size, name: name, on: connection)
        }
    }

    private func performDownload(url: URL, size: Int64, name: String, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            connection.cancel()
            send("450 无法打开文件：\(name)")
            return
        }

        var offset = restOffset
        restOffset = 0
        if offset > 0 {
            if offset >= size {
                offset = 0
            } else {
                try? handle.seek(toOffset: UInt64(offset))
            }
        }

        let source = FTPDownloadSource(handle: handle,
                                       remaining: size - offset,
                                       ascii: transferType == .ascii)
        let wireWillBeAscii = transferType == .ascii

        transferAbortRequested = false
        isTransferring = true
        mutateSnapshot { $0.isTransferring = true; $0.transferSummary = "下载 \(name)" }
        let modeText = wireWillBeAscii ? "ASCII" : "二进制"
        log(.info, "开始下载 \(name)（\(ByteFormat.text(size - offset))，\(modeText) 模式）")
        send("150 正在打开数据连接，准备发送 \(name)")
        beginTransferWatchdog()

        let started = Date()
        let sender = FTPDataSender(connection: connection) { [weak self] count in
            guard let self = self else { return }
            self.addBytesOut(Int64(count))
            self.touchTransferWatchdog()
        }
        activeSender = sender
        sender.start(producer: {
            source.nextChunk()
        }, completion: { [weak self] error in
            source.close()
            // 源文件中途读不出来时不能报成功，否则客户端收到 226 却少了数据
            let failure = source.endedEarly
                ? FTPError.io("源文件在传输途中被截断或读取失败")
                : nil
            self?.concludeTransfer(error: error ?? failure,
                                   action: "下载",
                                   name: name,
                                   started: started,
                                   bytes: source.bytesRead)
        })
    }

    // MARK: - STOR / APPE

    func handleSTOR(_ argument: String, append: Bool) throws {
        guard permissions.canUpload else { throw FTPError.permissionDenied("禁止上传") }
        let fileSystem = try requireVFS()
        let url = try fileSystem.resolveForWrite(argument, relativeTo: cwd)
        guard !fileSystem.isDirectory(url) else { throw FTPError.isADirectory }

        let name = url.lastPathComponent
        let resumeOffset = append ? -1 : restOffset
        restOffset = 0

        obtainDataConnection(timeout: server.config.dataTimeout) { [weak self] connection in
            guard let self = self else {
                connection?.cancel()
                return
            }
            guard let connection = connection else {
                self.send("425 \(FTPError.noDataConnection.message)")
                return
            }
            self.performUpload(url: url, name: name, append: append,
                               resumeOffset: resumeOffset, on: connection)
        }
    }

    private func performUpload(url: URL, name: String, append: Bool,
                               resumeOffset: Int64, on connection: NWConnection) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                connection.cancel()
                send("450 无法创建文件：\(name)")
                return
            }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            connection.cancel()
            send("450 无法写入文件：\(name)")
            return
        }
        if append {
            _ = try? handle.seekToEnd()
        } else if resumeOffset > 0 {
            try? handle.seek(toOffset: UInt64(resumeOffset))
            try? handle.truncate(atOffset: UInt64(resumeOffset))
        } else {
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
        }

        let sink = FTPUploadSink(handle: handle, ascii: transferType == .ascii)
        transferAbortRequested = false
        isTransferring = true
        mutateSnapshot { $0.isTransferring = true; $0.transferSummary = "上传 \(name)" }
        let modeText = transferType == .ascii ? "ASCII" : "二进制"
        log(.info, "开始接收 \(name)（\(modeText) 模式\(append ? "，追加" : "")）")
        send("150 正在打开数据连接，准备接收 \(name)")
        beginTransferWatchdog()

        let started = Date()
        let receiver = FTPDataReceiver(connection: connection, onBytes: { [weak self] count in
            guard let self = self else { return }
            self.addBytesIn(Int64(count))
            self.touchTransferWatchdog()
        }, onChunk: { data in
            try sink.write(data)
        })
        activeReceiver = receiver
        receiver.start { [weak self] error in
            var finalError = error
            if finalError == nil {
                do {
                    try sink.finish()
                } catch {
                    finalError = error
                }
            } else {
                sink.close()
            }
            self?.concludeTransfer(error: finalError,
                                   action: "上传",
                                   name: name,
                                   started: started,
                                   bytes: sink.bytesWritten)
        }
    }

    // MARK: - LIST / NLST / MLSD

    /// 剥离 `-la` 之类的选项，返回剩余的路径参数。
    static func extractPathArgument(_ argument: String) -> String {
        argument.split(separator: " ")
            .map(String.init)
            .filter { !$0.hasPrefix("-") }
            .joined(separator: " ")
    }

    func handleList(argument: String, mode: ListMode) throws {
        guard permissions.canDownload else { throw FTPError.permissionDenied("禁止列举目录") }
        let fileSystem = try requireVFS()
        let pathArgument = FTPSession.extractPathArgument(argument)
        let normalized = try fileSystem.normalize(pathArgument.isEmpty ? cwd : pathArgument,
                                                  relativeTo: cwd)
        let url = fileSystem.fileURL(for: normalized)
        try fileSystem.ensureInsideRoot(url)
        guard fileSystem.exists(url) else { throw FTPError.notFound }

        let payload: Data
        if fileSystem.isDirectory(url) {
            let entries = try fileSystem.list(normalized)
            switch mode {
            case .list: payload = FTPVirtualFileSystem.listData(entries: entries)
            case .nlst: payload = FTPVirtualFileSystem.nlstData(entries: entries)
            case .mlsd: payload = FTPVirtualFileSystem.mlsdData(entries: entries, permissions: permissions)
            }
        } else {
            let item = try fileSystem.entry(for: url)
            switch mode {
            case .list: payload = FTPVirtualFileSystem.listData(entries: [item])
            case .nlst: payload = Data((item.name + "\r\n").utf8)
            case .mlsd: payload = FTPVirtualFileSystem.mlsdData(entries: [item], permissions: permissions)
            }
        }

        let label = mode.label
        obtainDataConnection(timeout: server.config.dataTimeout) { [weak self] connection in
            guard let self = self else {
                connection?.cancel()
                return
            }
            guard let connection = connection else {
                self.send("425 \(FTPError.noDataConnection.message)")
                return
            }
            self.performSend(payload: payload, label: label, name: normalized, on: connection)
        }
    }

    private func performSend(payload: Data, label: String, name: String, on connection: NWConnection) {
        transferAbortRequested = false
        isTransferring = true
        mutateSnapshot { $0.isTransferring = true; $0.transferSummary = "\(label) \(name)" }
        log(.debug, "\(label) \(name)（\(payload.count) 字节）")
        send("150 正在打开数据连接")
        beginTransferWatchdog()

        let started = Date()
        let source = FTPMemorySource(payload: payload)
        let sender = FTPDataSender(connection: connection) { [weak self] count in
            guard let self = self else { return }
            self.addBytesOut(Int64(count))
            self.touchTransferWatchdog()
        }
        activeSender = sender
        sender.start(producer: {
            source.nextChunk()
        }, completion: { [weak self] error in
            self?.concludeTransfer(error: error,
                                   action: label,
                                   name: name,
                                   started: started,
                                   bytes: Int64(payload.count))
        })
    }

    // MARK: - MLST（走控制通道）

    func handleMLST(_ argument: String) throws {
        let fileSystem = try requireVFS()
        let normalized = try fileSystem.normalize(argument.isEmpty ? cwd : argument, relativeTo: cwd)
        let url = fileSystem.fileURL(for: normalized)
        try fileSystem.ensureInsideRoot(url)
        guard fileSystem.exists(url) else { throw FTPError.notFound }
        let item = try fileSystem.entry(for: url, name: normalized)
        let line = FTPVirtualFileSystem.mlsdLine(for: item, permissions: permissions)
        send("250-\(normalized) 的条目信息：\r\n \(line)\r\n250 结束")
    }

    // MARK: - ABOR

    func handleABOR() {
        guard isTransferring else {
            teardownDataChannel()
            send("226 当前没有正在进行的传输")
            return
        }
        transferAbortRequested = true
        activeSender?.abort()
        activeReceiver?.abort()
        cancelTransferWatchdog()
        isTransferring = false
        mutateSnapshot { $0.isTransferring = false; $0.transferSummary = "" }
        teardownDataChannel()
        log(.warning, "客户端中止了传输")
        send("426 传输已被客户端中止，数据连接已关闭")
        send("226 中止命令执行完成")
    }
}
