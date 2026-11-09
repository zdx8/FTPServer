import SwiftUI

// MARK: - 状态指示

struct StatusDot: View {
    let state: FTPServerState
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: size * 2.4, height: size * 2.4)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }

    private var color: Color {
        switch state {
        case .running:              return Color(red: 0.13, green: 0.63, blue: 0.35)
        case .starting, .stopping:  return Color.orange
        case .failed:               return Color.red
        case .stopped:              return Color.secondary
        }
    }
}

struct LevelChip: View {
    let level: LogLevel

    var body: some View {
        Text(level.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch level {
        case .debug:   return Color.secondary
        case .info:    return Color.accentColor
        case .warning: return Color.orange
        case .error:   return Color.red
        }
    }
}

// MARK: - 容器

struct CardContainer<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle = subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var caption: String? = nil
    var systemImage: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if let caption = caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - 顶部控制条

struct ServerControlBar: View {
    @ObservedObject var model: ServerViewModel

    var body: some View {
        HStack(spacing: 13) {
            StatusDot(state: model.state)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.label)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if model.state.isBusy {
                ProgressView().controlSize(.small)
            }

            Button {
                model.toggleServer()
            } label: {
                Text(model.server.isRunning ? "停止服务" : "启动服务")
                    .frame(minWidth: 74)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.server.isRunning ? Color.red : Color.accentColor)
            .disabled(model.state.isBusy)
            .keyboardShortcut("r", modifiers: [.command])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var subtitle: String {
        switch model.state {
        case .running:
            return "监听端口 \(model.config.port) · 已运行 \(model.server.uptimeText)"
        case .stopped:
            return "端口 \(model.config.port) · 未在监听"
        case .starting:
            return "正在绑定端口 \(model.config.port)…"
        case .stopping:
            return "正在关闭连接…"
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - 地址行

struct AddressRow: View {
    let name: String
    let url: String
    @ObservedObject var model: ServerViewModel
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            Text(url)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)

            Spacer(minLength: 6)

            Button {
                model.copyToPasteboard(url)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 空状态

struct EmptyHint: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - 目录选择

enum DirectoryPicker {
    static func choose(title: String, current: String, completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK {
            completion(panel.url?.path)
        } else {
            completion(nil)
        }
    }
}
