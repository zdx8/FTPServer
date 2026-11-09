import SwiftUI
import AppKit

struct LogsView: View {
    @ObservedObject var model: ServerViewModel
    @State private var minimumLevel: LogLevel = .debug
    @State private var searchText = ""
    @State private var autoScroll = true

    private var filtered: [FTPLogEntry] {
        model.logEntries.filter { entry in
            guard entry.level.rank >= minimumLevel.rank else { return false }
            guard !searchText.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText)
                || entry.session.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            logList
                .padding(.horizontal, Bencho.Space.page)
                .padding(.bottom, Bencho.Space.page)
        }
        .background(Bencho.bg)
        .navigationTitle("运行日志")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            BenchoSegmented(items: LogLevel.allCases,
                            title: { $0.label },
                            selection: $minimumLevel)

            BenchoSearchField(placeholder: "搜索关键字", text: $searchText)
                .frame(width: 210)

            HStack(spacing: 7) {
                LiquidSwitch(isOn: autoScroll,
                             trackWidth: 34,
                             trackHeight: 20,
                             label: "自动滚动") {
                    autoScroll.toggle()
                }
                Text("自动滚动")
                    .font(.benchoMicro)
                    .foregroundStyle(Bencho.ink3)
            }

            Spacer()

            Text("\(filtered.count) / \(model.logEntries.count) 条")
                .font(.benchoMicro)
                .foregroundStyle(Bencho.ink4)

            Button {
                let text = filtered
                    .map { "[\(TimeText.clock($0.timestamp))] [\($0.level.label)] [\($0.session)] \($0.message)" }
                    .joined(separator: "\n")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                ToastCenter.shared.show(.success, "已复制 \(filtered.count) 条日志")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(BenchoButtonStyle(kind: .ghost, compact: true))
            .disabled(filtered.isEmpty)

            Button("清空") {
                model.clearLogs()
                ToastCenter.shared.show(.info, "日志已清空")
            }
            .buttonStyle(BenchoButtonStyle(kind: .ghost, compact: true))
            .disabled(model.logEntries.isEmpty)
        }
        .padding(.horizontal, Bencho.Space.page)
        .padding(.vertical, 12)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .benchoInset(corner: Bencho.Radius.card)
            .onChange(of: filtered.count) { _, _ in
                guard autoScroll, let last = filtered.last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func row(_ entry: FTPLogEntry) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(TimeText.clock(entry.timestamp))
                .font(.benchoMonoSmall)
                .foregroundStyle(Bencho.ink5)
                .frame(width: 58, alignment: .leading)

            LevelChip(level: entry.level)
                .frame(width: 40, alignment: .leading)

            Text(entry.session)
                .font(.benchoMonoSmall)
                .foregroundStyle(Bencho.ink5)
                .frame(width: 30, alignment: .leading)

            Text(entry.message)
                .font(.benchoMonoSmall)
                .foregroundStyle(entry.level == .error ? Bencho.danger : (entry.level == .warning ? Bencho.ink2 : Bencho.ink3))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}
