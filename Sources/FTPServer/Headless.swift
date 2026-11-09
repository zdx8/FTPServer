import Foundation

/// 无界面运行模式：`FTPServer --headless [选项]`
///
/// 该模式让同一份二进制既可以作为桌面应用运行，也可以被脚本、
/// launchd 或自动化测试直接驱动，无需触碰界面。
enum HeadlessRunner {

    static func run(arguments: [String]) -> Never {
        var port: UInt16 = 2121
        var rootPath: String? = nil
        var anonymousRootPath: String? = nil
        var bindAllInterfaces = true
        var pasvAdvertiseHost = ""
        var logLevel = LogLevel.info
        var accounts: [FTPAccount] = []

        var index = 0
        func nextValue() -> String? {
            guard index + 1 < arguments.count else { return nil }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--port":
                if let value = nextValue(), let parsed = UInt16(value) { port = parsed }
            case "--root":
                if let value = nextValue() { rootPath = value }
            case "--anonymous-root":
                if let value = nextValue() { anonymousRootPath = value }
            case "--localhost":
                bindAllInterfaces = false
            case "--pasv-host":
                if let value = nextValue() { pasvAdvertiseHost = value }
            case "--log-level":
                if let value = nextValue(), let parsed = LogLevel(rawValue: value) { logLevel = parsed }
            case "--user":
                if index + 3 < arguments.count {
                    let name = arguments[index + 1]
                    let password = arguments[index + 2]
                    let path = arguments[index + 3]
                    index += 3
                    // 可选的权限描述：r=查看与下载 w=上传 d=删除与重命名 m=创建目录
                    var spec = "rwmd"
                    if index + 1 < arguments.count {
                        let candidate = arguments[index + 1]
                        if !candidate.hasPrefix("--"),
                           candidate.range(of: "^[rwmd]+$", options: .regularExpression) != nil {
                            spec = candidate
                            index += 1
                        }
                    }
                    var account = FTPAccount(username: name, password: password, rootPath: path)
                    account.canDownload = spec.contains("r")
                    account.canUpload = spec.contains("w")
                    account.canDelete = spec.contains("d")
                    account.canCreateDirectory = spec.contains("m")
                    accounts.append(account)
                }
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                break
            }
            index += 1
        }

        var config = ServerConfig()
        config.port = port
        config.bindAllInterfaces = bindAllInterfaces
        config.pasvAdvertiseHost = pasvAdvertiseHost
        config.logLevel = logLevel
        config.accounts = accounts
        if let rootPath = rootPath {
            config.defaultRootPath = rootPath
            config.anonymousRootPath = rootPath
        }
        if let anonymousRootPath = anonymousRootPath {
            config.anonymousRootPath = anonymousRootPath
        }

        let server = FTPServer()
        let observer = ConsoleObserver()
        server.addObserver(observer)

        do {
            try server.start(config: config)
        } catch {
            FileHandle.standardError.write(Data("启动失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }

        // 等待监听真正就绪后再打印接入信息，避免输出与实际状态不一致
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            print("")
            print("FTP Server 已启动")
            print("  监听端口   : \(config.port)")
            print("  绑定范围   : \(config.bindAllInterfaces ? "0.0.0.0（全部网卡）" : "127.0.0.1（仅本机）")")
            print("  匿名根目录 : \(config.anonymousRootPath)")
            if let primary = NetworkInterface.primaryIPv4() {
                print("  局域网地址 : ftp://\(primary):\(config.port)")
            }
            print("  本机地址   : ftp://127.0.0.1:\(config.port)")
            if !accounts.isEmpty {
                print("  账号       : \(accounts.map { $0.username }.joined(separator: ", "))")
            }
            print("")
            print("按 Ctrl+C 停止服务")
            print("")
            fflush(stdout)
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interruptSource.setEventHandler {
            print("\n正在停止服务…")
            server.stop()
            print("服务已停止")
            exit(0)
        }
        interruptSource.resume()

        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminateSource.setEventHandler {
            print("\n正在停止服务…")
            server.stop()
            exit(0)
        }
        terminateSource.resume()

        dispatchMain()
    }

    private static func printUsage() {
        print("""
        FTPServer（无界面模式）

        用法：
          FTPServer --headless [选项]

        选项：
          --port <端口>            监听端口，默认 2121
          --root <目录>            根目录（同时作为匿名根目录）
          --anonymous-root <目录>  单独指定匿名根目录
          --localhost              仅绑定 127.0.0.1，不暴露到局域网
          --pasv-host <IPv4>       被动模式对外通告的地址（NAT/多网卡环境使用）
          --log-level <级别>       debug | info | warning | error
          --user <用户名> <口令> <根目录> [权限]
                                   添加一个账号，可重复多次。
                                   权限由 r w d m 组合而成，缺省为 rwmd：
                                     r = 查看与下载   w = 上传文件
                                     d = 删除与重命名 m = 创建目录
                                   例如 `--user guest pw /tmp/share r` 为只读账号
          --help                   显示本帮助
        """)
    }
}

private final class ConsoleObserver: FTPServerObserver {
    private let formatter: DateFormatter

    init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
    }

    func ftpServerDidLog(_ entry: FTPLogEntry) {
        print("[\(formatter.string(from: entry.timestamp))] [\(entry.level.label)] [\(entry.session)] \(entry.message)")
        fflush(stdout)
    }

    func ftpServerDidChangeState(_ state: FTPServerState) {
        print("[状态] \(state.label)\(state.failureReason.map { "：\($0)" } ?? "")")
        fflush(stdout)
    }
}
