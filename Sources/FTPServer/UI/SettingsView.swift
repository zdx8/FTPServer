import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ServerViewModel
    @ObservedObject private var theme = ThemeController.shared
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ServerControlBar(model: model)
                listeningCard
                limitsCard
                passiveCard
                rootCard
                appearanceCard
                behaviorCard
                logCard
                configCard
            }
            .padding(20)
        }
        .navigationTitle("设置")
        .alert("恢复默认设置", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) { }
            Button("恢复默认", role: .destructive) {
                model.stopServer()
                model.resetConfig()
            }
        } message: {
            Text("将清除端口、目录、账号等全部配置并恢复出厂默认值，此操作不可撤销。")
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ServerConfig, T>) -> Binding<T> {
        Binding(
            get: { model.config[keyPath: keyPath] },
            set: { newValue in
                model.config[keyPath: keyPath] = newValue
                model.saveConfig()
            }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { Int(model.config.port) },
            set: { newValue in
                model.config.port = UInt16(max(1, min(65535, newValue)))
                model.saveConfig()
            }
        )
    }

    // MARK: - 卡片

    private var listeningCard: some View {
        CardContainer(title: "监听", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "监听端口",
                           detail: "1024 以上端口无需管理员权限；21 端口需要 root") {
                    TextField("", value: portBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 84)
                }

                Divider()

                SettingRow(title: "绑定范围",
                           detail: model.config.bindAllInterfaces
                               ? "0.0.0.0 — 局域网内其他设备可访问"
                               : "127.0.0.1 — 仅本机可访问") {
                    Picker("", selection: binding(\.bindAllInterfaces)) {
                        Text("全部网卡").tag(true)
                        Text("仅本机").tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 118)
                }

                Divider()

                SettingRow(title: "启动应用后自动开始监听",
                           detail: "适合把本应用当作常驻服务使用") {
                    Toggle("", isOn: binding(\.autoStart)).labelsHidden()
                }

                if model.state.isRunning {
                    Divider()
                    HStack(spacing: 10) {
                        Text("修改监听配置需要重启服务后生效")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重启服务") { restart() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var limitsCard: some View {
        CardContainer(title: "限制与超时", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "最大并发连接数", detail: "\(model.config.maxConnections) 个") {
                    Stepper("", value: binding(\.maxConnections), in: 1...512)
                        .labelsHidden()
                        .frame(width: 96)
                }

                Divider()

                SettingRow(title: "空闲超时",
                           detail: "\(Int(model.config.idleTimeout)) 秒无任何活动则断开连接") {
                    Stepper("", value: binding(\.idleTimeout), in: 30...7200, step: 30)
                        .labelsHidden()
                        .frame(width: 96)
                }

                Divider()

                SettingRow(title: "数据连接超时",
                           detail: "\(Int(model.config.dataTimeout)) 秒内无数据流动则中止本次传输") {
                    Stepper("", value: binding(\.dataTimeout), in: 5...600, step: 5)
                        .labelsHidden()
                        .frame(width: 96)
                }
            }
        }
    }

    private var passiveCard: some View {
        CardContainer(title: "被动模式（PASV）", systemImage: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "对外通告地址",
                           detail: model.config.pasvAdvertiseHost.isEmpty
                               ? "自动检测：优先使用控制连接的本地地址"
                               : model.config.pasvAdvertiseHost) {
                    TextField("自动", text: binding(\.pasvAdvertiseHost))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 148)
                }

                Text("客户端在被动模式下会用服务器返回的地址发起数据连接。若服务器位于 NAT 后方或存在多张网卡导致自动检测出错，请在此填写客户端实际可访问的 IPv4 地址。留空表示自动检测。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rootCard: some View {
        CardContainer(title: "默认共享目录", systemImage: "folder") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "默认根目录", detail: model.config.defaultRootPath) {
                    Button("选择…") {
                        DirectoryPicker.choose(title: "选择默认共享目录",
                                               current: model.config.defaultRootPath) { path in
                            guard let path = path else { return }
                            model.config.defaultRootPath = path
                            model.saveConfig()
                        }
                    }
                }
                Text("服务启动时会自动创建不存在的共享目录。各账号可在「用户账号」中单独指定自己的根目录。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceCard: some View {
        CardContainer(title: "外观", systemImage: "circle.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "界面主题",
                           detail: "工具栏右上角的按钮可快速在浅色与深色之间切换") {
                    Picker("", selection: themeBinding) {
                        ForEach(AppTheme.allCases) { item in
                            Label(item.label, systemImage: item.icon).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 138)
                }

                Divider()

                SettingRow(title: "主题随系统外观自动切换",
                           detail: "选择「跟随系统」后，系统切换深色时本应用会同步切换") {
                    Text(theme.theme == .system ? "已启用" : "未启用")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.theme == .system ? Color.accentColor : Color.secondary)
                }
            }
        }
    }

    private var behaviorCard: some View {
        CardContainer(title: "窗口与退出", systemImage: "macwindow") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "关闭主窗口时",
                           detail: model.config.closeBehavior.detail) {
                    Picker("", selection: binding(\.closeBehavior)) {
                        ForEach(CloseBehavior.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 158)
                }

                Divider()

                SettingRow(title: "菜单栏常驻图标",
                           detail: "常驻系统菜单栏，可随时启停服务、复制接入地址、恢复主窗口或退出") {
                    Text("已启用")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if model.config.closeBehavior == .minimizeToMenuBar {
                    Divider()
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                        Text("关闭窗口后应用将从 Dock 隐藏，仅保留菜单栏图标，FTP 服务继续运行。点击菜单栏图标选择「打开主窗口」即可恢复。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { theme.theme },
            set: { theme.set($0) }
        )
    }

    private var logCard: some View {
        CardContainer(title: "日志", systemImage: "text.alignleft") {
            SettingRow(title: "记录级别",
                       detail: "调试级别会记录每一条客户端命令，便于排查兼容性问题") {
                Picker("", selection: binding(\.logLevel)) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
        }
    }

    private var configCard: some View {
        CardContainer(title: "配置文件", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.configURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Button("在访达中显示") { model.revealConfigInFinder() }
                    Button("重新载入") {
                        model.stopServer()
                        let reloaded = ServerViewModel.loadConfig(from: model.configURL)
                        model.config = reloaded
                        model.saveConfig()
                    }
                    Spacer()
                    Button("恢复默认设置") { showResetConfirm = true }
                }
                .controlSize(.small)
            }
        }
    }

    private func restart() {
        model.stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            model.startServer()
        }
    }
}
