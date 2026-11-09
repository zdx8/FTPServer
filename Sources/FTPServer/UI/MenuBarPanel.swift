import SwiftUI
import AppKit

/// 菜单栏常驻面板。关闭主窗口后仍可通过这里的图标操作服务。
struct MenuBarPanel: View {
    @ObservedObject var model: ServerViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            primaryAction
            Hairline()
            metrics
            Hairline()
            addresses
            Hairline()
            footerActions
        }
        .frame(width: 336)
        .background(Bencho.bg)
    }

    // MARK: - 状态

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(state: model.state, size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.label)
                    .font(.benchoLabel)
                    .foregroundStyle(Bencho.ink)
                Text(statusDetail)
                    .font(.benchoMonoSmall)
                    .foregroundStyle(Bencho.ink4)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        HStack(spacing: 10) {
            LiquidSwitch(isOn: model.server.isRunning,
                         isEnabled: !model.state.isBusy,
                         trackWidth: 44,
                         trackHeight: 25) {
                model.toggleServer()
            }

            Button {
                model.toggleServer()
            } label: {
                // 撑宽必须写在 label 上：写在 Button 外层时胶囊背景仍按文字宽度绘制，
                // 会变成一枚悬在行中间的小胶囊。
                Text(model.server.isRunning ? "停止服务" : "启动服务")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BenchoButtonStyle(kind: .primary))
            .disabled(model.state.isBusy)

            if model.state.isBusy {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - 指标

    private var metrics: some View {
        VStack(spacing: 6) {
            metricRow("当前连接", value: "\(model.stats.activeSessions) / \(model.config.maxConnections)")
            metricRow("累计会话", value: "\(model.stats.totalSessions)")
            metricRow("已上传", value: model.stats.uploadTotalText, extra: ByteFormat.rate(model.stats.uploadRate))
            metricRow("已下载", value: model.stats.downloadTotalText, extra: ByteFormat.rate(model.stats.downloadRate))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func metricRow(_ title: String, value: String, extra: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.benchoMicro)
                .foregroundStyle(Bencho.ink4)
            Spacer(minLength: 6)
            if let extra = extra {
                Text(extra)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Bencho.ink5)
            }
            Text(value)
                .font(.benchoMono)
                .monospacedDigit()
                .foregroundStyle(Bencho.ink)
        }
    }

    // MARK: - 接入地址

    private var addresses: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "接入地址")
                .padding(.bottom, 2)

            ForEach(model.connectionAddresses.prefix(4), id: \.url) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 10))
                        .foregroundStyle(Bencho.ink5)
                        .frame(width: 44, alignment: .leading)
                    Text(item.url)
                        .font(.benchoMonoSmall)
                        .foregroundStyle(Bencho.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        model.copyToPasteboard(item.url)
                        ToastCenter.shared.show(.success, "已复制接入地址", detail: item.url)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Bencho.ink4)
                    .help("复制该地址")
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - 底部操作

    private var footerActions: some View {
        VStack(spacing: 1) {
            menuButton("打开主窗口", icon: "macwindow") {
                restoreMainWindow()
            }
            menuButton("在访达中打开共享目录", icon: "folder") {
                let path = (model.config.defaultRootPath as NSString).expandingTildeInPath
                NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            }
            menuButton("复制当前日志摘要", icon: "doc.text") {
                model.copyToPasteboard(model.recentLogDigest)
                ToastCenter.shared.show(.success, "日志摘要已复制")
            }
            Hairline().padding(.vertical, 4)
            menuButton("退出 FTP Server", icon: "power", danger: true) {
                model.stopServer()
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func menuButton(_ title: String,
                            icon: String,
                            danger: Bool = false,
                            action: @escaping () -> Void) -> some View {
        MenuRow(title: title, icon: icon, danger: danger, action: action)
    }

    /// 从菜单栏恢复主窗口：必须先切回常规前台应用，否则窗口不会出现在 Dock 也拿不到焦点。
    private func restoreMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: AppWindow.main)
    }
}

private struct MenuRow: View {
    let title: String
    let icon: String
    var danger: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                Text(title)
                    .font(.benchoCaption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(danger ? Bencho.danger : (hovering ? Bencho.ink : Bencho.ink2))
            .contentShape(Rectangle())
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Bencho.inset : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Bencho.fade, value: hovering)
    }
}
