import SwiftUI
import AppKit

/// 菜单栏常驻面板。关闭主窗口后仍可通过这里的图标操作服务。
struct MenuBarPanel: View {
    @ObservedObject var model: ServerViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            primaryAction
            divider
            metrics
            divider
            addresses
            divider
            footerActions
        }
        .frame(width: 336)
    }

    private var divider: some View { Divider() }

    // MARK: - 状态

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(state: model.state, size: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.state.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusDetail: String {
        switch model.state {
        case .running:
            return "端口 \(model.config.port) · 已运行 \(model.server.uptimeText)"
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

    // MARK: - 启停

    private var primaryAction: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleServer()
            } label: {
                Label(model.server.isRunning ? "停止服务" : "启动服务",
                      systemImage: model.server.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.server.isRunning ? Color.red : Color.accentColor)
            .controlSize(.large)
            .disabled(model.state.isBusy)

            if model.state.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - 指标

    private var metrics: some View {
        VStack(spacing: 5) {
            metricRow("当前连接", value: "\(model.stats.activeSessions) / \(model.config.maxConnections)")
            metricRow("累计会话", value: "\(model.stats.totalSessions)")
            metricRow("已上传", value: model.stats.uploadTotalText, extra: ByteFormat.rate(model.stats.uploadRate))
            metricRow("已下载", value: model.stats.downloadTotalText, extra: ByteFormat.rate(model.stats.downloadRate))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func metricRow(_ title: String, value: String, extra: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let extra = extra {
                Text(extra)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    // MARK: - 接入地址

    private var addresses: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("接入地址")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 1)

            ForEach(model.connectionAddresses.prefix(4), id: \.url) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .leading)
                    Text(item.url)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        model.copyToPasteboard(item.url)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("复制该地址")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 底部操作

    private var footerActions: some View {
        VStack(spacing: 2) {
            menuButton("打开主窗口", icon: "macwindow") {
                restoreMainWindow()
            }
            menuButton("在访达中打开共享目录", icon: "folder") {
                let path = (model.config.defaultRootPath as NSString).expandingTildeInPath
                NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            }
            menuButton("复制当前日志摘要", icon: "doc.text") {
                model.copyToPasteboard(model.recentLogDigest)
            }
            Divider().padding(.vertical, 3)
            menuButton("退出 FTP Server", icon: "power") {
                model.stopServer()
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func menuButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    /// 从菜单栏恢复主窗口：必须先切回常规前台应用，否则窗口不会出现在 Dock 也拿不到焦点。
    private func restoreMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: AppWindow.main)
    }
}
