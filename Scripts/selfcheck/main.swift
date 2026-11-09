import Foundation
import Network

/// 会话发布链路自检。
///
/// 专门覆盖「客户端连接后，服务器是否把会话列表推送给了界面」这条链路——
/// 这是界面看不到活动会话时最先要排除的一环。不依赖 SwiftUI，可直接用
/// swiftc 编译运行。

final class StubObserver: FTPServerObserver {
    private(set) var published: [[FTPSessionSnapshot]] = []
    private(set) var states: [FTPServerState] = []
    private(set) var statsPublishes = 0

    func ftpServerDidChangeState(_ state: FTPServerState) { states.append(state) }
    func ftpServerDidUpdateSessions(_ sessions: [FTPSessionSnapshot]) { published.append(sessions) }
    func ftpServerDidUpdateStats(_ stats: FTPServerStats) { statsPublishes += 1 }
}

/// 在无 RunLoop 的命令行进程里驱动主队列回调。
func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
}

var failureCount = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    print("  [\(condition ? "PASS" : "FAIL")] \(name)\(condition ? "" : "  → \(detail)")")
    if !condition { failureCount += 1 }
}

// MARK: - 准备

let root = NSTemporaryDirectory() + "ftpserver-selfcheck-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
try? "hello\n".write(toFile: root + "/hello.txt", atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(atPath: root) }

let port: UInt16 = 21999
let server = FTPServer()
let observer = StubObserver()
server.addObserver(observer)

var config = ServerConfig()
config.port = port
config.defaultRootPath = root
config.anonymousRootPath = root
config.pasvAdvertiseHost = "127.0.0.1"
config.idleTimeout = 120
config.anonymousEnabled = true

print("== 服务启动 ==")
do {
    try server.start(config: config)
} catch {
    print("  启动失败：\(error.localizedDescription)")
    exit(1)
}
pump(1.5)
check("服务进入运行状态", server.state.isRunning, server.state.label)
check("已开始推送统计", observer.statsPublishes > 0, "收到 \(observer.statsPublishes) 次")

print("== 客户端连接前，会话列表应为空 ==")
check("初始会话列表为空", (observer.published.last?.count ?? 0) == 0,
      "\(observer.published.last?.count ?? -1)")

print("== 客户端连接后，必须推送非空会话列表 ==")
let connection = NWConnection(host: "127.0.0.1",
                              port: NWEndpoint.Port(rawValue: port)!,
                              using: .tcp)
connection.start(queue: .global())
pump(2.0)

let observedCounts = observer.published.map { $0.count }
check("推送过含 1 个会话的快照", observedCounts.contains(1), "观测到的计数序列：\(observedCounts)")

if let latest = observer.published.last {
    let addresses = latest.map { $0.remoteAddress }
    check("会话条目带客户端地址",
          addresses.contains { $0.contains("127.0.0.1") },
          "地址列表：\(addresses)")
    check("会话条目带唯一标识", Set(latest.map { $0.id }).count == latest.count, "\(latest.count) 条")
} else {
    check("收到过会话通知", false, "从未收到 ftpServerDidUpdateSessions")
}

print("== 登录后用户名应更新 ==")
connection.send(content: Data("USER anonymous\r\nPASS a@b.c\r\n".utf8),
                completion: .contentProcessed { _ in })
pump(2.0)
let usernames = observer.published.last?.map { $0.username } ?? []
check("用户名更新为 anonymous", usernames.contains("anonymous"), "\(usernames)")

print("== 断开后会话列表应清空 ==")
connection.cancel()
pump(2.0)
let remaining = observer.published.last?.count ?? -1
check("断开后会话列表归零", remaining == 0, "剩余 \(remaining)")

print("")
print("== 绑定模式：仅本机 / 全部网卡 ==")
// 「仅本机」曾经无法启动：requiredLocalEndpoint 已携带端口，再给 on: 传端口会直接 EINVAL。
// 这里同时核对两种模式的实际绑定地址，而不只是「启动成功」。

/// 用 lsof 直接读取该端口上监听套接字绑定的本地地址。
func listenBinding(port: UInt16) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return ""
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}

