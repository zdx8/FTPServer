import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ServerViewModel
    @ObservedObject private var theme = ThemeController.shared
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Bencho.Space.stack) {
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
            .padding(Bencho.Space.page)
        }
        .scrollContentBackground(.hidden)
        .background(Bencho.bg)
        .navigationTitle("设置")
        .alert("恢复默认设置", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) { }
            Button("恢复默认", role: .destructive) {
                model.stopServer()
                model.resetConfig()
                ToastCenter.shared.show(.warning, "已恢复默认配置")
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

    private var maxConnectionsBinding: Binding<Double> {
        Binding(
            get: { Double(model.config.maxConnections) },
            set: { model.config.maxConnections = Int($0); model.saveConfig() }
        )
    }

    private var idleTimeoutBinding: Binding<Double> {
        Binding(
            get: { model.config.idleTimeout },
            set: { model.config.idleTimeout = $0; model.saveConfig() }
        )
    }

    private var dataTimeoutBinding: Binding<Double> {
        Binding(
            get: { model.config.dataTimeout },
            set: { model.config.dataTimeout = $0; model.saveConfig() }
        )
    }

    // MARK: - 卡片

    private var listeningCard: some View {
        CardContainer(title: "监听", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 8) {
                SettingRow(title: "监听端口",
                           detail: "1024 以上端口无需管理员权限；21 端口需要 root") {
                    TextField("", value: portBinding, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .font(.benchoMono)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 9)
                        .frame(width: 84, height: 28)
                        .benchoInset(corner: Bencho.Radius.pill)
                }

                Hairline()

                SettingRow(title: "绑定范围",
                           detail: model.config.bindAllInterfaces
                               ? "0.0.0.0 — 局域网内其他设备可访问"
                               : "127.0.0.1 — 仅本机可访问") {
                    BenchoSegmented(items: [true, false],
                                    title: { $0 ? "全部网卡" : "仅本机" },
                                    selection: binding(\.bindAllInterfaces))
                }

                Hairline()

                SettingRow(title: "启动应用后自动开始监听",
                           detail: "适合把本应用当作常驻服务使用") {
                    LiquidSwitch(isOn: model.config.autoStart,
                                 trackWidth: 42, trackHeight: 24,
                                 label: "启动应用后自动开始监听") {
                        binding(\.autoStart).wrappedValue.toggle()
                    }
                }

                if model.state.isRunning {
                    Hairline()
                    HStack(spacing: 10) {
                        Text("修改监听配置需要重启服务后生效")
                            .font(.benchoMicro)
                            .foregroundStyle(Bencho.ink4)
                        Spacer()
                        Button("重启服务") { restart() }
                            .buttonStyle(BenchoButtonStyle(kind: .secondary, compact: true))
                    }
                }
            }
        }
    }

    private var limitsCard: some View {
        CardContainer(title: "限制与超时", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 8) {
                SettingRow(title: "最大并发连接数") {
                    ValueStepper(value: maxConnectionsBinding,
                                 range: 1...512,
                                 step: 1,
                                 format: { "\(Int($0))" })
                }

                Hairline()

                SettingRow(title: "空闲超时",
                           detail: "无任何活动则断开连接") {
                    ValueStepper(value: idleTimeoutBinding,
                                 range: 30...7200,
                                 step: 30,
                                 format: { "\(Int($0)) 秒" })
                }

                Hairline()

                SettingRow(title: "数据连接超时",
                           detail: "无数据流动则中止本次传输") {
                    ValueStepper(value: dataTimeoutBinding,
                                 range: 5...600,
                                 step: 5,
                                 format: { "\(Int($0)) 秒" })
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
                        .textFieldStyle(.plain)
                        .font(.benchoMono)
                        .padding(.horizontal, 10)
                        .frame(width: 156, height: 28)
                        .benchoInset(corner: Bencho.Radius.pill)
                }

                Text("客户端在被动模式下会用服务器返回的地址发起数据连接。若服务器位于 NAT 后方或存在多张网卡导致自动检测出错，请在此填写客户端实际可访问的 IPv4 地址。留空表示自动检测。")
                    .font(.benchoMicro)
                    .foregroundStyle(Bencho.ink4)
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
                    .buttonStyle(BenchoButtonStyle(kind: .secondary, compact: true))
                }
                Text("服务启动时会自动创建不存在的共享目录。各账号可在「用户账号」中单独指定自己的根目录。")
                    .font(.benchoMicro)
                    .foregroundStyle(Bencho.ink4)
            }
        }
    }

    private var appearanceCard: some View {
        CardContainer(title: "外观", systemImage: "circle.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 8) {
                SettingRow(title: "界面主题",
                           detail: "工具栏右上角的按钮可快速在浅色与深色之间切换") {
                    BenchoSegmented(items: AppTheme.allCases,
                                    title: { $0.label },
                                    selection: themeBinding)
                }

                Hairline()

                SettingRow(title: "主题随系统外观自动切换",
                           detail: "选择「跟随系统」后，系统切换深色时本应用会同步切换") {
                    PillTag(text: theme.theme == .system ? "已启用" : "未启用",
                            tint: theme.theme == .system ? Bencho.ok : Bencho.ink4)
                }
            }
        }
    }

    private var behaviorCard: some View {
        CardContainer(title: "窗口与退出", systemImage: "macwindow") {
            VStack(alignment: .leading, spacing: 8) {
                SettingRow(title: "关闭主窗口时",
                           detail: model.config.closeBehavior.detail) {
                    BenchoSegmented(items: CloseBehavior.allCases,
                                    title: { $0.label },
                                    selection: binding(\.closeBehavior))
                }

                Hairline()

                SettingRow(title: "菜单栏常驻图标",
                           detail: "常驻系统菜单栏，可随时启停服务、复制接入地址、恢复主窗口或退出") {
                    PillTag(text: "已启用", tint: Bencho.ok)
                }

                if model.config.closeBehavior == .minimizeToMenuBar {
                    Hairline()
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Bencho.pick)
                        Text("关闭窗口后应用将从 Dock 隐藏，仅保留菜单栏图标，FTP 服务继续运行。点击菜单栏图标选择「打开主窗口」即可恢复。")
                            .font(.benchoMicro)
                            .foregroundStyle(Bencho.ink4)
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
                BenchoSegmented(items: LogLevel.allCases,
                                title: { $0.label },
                                selection: binding(\.logLevel))
            }
        }
    }

    private var configCard: some View {
        CardContainer(title: "配置文件", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.configURL.path)
                    .font(.benchoMonoSmall)
                    .foregroundStyle(Bencho.ink4)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .benchoInset(corner: Bencho.Radius.inner)

                HStack(spacing: 8) {
                    Button("在访达中显示") { model.revealConfigInFinder() }
                        .buttonStyle(BenchoButtonStyle(kind: .secondary, compact: true))
                    Button("重新载入") {
                        model.stopServer()
                        let reloaded = ServerViewModel.loadConfig(from: model.configURL)
                        model.config = reloaded
                        model.saveConfig()
                        ToastCenter.shared.show(.info, "已重新载入配置")
                    }
                    .buttonStyle(BenchoButtonStyle(kind: .secondary, compact: true))
                    Spacer()
                    Button("恢复默认设置") { showResetConfirm = true }
                        .buttonStyle(BenchoButtonStyle(kind: .danger, compact: true))
                }
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

// MARK: - 数值步进

/// 用 −/+ 两枚胶囊键代替系统 Stepper：bencho 的 rolling-counter 就是这样拿掉箭头按钮的。
private struct ValueStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 0) {
            key("minus") {
                value = max(range.lowerBound, value - step)
            }

            Text(format(value))
                .font(.benchoMono)
                .monospacedDigit()
                .foregroundStyle(Bencho.ink)
                .frame(minWidth: 62)
                .contentTransition(.numericText())

            key("plus") {
                value = min(range.upperBound, value + step)
            }
        }
        .padding(3)
        .benchoInset(corner: Bencho.Radius.pill)
        .animation(Bencho.settle, value: value)
    }

    private func key(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Bencho.ink2)
                .frame(width: 24, height: 22)
                .background(Capsule().fill(Bencho.insetDeep))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
