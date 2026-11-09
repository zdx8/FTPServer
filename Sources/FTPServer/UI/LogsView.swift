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
            Divider()
            logList
        }
        .navigationTitle("运行日志")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("级别", selection: $minimumLevel) {
                ForEach(LogLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 92)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索关键字", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .frame(maxWidth: 260)

            Toggle("自动滚动", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Spacer()

            Text("\(filtered.count) / \(model.logEntries.count) 条")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                let text = filtered
                    .map { "[\(TimeText.clock($0.timestamp))] [\($0.level.label)] [\($0.session)] \($0.message)" }
                    .joined(separator: "\n")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.link)
            .disabled(filtered.isEmpty)

            Button("清空") { model.clearLogs() }
                .buttonStyle(.link)
                .disabled(model.logEntries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
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
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            LevelChip(level: entry.level)
                .frame(width: 38, alignment: .leading)

            Text(entry.session)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.level == .error ? Color.red : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}
