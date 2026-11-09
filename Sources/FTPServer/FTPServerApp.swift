import SwiftUI

@main
struct FTPServerEntry {
    static func main() {
        // 无界面模式：同一份二进制可由脚本或自动化测试直接驱动
        if CommandLine.arguments.contains("--headless") {
            HeadlessRunner.run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        FTPDesktopApp.main()
    }
}

struct FTPDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ServerViewModel.shared

    var body: some Scene {
        // 用 Window 而非 WindowGroup：本应用天然只有一个主窗口，
        // 关闭后需要能被菜单栏重新打开，单例窗口场景语义更准确。
        Window("FTP Server", id: AppWindow.main) {
            ContentView()
                .frame(minWidth: 1040, minHeight: 700)
        }
        .defaultSize(width: 1180, height: 790)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // 常驻菜单栏：关闭主窗口后仍可操作服务
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// 图标反映服务状态，便于一眼判断是否在对外提供服务。
    private var menuBarIcon: String {
        model.server.isRunning ? "dot.radiowaves.left.and.right" : "server.rack"
    }
}
