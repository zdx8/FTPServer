import SwiftUI
import Charts

struct DashboardView: View {
    @ObservedObject var model: ServerViewModel

    private let statColumns = [GridItem(.adaptive(minimum: 158), spacing: Bencho.Space.stack)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Bencho.Space.stack) {
                ServerControlBar(model: model)
                statGrid
                throughputCard
                addressCard
                clientHintCard
            }
            .padding(Bencho.Space.page)
        }
        .scrollContentBackground(.hidden)
        .background(Bencho.bg)
        .navigationTitle("概览")
    }

    // MARK: - 统计卡片

    private var statGrid: some View {
        LazyVGrid(columns: statColumns, spacing: Bencho.Space.stack) {
            StatCard(title: "当前连接",
                     value: "\(model.stats.activeSessions)",
                     caption: "上限 \(model.config.maxConnections)",
                     systemImage: "person.2",
                     tint: Bencho.pick)

            StatCard(title: "累计会话",
                     value: "\(model.stats.totalSessions)",
                     caption: model.stats.startedAt == nil ? "本次未运行" : "自本次启动",
                     systemImage: "arrow.triangle.2.circlepath",
                     tint: Bencho.ink4)

            StatCard(title: "已上传",
                     value: model.stats.uploadTotalText,
                     caption: "客户端 → 服务器 · \(ByteFormat.rate(model.stats.uploadRate))",
                     systemImage: "arrow.down.circle",
                     tint: Bencho.ok)

            StatCard(title: "已下载",
                     value: model.stats.downloadTotalText,
                     caption: "服务器 → 客户端 · \(ByteFormat.rate(model.stats.downloadRate))",
                     systemImage: "arrow.up.circle",
                     tint: Bencho.ember)
        }
    }

    // MARK: - 速率图表

    private var throughputCard: some View {
        CardContainer(title: "传输速率",
                      subtitle: "最近 150 秒",
                      systemImage: "chart.xyaxis.line") {
            if model.rateHistory.isEmpty {
                EmptyHint(icon: "chart.xyaxis.line",
                          title: "暂无采样数据",
                          message: "服务启动后开始每秒采集一次传输速率。")
                    .frame(height: 156)
            } else {
                chart

                if model.stats.uploadRate + model.stats.downloadRate > 0 {
                    TrafficBar(upload: model.stats.uploadRate, download: model.stats.downloadRate)
                        .padding(.top, 2)
                }

                HStack(spacing: 16) {
                    legend(color: Bencho.pick, text: "下载 \(ByteFormat.rate(model.stats.downloadRate))")
                    legend(color: Bencho.ember, text: "上传 \(ByteFormat.rate(model.stats.uploadRate))")
                    Spacer()
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.rateHistory) { sample in
                AreaMark(
                    x: .value("时间", sample.time),
                    y: .value("下载", sample.download)
                )
                .foregroundStyle(Bencho.pick.opacity(0.10))
                .interpolationMethod(.catmullRom)
            }
            ForEach(model.rateHistory) { sample in
                LineMark(
                    x: .value("时间", sample.time),
                    y: .value("下载", sample.download)
                )
                .foregroundStyle(Bencho.pick)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(model.rateHistory) { sample in
                LineMark(
                    x: .value("时间", sample.time),
                    y: .value("上传", sample.upload)
                )
                .foregroundStyle(Bencho.ember)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [3, 3]))
            }
        }
        .chartYScale(domain: 0...chartUpperBound)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Bencho.edge)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(ByteFormat.rate(raw))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Bencho.ink5)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Bencho.edge)
                AxisValueLabel(format: .dateTime.minute().second())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Bencho.ink5)
            }
        }
        .frame(height: 156)
    }

    private var chartUpperBound: Double {
        let peak = model.rateHistory.map { max($0.upload, $0.download) }.max() ?? 0
        return max(1024, peak * 1.25)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 12, height: 3)
            Text(text)
                .font(.benchoMicro)
                .foregroundStyle(Bencho.ink3)
        }
    }

    // MARK: - 接入地址

    private var addressCard: some View {
        CardContainer(title: "接入地址",
                      subtitle: model.state.isRunning ? "服务运行中" : "启动服务后生效",
                      systemImage: "link") {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(model.connectionAddresses, id: \.url) { item in
                    AddressRow(name: item.name, url: item.url, model: model)
                }
                if !model.config.pasvAdvertiseHost.trimmingCharacters(in: .whitespaces).isEmpty {
                    Hairline().padding(.vertical, 7)
                    Text("被动模式对外通告地址：\(model.config.pasvAdvertiseHost)")
                        .font(.benchoMicro)
                        .foregroundStyle(Bencho.ink4)
                }
            }
        }
    }

    // MARK: - 客户端提示

    private var clientHintCard: some View {
        CardContainer(title: "如何连接", systemImage: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Bencho.warn)
                    Text("macOS 自 10.13 起已从访达（Finder）中移除 FTP 支持，因此无法在访达「连接服务器」中使用 ftp:// 地址。请改用下列任一方式。")
                        .font(.benchoCaption)
                        .foregroundStyle(Bencho.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Bencho.Radius.inner, style: .continuous)
                        .fill(Bencho.warn.opacity(0.07))
                )

                hint(title: "图形客户端", detail: "Cyberduck、FileZilla、Transmit 等均支持明文 FTP，填入上方地址即可。")
                hint(title: "curl 列出目录", detail: "curl ftp://\(model.displayHost):\(model.config.port)/")
                hint(title: "curl 下载", detail: "curl -O ftp://\(model.displayHost):\(model.config.port)/文件名")
                hint(title: "系统 ftp", detail: "ftp \(model.displayHost) \(model.config.port)")
            }
        }
    }

    private func hint(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.benchoMicro)
                .foregroundStyle(Bencho.ink4)
                .frame(width: 88, alignment: .leading)
            Text(detail)
                .font(.benchoMonoSmall)
                .foregroundStyle(Bencho.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// bencho 的 `stacked-bars` 语言：一根轨道按比例分成两段，代替两个独立进度条。
private struct TrafficBar: View {
    let upload: Double
    let download: Double

    private var total: Double { upload + download }
    private var share: Double {
        guard total > 0 else { return 0 }
        return download / total
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let gap: CGFloat = 3
            let pickWidth = max(0, width * share - gap / 2)
            let emberWidth = max(0, width - pickWidth - gap)
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Bencho.pick)
                    .frame(width: pickWidth)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Bencho.ember)
                    .frame(width: emberWidth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Bencho.inset)
            )
        }
        .frame(height: 4)
        .animation(Bencho.settle, value: share)
    }
}
