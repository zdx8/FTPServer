import SwiftUI
import Charts

struct DashboardView: View {
    @ObservedObject var model: ServerViewModel

    private let statColumns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ServerControlBar(model: model)
                statGrid
                throughputCard
                addressCard
                clientHintCard
            }
            .padding(20)
        }
        .navigationTitle("概览")
    }

    // MARK: - 统计卡片

    private var statGrid: some View {
        LazyVGrid(columns: statColumns, spacing: 12) {
            StatCard(title: "当前连接",
                     value: "\(model.stats.activeSessions)",
                     caption: "上限 \(model.config.maxConnections)",
                     systemImage: "person.2",
                     tint: .accentColor)

            StatCard(title: "累计会话",
                     value: "\(model.stats.totalSessions)",
                     caption: model.stats.startedAt == nil ? "本次未运行" : "自本次启动",
                     systemImage: "arrow.triangle.2.circlepath",
                     tint: .accentColor)

            StatCard(title: "已上传（客户端→服务器）",
                     value: model.stats.uploadTotalText,
                     caption: ByteFormat.rate(model.stats.uploadRate),
                     systemImage: "arrow.down.circle",
                     tint: Color(red: 0.13, green: 0.63, blue: 0.35))

            StatCard(title: "已下载（服务器→客户端）",
                     value: model.stats.downloadTotalText,
                     caption: ByteFormat.rate(model.stats.downloadRate),
                     systemImage: "arrow.up.circle",
                     tint: .orange)
        }
    }

    // MARK: - 速率图表

    private var throughputCard: some View {
        CardContainer(title: "传输速率", subtitle: "最近 150 秒", systemImage: "chart.xyaxis.line") {
            if model.rateHistory.isEmpty {
                EmptyHint(icon: "chart.xyaxis.line",
                          title: "暂无采样数据",
                          message: "服务启动后开始每秒采集一次传输速率。")
                    .frame(height: 150)
            } else {
                Chart {
                    ForEach(model.rateHistory) { sample in
                        AreaMark(
                            x: .value("时间", sample.time),
                            y: .value("下载", sample.download)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("时间", sample.time),
                            y: .value("下载", sample.download)
                        )
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                    ForEach(model.rateHistory) { sample in
                        LineMark(
                            x: .value("时间", sample.time),
                            y: .value("上传", sample.upload)
                        )
                        .foregroundStyle(Color.orange)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: 0...chartUpperBound)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text(ByteFormat.rate(raw)).font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.minute().second())
                            .font(.system(size: 9))
                    }
                }
                .frame(height: 150)

                HStack(spacing: 16) {
                    legend(color: .accentColor, text: "下载  \(ByteFormat.rate(model.stats.downloadRate))")
                    legend(color: .orange, text: "上传  \(ByteFormat.rate(model.stats.uploadRate))")
                    Spacer()
                }
            }
        }
    }

    private var chartUpperBound: Double {
        let peak = model.rateHistory.map { max($0.upload, $0.download) }.max() ?? 0
        return max(1024, peak * 1.25)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 10, height: 3)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 接入地址

    private var addressCard: some View {
        CardContainer(title: "接入地址",
                      subtitle: model.state.isRunning ? "服务运行中，可用下列地址连接" : "启动服务后生效",
                      systemImage: "link") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.connectionAddresses, id: \.url) { item in
                    AddressRow(name: item.name, url: item.url, model: model)
                }
                if !model.config.pasvAdvertiseHost.trimmingCharacters(in: .whitespaces).isEmpty {
                    Divider().padding(.vertical, 5)
                    Text("被动模式对外通告地址：\(model.config.pasvAdvertiseHost)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 客户端提示

    private var clientHintCard: some View {
        CardContainer(title: "如何连接", systemImage: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("macOS 自 10.13 起已从访达（Finder）中移除 FTP 支持，因此无法在访达「连接服务器」中使用 ftp:// 地址。请改用下列任一方式。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                hint(title: "图形客户端", detail: "Cyberduck、FileZilla、Transmit 等均支持明文 FTP，填入上方地址即可。")
                hint(title: "命令行 curl", detail: "curl ftp://\(model.displayHost):\(model.config.port)/  —  列出目录")
                hint(title: "命令行 curl 下载", detail: "curl -O ftp://\(model.displayHost):\(model.config.port)/文件名")
                hint(title: "命令行 ftp", detail: "ftp \(model.displayHost) \(model.config.port)  —  使用系统自带客户端（如存在）")
            }
        }
    }

    private func hint(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 96, alignment: .leading)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
