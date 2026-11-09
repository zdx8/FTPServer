import Foundation
import Network

// MARK: - ASCII 传输模式转换（RFC 959 TYPE A）

/// 网络侧行结束符为 CRLF，本地侧为 LF。
/// 分块处理时用 1 字节回溯状态避免跨块边界的 CR/LF 被错切。
final class ASCIITranscoder {
    private let uploading: Bool
    private var pendingCR = false

    init(uploading: Bool) { self.uploading = uploading }

    func transform(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count + 16)
        for byte in data {
            if pendingCR {
                pendingCR = false
                if byte == 0x0A {
                    output.append(uploading ? 0x0A : 0x0D)
                    if !uploading { output.append(0x0A) }
                    continue
                }
                output.append(0x0D)
            }
            if byte == 0x0D {
                pendingCR = true
            } else if byte == 0x0A {
                if uploading {
                    output.append(0x0A)
                } else {
                    output.append(contentsOf: [0x0D, 0x0A])
                }
            } else {
                output.append(byte)
            }
        }
        return output
    }

    func flush() -> Data {
        guard pendingCR else { return Data() }
        pendingCR = false
        return uploading ? Data([0x0D]) : Data([0x0D, 0x0A])
    }
}

// MARK: - 数据通道发送器（生产者驱动，天然背压，一次仅一块在途）

final class FTPDataSender {
    private let connection: NWConnection
    private let onBytes: (Int) -> Void
    private var producer: (() -> Data?)?
    private var completion: ((Error?) -> Void)?
    private var isFinished = false

    init(connection: NWConnection, onBytes: @escaping (Int) -> Void) {
        self.connection = connection
        self.onBytes = onBytes
    }

    func start(producer: @escaping () -> Data?, completion: @escaping (Error?) -> Void) {
        self.producer = producer
        self.completion = completion
        pump()
    }

    /// 主动中止（ABOR 或超时）。不会产生第二次回调。
    func abort() {
        guard !isFinished else { return }
        isFinished = true
        producer = nil
        let done = completion
        completion = nil
        connection.cancel()
        done?(nil)
    }

    private func pump() {
        while true {
            guard !isFinished, let producer = producer else { return }
            guard let chunk = producer() else { finish(error: nil); return }
            if chunk.isEmpty { continue }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self = self, !self.isFinished else { return }
                if let error = error {
                    self.finish(error: error)
                    return
                }
                self.onBytes(chunk.count)
                self.pump()
            })
            return
        }
    }

    private func finish(error: Error?) {
        guard !isFinished else { return }
        isFinished = true
        producer = nil
        let done = completion
        completion = nil
        connection.send(content: nil,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            done?(error)
        })
    }
}

// MARK: - 数据通道接收器

final class FTPDataReceiver {
    private let connection: NWConnection
    private let onBytes: (Int) -> Void
    private let onChunk: (Data) throws -> Void
    private var completion: ((Error?) -> Void)?
    private var isFinished = false

    init(connection: NWConnection,
         onBytes: @escaping (Int) -> Void,
         onChunk: @escaping (Data) throws -> Void) {
        self.connection = connection
        self.onBytes = onBytes
        self.onChunk = onChunk
    }

    func start(completion: @escaping (Error?) -> Void) {
        self.completion = completion
        receive()
    }

    func abort() {
        guard !isFinished else { return }
        isFinished = true
        connection.cancel()
        let done = completion
        completion = nil
        done?(nil)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isFinished else { return }
            if let data = data, !data.isEmpty {
                do {
                    try self.onChunk(data)
                    self.onBytes(data.count)
                } catch {
                    self.finish(error: error)
                    return
                }
            }
            if let error = error {
                self.finish(error: error)
                return
            }
            if isComplete {
                self.finish(error: nil)
                return
            }
            self.receive()
        }
    }

    private func finish(error: Error?) {
        guard !isFinished else { return }
        isFinished = true
        connection.cancel()
        let done = completion
        completion = nil
        done?(error)
    }
}

// MARK: - 下载数据源

final class FTPDownloadSource {
    private let handle: FileHandle
    private var remaining: Int64
    private let transcoder: ASCIITranscoder?
    private var finished = false
    private var closed = false

    /// 已从磁盘读出的原始字节数（用于统计与日志，不等同于线路字节数）。
    private(set) var bytesRead: Int64 = 0

    /// 尚未读满预定长度就中断（文件被截断或读取出错）。
    /// 必须区别于正常读完，否则客户端会收到 226 却拿到短了的数据。
    private(set) var endedEarly = false

    init(handle: FileHandle, remaining: Int64, ascii: Bool) {
        self.handle = handle
        self.remaining = max(0, remaining)
        self.transcoder = ascii ? ASCIITranscoder(uploading: false) : nil
    }

    func nextChunk() -> Data? {
        if finished { return nil }
        if remaining > 0 {
            let want = Int(min(65536, remaining))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else {
                // 还剩字节可读却读不出来，说明源文件在传输途中被截断或读取失败
                endedEarly = true
                finished = true
                close()
                return nil
            }
            remaining -= Int64(chunk.count)
            bytesRead += Int64(chunk.count)
            return transcoder?.transform(chunk) ?? chunk
        }
        finished = true
        close()
        if let transcoder = transcoder {
            let tail = transcoder.flush()
            return tail.isEmpty ? nil : tail
        }
        return nil
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

// MARK: - 上传数据接收

final class FTPUploadSink {
    private let handle: FileHandle
    private let transcoder: ASCIITranscoder?
    private var closed = false
    private(set) var bytesWritten: Int64 = 0

    init(handle: FileHandle, ascii: Bool) {
        self.handle = handle
        self.transcoder = ascii ? ASCIITranscoder(uploading: true) : nil
    }

    func write(_ data: Data) throws {
        let output = transcoder?.transform(data) ?? data
        guard !output.isEmpty else { return }
        try handle.write(contentsOf: output)
        bytesWritten += Int64(output.count)
    }

    func finish() throws {
        if let transcoder = transcoder {
            let tail = transcoder.flush()
            if !tail.isEmpty {
                try handle.write(contentsOf: tail)
                bytesWritten += Int64(tail.count)
            }
        }
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
