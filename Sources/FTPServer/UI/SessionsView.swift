import SwiftUI

enum TimeText {
    /// 仅在主线程（视图渲染）中使用的共享格式化器。
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    static func duration(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// 会话列表的列宽定义。集中在一处，保证表头与数据行严格对齐。
private enum SessionColumn {
    static let client: CGFloat = 166
    static let user: CGFloat = 100
    static let status: CGFloat = 132
    static let uploaded: CGFloat = 76
    static let downloaded: CGFloat = 76
    static let duration: CGFloat = 72
    static let command: CGFloat = 88
    static let action: CGFloat = 52
    static let directoryMinimum: CGFloat = 120
}

struct SessionsView: View {
    @ObservedObject var model: ServerViewModel
    @State private var selection: Set<FTPSessionSnapshot.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            ServerControlBar(model: model)
                .padding(16)

            if model.sessions.isEmpty {
                EmptyHint(icon: "person.2.slash",
                          title: "当前没有连接",
                          message: model.state.isRunning
                              ? "服务已在端口 \(model.config.port) 监听，等待客户端接入。"
                              : "服务未运行，请先点击「启动服务」。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .navigationTitle("活动会话")
        .onChange(of: model.sessions.map { $0.id }) { _, newValue in
            selection = selection.intersection(Set(newValue))
        }
    }

    // MARK: - 列表

    /// 用 ScrollView + 固定列宽实现，而非 Table。
    /// Table 放在 VStack 里若不给显式尺寸会塌缩为零高度——数据已到但行不显示。
    private var sessionList: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sessions) { session in
                        sessionRow(session)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            headerCell("客户端", width: SessionColumn.client)
            headerCell("用户", width: SessionColumn.user)
            headerCell("当前目录", flexible: true)
            headerCell("状态", width: SessionColumn.status)
            headerCell("已上传", width: SessionColumn.uploaded, alignment: .trailing)
            headerCell("已下载", width: SessionColumn.downloaded, alignment: .trailing)
            headerCell("时长", width: SessionColumn.duration, alignment: .trailing)
            headerCell("最后命令", width: SessionColumn.command)
            headerCell("", width: SessionColumn.action)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
    }

    private func headerCell(_ title: String,
                            width: CGFloat? = nil,
                            flexible: Bool = false,
                            alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            // frame 没有同时接受 width 与 maxWidth 的重载，拆成两次调用
            .frame(width: flexible ? nil : width, alignment: alignment)
            .frame(maxWidth: flexible ? .infinity : nil, alignment: alignment)
    }

    private func sessionRow(_ session: FTPSessionSnapshot) -> some View {
        let isSelected = selection.contains(session.id)
        return HStack(spacing: 8) {
            Text(session.remoteAddress)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .frame(width: SessionColumn.client, alignment: .leading)

            Text(session.username)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: SessionColumn.user, alignment: .leading)

            Text(session.currentDirectory)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            statusCell(session)
                .frame(width: SessionColumn.status, alignment: .leading)

            Text(ByteFormat.text(session.bytesIn))
                .font(.system(size: 11))
                .monospacedDigit()
                .frame(width: SessionColumn.uploaded, alignment: .trailing)

            Text(ByteFormat.text(session.bytesOut))
                .font(.system(size: 11))
                .monospacedDigit()
                .frame(width: SessionColumn.downloaded, alignment: .trailing)

            Text(TimeText.duration(since: session.connectedAt))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: SessionColumn.duration, alignment: .trailing)

            Text(session.lastCommand)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: SessionColumn.command, alignment: .leading)

            Button("断开") { model.disconnect(session) }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .frame(width: SessionColumn.action, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selection.remove(session.id) } else { selection.insert(session.id) }
        }
        .contextMenu {
            Button("断开该连接") { model.disconnect(session) }
        }
    }

    @ViewBuilder
    private func statusCell(_ session: FTPSessionSnapshot) -> some View {
        if session.isTransferring {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(session.transferSummary.isEmpty ? "传输中" : session.transferSummary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            Text("空闲").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 底部汇总

    private var footer: some View {
        HStack(spacing: 12) {
            Text("共 \(model.sessions.count) 个连接，上限 \(model.config.maxConnections)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // 服务端计数与列表条数不一致，说明推送链路出了问题。
            // 把这种情况直接摆到界面上，避免「连接了但列表空白」无从判断。
            if model.stats.activeSessions != model.sessions.count {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("服务端报告 \(model.stats.activeSessions) 个连接，列表未同步")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.orange)
            }

            if !selection.isEmpty {
                Text("已选中 \(selection.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Button("断开所选") {
                for id in selection {
                    if let session = model.sessions.first(where: { $0.id == id }) {
                        model.disconnect(session)
                    }
                }
                selection.removeAll()
            }
            .buttonStyle(.link)
            .disabled(selection.isEmpty)

            Button("全部断开") { model.disconnectAll() }
                .buttonStyle(.link)
                .disabled(model.sessions.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