func bindModeCheck(_ label: String, port: UInt16, bindAll: Bool) -> FTPServer {
    var config = ServerConfig()
    config.port = port
    config.bindAllInterfaces = bindAll
    config.defaultRootPath = root
    config.anonymousRootPath = root
    config.logLevel = .error

    let instance = FTPServer()
    do {
        try instance.start(config: config)
    } catch {
        check("\(label)可启动", false, error.localizedDescription)
        return instance
    }
    pump(1.5)
    check("\(label)可启动", instance.state.isRunning, instance.state.label)

    let binding = listenBinding(port: port)
    let loopbackBound = binding.contains("127.0.0.1:\(port)")
    let wildcardBound = binding.contains("*:\(port)") || binding.contains("0.0.0.0:\(port)")

    if bindAll {
        check("\(label)绑定到全部网卡", wildcardBound, binding.replacingOccurrences(of: "\n", with: " | "))
    } else {
        check("\(label)绑定到 127.0.0.1", loopbackBound, binding.replacingOccurrences(of: "\n", with: " | "))
        check("\(label)未暴露到局域网", !wildcardBound, binding.replacingOccurrences(of: "\n", with: " | "))
    }
    return instance
}

let loopbackServer = bindModeCheck("仅本机模式", port: 21960, bindAll: false)
loopbackServer.stop()
pump(0.6)

let allInterfaceServer = bindModeCheck("全部网卡模式", port: 21961, bindAll: true)
allInterfaceServer.stop()
pump(0.6)

print("")
print("== 配置向后兼容 ==")
// 新增字段后，已发布的 config.json 缺少这些键时仍必须能解析出默认值，
// 否则老用户升级会整份配置丢失。
let legacyJSON = """
{
  "port": 3131,
  "bindAllInterfaces": false,
  "defaultRootPath": "/tmp/legacy-root",
  "anonymousEnabled": false,
  "anonymousRootPath": "/tmp/legacy-anon",
  "anonymousCanUpload": true,
  "anonymousCanDelete": true,
  "anonymousCanCreateDirectory": true,
  "maxConnections": 7,
  "idleTimeout": 111,
  "dataTimeout": 22,
  "pasvAdvertiseHost": "192.0.2.3",
  "logLevel": "warning",
  "accounts": []
}
"""
do {
    let decoded = try JSONDecoder().decode(ServerConfig.self, from: Data(legacyJSON.utf8))
    check("旧配置缺少 autoStart 时取默认值", decoded.autoStart == false, "\(decoded.autoStart)")
    check("旧配置缺少 closeBehavior 时按退出处理",
          decoded.closeBehavior == .quit, "\(decoded.closeBehavior)")
    check("旧配置的既有字段被完整保留",
          decoded.port == 3131 && decoded.maxConnections == 7
          && decoded.logLevel == .warning && decoded.pasvAdvertiseHost == "192.0.2.3"
          && decoded.bindAllInterfaces == false,
          "port=\(decoded.port) max=\(decoded.maxConnections)")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let roundTripDecoder = JSONDecoder()
    roundTripDecoder.dateDecodingStrategy = .iso8601
    if let data = try? encoder.encode(decoded),
       let roundTrip = try? roundTripDecoder.decode(ServerConfig.self, from: data) {
        check("配置编解码往返一致", roundTrip == decoded, "往返结果不一致")
    } else {
        check("配置编解码往返一致", false, "编解码失败")
    }
} catch {
    check("旧配置可解析", false, "\(error)")
}

let readOnlyAccount = FTPAccount(username: "guest", password: "pw", rootPath: "/tmp/legacy-readonly",
                                 canDownload: true, canUpload: false,
                                 canDelete: false, canCreateDirectory: false)
check("只读账号权限摘要正确", readOnlyAccount.permissionSummary == "下载",
      readOnlyAccount.permissionSummary)
check("口令校验区分大小写且拒绝错误口令",
      readOnlyAccount.verify(password: "pw") && !readOnlyAccount.verify(password: "PW"),
      "口令校验异常")

