import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = ServerViewModel.shared
    @ObservedObject private var theme = ThemeController.shared
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("运行") {
                    ForEach([SidebarItem.dashboard, .sessions, .logs]) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                Section("配置") {
                    ForEach([SidebarItem.accounts, .settings]) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 250)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ThemeToggleButton()
            }
        }
        // SwiftUI 绘制部分的外观；原生部件由 ThemeController.applyAppearance() 设置
        .preferredColorScheme(theme.theme.colorScheme)
        .onAppear { theme.applyAppearance() }
        .alert("提示", isPresented: alertBinding) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .dashboard {
        case .dashboard: DashboardView(model: model)
        case .sessions:  SessionsView(model: model)
        case .logs:      LogsView(model: model)
        case .accounts:  AccountsView(model: model)
        case .settings:  SettingsView(model: model)
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 7) {
                StatusDot(state: model.state, size: 8)
                Text(model.state.label)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                Text(":\(String(model.config.port))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }
}
