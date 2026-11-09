import SwiftUI
import AppKit

/// 界面主题。`system` 表示跟随系统外观。
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// 主题控制器：持久化偏好，并把外观同时施加到 AppKit 与 SwiftUI 两侧。
///
/// 两侧都必须设置，否则窗口标题栏、下拉菜单、文件选择面板会与内容区外观相反：
/// - `NSApp.appearance` 管原生部件
/// - 根视图上的 `.preferredColorScheme` 管 SwiftUI 绘制部分
final class ThemeController: ObservableObject {

    static let shared = ThemeController()

    private static let storageKey = "appAppearance"

    @Published private(set) var theme: AppTheme

    private init() {
        let stored = UserDefaults.standard.string(forKey: ThemeController.storageKey) ?? ""
        theme = AppTheme(rawValue: stored) ?? .system
    }

    /// 工具栏按钮的点击行为：在浅色与深色之间来回切换。
    /// 当前为「跟随系统」时切到系统外观的反面，符合直觉。
    func toggle() {
        switch theme {
        case .light:
            set(.dark)
        case .dark:
            set(.light)
        case .system:
            set(ThemeController.systemIsDark ? .light : .dark)
        }
    }

    func set(_ newTheme: AppTheme) {
        guard newTheme != theme else {
            applyAppearance()
            return
        }
        theme = newTheme
        UserDefaults.standard.set(newTheme.rawValue, forKey: ThemeController.storageKey)
        applyAppearance()
    }

    /// 施加外观。已打开的窗口必须逐个设置，否则标题栏不会立即重绘。
    /// 首次启动与新建窗口时也需要调用一次，保证立即生效。
    func applyAppearance() {
        let appearance = theme.nsAppearance
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }

    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    var toolbarIcon: String {
        switch theme {
        case .light: return "moon"
        case .dark:  return "sun.max"
        case .system: return ThemeController.systemIsDark ? "sun.max" : "moon"
        }
    }

    var toolbarHelp: String {
        switch theme {
        case .light: return "当前浅色主题，点击切换到深色"
        case .dark:  return "当前深色主题，点击切换到浅色"
        case .system: return "当前跟随系统，点击切换到相反主题"
        }
    }
}

/// 工具栏右上角的主题切换按钮。
struct ThemeToggleButton: View {
    @ObservedObject private var theme = ThemeController.shared

    var body: some View {
        Button {
            theme.toggle()
        } label: {
            Image(systemName: theme.toolbarIcon)
                .font(.system(size: 13, weight: .medium))
        }
        .help(theme.toolbarHelp)
        .accessibilityLabel("切换主题")
    }
}
