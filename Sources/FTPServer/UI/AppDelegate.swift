import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 非 Xcode 打包的 SwiftUI 应用必须显式声明为常规前台应用，
        // 否则从命令行启动时不会出现在 Dock，也无法获得焦点。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 主题偏好要在窗口绘制前施加，避免启动瞬间闪一下系统外观
        ThemeController.shared.applyAppearance()

        let model = ServerViewModel.shared
        if model.config.autoStart, !model.server.isRunning {
            model.startServer()
        }
    }

    /// 关闭主窗口时是否退出进程，取决于用户的偏好设置。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        switch ServerViewModel.shared.config.closeBehavior {
        case .quit:
            return true
        case .minimizeToMenuBar:
            // 隐藏 Dock 图标，退居菜单栏；服务继续运行。
            // 延后一拍执行，避免在窗口关闭过程中改变激活策略引发动画异常。
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ServerViewModel.shared.server.stop()
    }
}

enum AppWindow {
    /// 主窗口标识。菜单栏面板需要用它重新打开窗口，
    /// 定义在中立位置以便 UI 层各部分（含测试）都能引用。
    static let main = "main-window"
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard
    case sessions
    case logs
    case accounts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "概览"
        case .sessions:  return "活动会话"
        case .logs:      return "运行日志"
        case .accounts:  return "用户账号"
        case .settings:  return "设置"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .sessions:  return "person.2"
        case .logs:      return "text.alignleft"
        case .accounts:  return "person.badge.key"
        case .settings:  return "gearshape"
        }
    }

    var group: String {
        switch self {
        case .dashboard, .sessions, .logs: return "运行"
        case .accounts, .settings:         return "配置"
        }
    }
}
