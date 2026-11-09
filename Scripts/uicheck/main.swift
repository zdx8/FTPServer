import SwiftUI
import AppKit
import Network

/// 界面层测试，分两部分：
///
/// 1. **渲染测试**：活动会话列表曾用 `Table` 实现，放在 `VStack` 中未显式约束尺寸——
///    会话数据确实已推送到视图模型，但行一个都不显示。这类缺陷在数据层测不出来，
///    必须在渲染层断言。
///    做法：离屏渲染两次，只改一个会话的客户端地址（其余字段完全相同），
///    若行真的被绘制，两张图必然不同；若行不显示，两张图字节级一致。
///
/// 2. **端到端测试**：真实服务器 + 真实客户端 + 真实视图模型桥接，
///    覆盖「客户端接入 → 服务器推送 → 视图模型收到 → 界面渲染」整条链路。
///    这是用户报的「连接了但活动会话不显示」的完整复现路径。

let canvasSize = CGSize(width: 1100, height: 640)
let fixedDate = Date()

func snapshot(address: String, bytesIn: Int64 = 4096, bytesOut: Int64 = 8192) -> FTPSessionSnapshot {
    FTPSessionSnapshot(id: UUID(),
                       remoteAddress: address,
                       username: "anonymous",
                       currentDirectory: "/downloads",
                       isTransferring: false,
                       transferSummary: "",
                       bytesIn: bytesIn,
                       bytesOut: bytesOut,
                       connectedAt: fixedDate,
                       lastCommand: "PASV")
}

var failureCount = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    print("  [\(condition ? "PASS" : "FAIL")] \(name)\(condition ? "" : "  → \(detail)")")
    if !condition { failureCount += 1 }
}

/// 驱动主队列与网络回调。
func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
}

let model = ServerViewModel.shared

/// 离屏渲染。视图挂进一个永不显示的无边框窗口，保证布局完整解析；
/// 不用 ImageRenderer 是因为它带主 actor 隔离，在命令行入口里不好调用。
func render(_ sessions: [FTPSessionSnapshot]) -> Data? {
    model.applySessions(sessions)

    let rootView = SessionsView(model: model)
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(Color.white)
        .environment(\.colorScheme, .light)

    let hosting = NSHostingView(rootView: rootView)
    hosting.frame = NSRect(origin: .zero, size: canvasSize)

    let window = NSWindow(contentRect: hosting.frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.contentView = hosting
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    window.contentView = nil
    return rep.representation(using: .png, properties: [:])
}

// MARK: - 一、渲染测试

print("== 渲染测试：会话行是否真的被绘制 ==")

guard let emptyImage = render([]) else {
    print("  渲染失败：未能产出图像")
    exit(1)
}
check("空会话时渲染成功", !emptyImage.isEmpty, "得到 \(emptyImage.count) 字节")

let addressA = "192.0.2.40:51234"
let addressB = "198.51.100.88:61000"

guard let imageA = render([snapshot(address: addressA)]) else {
    print("  渲染失败：有会话时未能产出图像")
    exit(1)
}
check("有会话时渲染成功", !imageA.isEmpty, "得到 \(imageA.count) 字节")

guard let imageB = render([snapshot(address: addressB)]) else {
    print("  渲染失败：第二张图像生成失败")
    exit(1)
}

check("空状态与有会话状态的渲染结果不同",
      emptyImage != imageA,
      "两者字节数 \(emptyImage.count) / \(imageA.count)")

// 核心断言：两次渲染的输入只有一个字段不同，若行被绘制则图像必然不同
check("会话行确实被绘制（客户端地址不同导致渲染不同）",
      imageA != imageB,
      "两张图完全一致 → 行未渲染")

guard let heavyImage = render([snapshot(address: addressA, bytesIn: 12_345_678)]) else {
    print("  渲染失败：大字节量图像生成失败")
    exit(1)
}
check("行内容变化会改变渲染结果", heavyImage != imageA, "字节量变化未反映到画面上")

// MARK: - 二、端到端测试

print("")
print("== 端到端测试：真实客户端 → 服务器 → 视图模型 → 渲染 ==")

let root = NSTemporaryDirectory() + "ftpserver-uicheck-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: root) }

var config = ServerConfig()
config.port = 21901
config.bindAllInterfaces = false
config.defaultRootPath = root
config.anonymousRootPath = root
config.pasvAdvertiseHost = "127.0.0.1"
config.logLevel = .warning

// 直接调用 server.start，避免经过 startServer() 而把测试端口写进用户配置
do {
    try model.server.start(config: config)
} catch {
    print("  服务启动失败：\(error.localizedDescription)")
    exit(1)
}
pump(1.5)
check("服务已运行", model.server.isRunning, model.state.label)
check("视图模型状态已同步为运行中", model.state.isRunning, "\(model.state)")
check("启动阶段会话列表为空", model.sessions.isEmpty, "\(model.sessions.count)")

let client = NWConnection(host: "127.0.0.1",
                          port: NWEndpoint.Port(rawValue: config.port)!,
                          using: .tcp)
client.start(queue: .global())
pump(2.5)

check("真实客户端接入后视图模型收到会话",
      model.sessions.count == 1,
      "视图模型中有 \(model.sessions.count) 个会话")

if let live = model.sessions.first {
    check("会话携带客户端地址", live.remoteAddress.contains("127.0.0.1"), live.remoteAddress)
    let liveImage = render(model.sessions)
    check("真实会话数据可渲染出画面",
          liveImage != nil && liveImage != emptyImage,
          "渲染结果与空状态相同")
}

// 登录后用户名应更新，验证会话对象是同一个且状态在推进
client.send(content: Data("USER anonymous\r\nPASS a@b.c\r\nNOOP\r\n".utf8),
            completion: .contentProcessed { _ in })
pump(2.0)
check("登录后用户名更新",
      model.sessions.first?.username == "anonymous",
      model.sessions.first?.username ?? "无会话")

client.cancel()
pump(2.5)
check("客户端断开后视图模型清空", model.sessions.isEmpty, "剩余 \(model.sessions.count) 个")

model.server.stop()
pump(0.6)
check("服务停止后状态同步", !model.state.isRunning, "\(model.state)")

print("")
print(failureCount == 0 ? "界面层测试全部通过" : "界面层测试失败 \(failureCount) 项")
exit(failureCount == 0 ? 0 : 1)
