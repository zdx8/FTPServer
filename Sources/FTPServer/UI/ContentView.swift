import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = ServerViewModel.shared
    @ObservedObject private var theme = ThemeController.shared
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 198, ideal: 214, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Bencho.bg)
        }
        // 会话表固定列合计 776pt，窗口再窄就会挤压数据行并与表头错位；
        // 用内容最小尺寸兜住，而不是让表格在窄窗下变形。
        .frame(minWidth: 1000, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ThemeToggleButton()
            }
        }
        // 顶栏与内容区同色：去掉工具栏材质，窗口底色由 WindowChromeConfigurator 接管
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(WindowChromeConfigurator())
        // 放右下角：右上角是启停开关与主按钮的位置，弹在那里会挡住操作
        .overlay(alignment: .bottomTrailing) {
            ToastStackView()
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

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "运行")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                ForEach([SidebarItem.dashboard, .sessions, .logs]) { item in
                    SidebarRow(item: item, selected: selection == item) {
                        withAnimation(Bencho.settle) { selection = item }
                    }
                }
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "配置")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                ForEach([SidebarItem.accounts, .settings]) { item in
                    SidebarRow(item: item, selected: selection == item) {
                        withAnimation(Bencho.settle) { selection = item }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 18)

            Spacer(minLength: 12)

            sidebarFooter
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Bencho.bg)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Bencho.fillOn)
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Bencho.onInk)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("FTP Server")
                    .font(.benchoLabel)
                    .tracking(-0.1)
                    .foregroundStyle(Bencho.ink)
                Text("原生 macOS 服务端")
                    .font(.system(size: 10))
                    .foregroundStyle(Bencho.ink4)
            }
            Spacer(minLength: 0)
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(state: model.state, size: 6)
                Text(model.state.label)
                    .font(.benchoMicro)
                    .foregroundStyle(Bencho.ink2)
                Spacer(minLength: 0)
                Text(":\(String(model.config.port))")
                    .font(.benchoMonoSmall)
                    .foregroundStyle(Bencho.ink4)
            }

            Hairline()

            HStack(spacing: 6) {
                Text("\(model.sessions.count) 个连接")
                    .font(.system(size: 10))
                    .foregroundStyle(Bencho.ink4)
                Spacer(minLength: 0)
                Text(model.stats.uploadTotalText + " ↑")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Bencho.ink5)
            }
        }
        .padding(10)
        .benchoInset(corner: 12)
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }
}

/// 侧边栏的一行。选中态是「反色胶囊」，与 bencho 的 fill-on / on-ink 反色规则一致。
private struct SidebarRow: View {
    let item: SidebarItem
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            Text(item.title)
                .font(.benchoLabel)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Bencho.onInk : (hovering ? Bencho.ink : Bencho.ink2))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            Capsule().fill(selected ? Bencho.fillOn : (hovering ? Bencho.inset : Color.clear))
        )
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .animation(Bencho.fade, value: hovering)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