print("")
print("== 符号链接写入防护（Core 层） ==")
// 读路径解析整条路径校验包含性即可；写路径校验的是**父目录**，
// 因此必须单独确认目标自身不是指向根目录之外的软链接，
// 否则 STOR / APPE / MKD 会顺链落到共享目录之外。
let escapeBase = NSTemporaryDirectory() + "ftpserver-escape-\(UUID().uuidString)"
let escapeRoot = escapeBase + "/root"
let escapeOutside = escapeBase + "/outside"
try? FileManager.default.createDirectory(atPath: escapeRoot, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: escapeOutside, withIntermediateDirectories: true)
try? "SECRET\n".write(toFile: escapeOutside + "/secret.txt", atomically: true, encoding: .utf8)
try? "inside\n".write(toFile: escapeRoot + "/inner.txt", atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(atPath: escapeBase) }

let vfs = FTPVirtualFileSystem(rootPath: escapeRoot)
try? FileManager.default.createSymbolicLink(atPath: escapeRoot + "/link-out.txt",
                                            withDestinationPath: escapeOutside + "/secret.txt")
try? FileManager.default.createSymbolicLink(atPath: escapeRoot + "/link-dangling.txt",
                                            withDestinationPath: escapeOutside + "/new.txt")
try? FileManager.default.createSymbolicLink(atPath: escapeRoot + "/link-in.txt",
                                            withDestinationPath: escapeRoot + "/inner.txt")

func writable(_ path: String) -> Bool {
    (try? vfs.resolveForWrite(path, relativeTo: "/")) != nil
}
check("拒绝写入指向根外的软链接", !writable("link-out.txt"))
check("拒绝写入悬空软链接", !writable("link-dangling.txt"))
check("允许写入指向根内的软链接", writable("link-in.txt"))
check("允许写入普通新文件", writable("brand-new.txt"))
check("拒绝越出根目录的写入路径", !writable("../outside/secret.txt"))
let stillSecret = (try? String(contentsOfFile: escapeOutside + "/secret.txt",
                               encoding: .utf8)) ?? ""
check("根目录外的文件未被改动", stillSecret == "SECRET\n", stillSecret)
check("normalize 拒绝越出根目录的 ..",
      (try? vfs.normalize("../../etc/passwd", relativeTo: "/")) == nil,
      "越界路径未被拒绝")

print("")
print("== 下载源中途截断检测 ==")
// 源文件在传输途中被截断或读取出错时，必须与「正常读完」区分开，
// 否则客户端会收到 226 却拿到短了的数据。
let truncatePath = escapeRoot + "/truncate.bin"
var big = Data(count: 400_000)
big.withUnsafeMutableBytes { buffer in
    for index in stride(from: 0, to: buffer.count, by: 4096) {
        buffer[index] = UInt8(index % 251)
    }
}
try? big.write(to: URL(fileURLWithPath: truncatePath))
if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: truncatePath)) {
    let source = FTPDownloadSource(handle: handle, remaining: Int64(big.count), ascii: false)
    _ = source.nextChunk()
    if let writer = try? FileHandle(forWritingTo: URL(fileURLWithPath: truncatePath)) {
        try? writer.truncate(atOffset: 0)
        try? writer.close()
    }
    var guardCount = 0
    while source.nextChunk() != nil {
        guardCount += 1
        if guardCount > 10_000 { break }
    }
    source.close()
    check("源文件中途截断被标记为异常", source.endedEarly,
          "endedEarly=\(source.endedEarly)")
} else {
    check("源文件中途截断被标记为异常", false, "无法打开测试文件")
}
if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: escapeRoot + "/inner.txt")) {
    let source = FTPDownloadSource(handle: handle, remaining: 7, ascii: false)
    while source.nextChunk() != nil {}
    source.close()
    check("正常读完不被误判为截断", !source.endedEarly, "endedEarly 误为 true")
} else {
    check("正常读完不被误判为截断", false, "无法打开测试文件")
}

print("== 服务停止后状态正确 ==")
server.stop()
pump(0.6)
check("服务状态为已停止", !server.state.isRunning, server.state.label)

print("")
print(failureCount == 0 ? "自检全部通过（\(observer.published.count) 次会话推送）"
                        : "自检失败 \(failureCount) 项")
exit(failureCount == 0 ? 0 : 1)
