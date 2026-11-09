import SwiftUI

struct AccountDraft: Identifiable {
    let id = UUID()
    var accountID: UUID?
    var username: String = ""
    var password: String = ""
    var rootPath: String = ServerConfig.defaultRootPath()
    var canDownload: Bool = true
    var canUpload: Bool = true
    var canDelete: Bool = true
    var canCreateDirectory: Bool = true
    var enabled: Bool = true

    var isNew: Bool { accountID == nil }

    static func from(_ account: FTPAccount) -> AccountDraft {
        AccountDraft(accountID: account.id,
                     username: account.username,
                     password: "",
                     rootPath: account.rootPath,
                     canDownload: account.canDownload,
                     canUpload: account.canUpload,
                     canDelete: account.canDelete,
                     canCreateDirectory: account.canCreateDirectory,
                     enabled: account.enabled)
    }
}

struct AccountsView: View {
    @ObservedObject var model: ServerViewModel
    @State private var draft: AccountDraft?
    @State private var pendingDeleteID: UUID?
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Bencho.Space.stack) {
                ServerControlBar(model: model)
                anonymousCard
                accountsCard
            }
            .padding(Bencho.Space.page)
        }
        .scrollContentBackground(.hidden)
        .background(Bencho.bg)
        .navigationTitle("用户账号")
        .sheet(item: $draft) { item in
            AccountEditorSheet(model: model, draft: item)
        }
        .alert("删除账号", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { pendingDeleteID = nil }
            Button("删除", role: .destructive) {
                if let id = pendingDeleteID {
                    let name = model.config.accounts.first(where: { $0.id == id })?.username ?? "账号"
                    model.removeAccount(id: id)
                    ToastCenter.shared.show(.warning, "已删除账号 \(name)")
                }
                pendingDeleteID = nil
            }
        } message: {
            Text("该账号的在线会话会被立即断开，删除操作不可撤销。")
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

    // MARK: - 匿名访问

    private var anonymousCard: some View {
        CardContainer(title: "匿名访问",
                      systemImage: "person.crop.circle.badge.questionmark",
                      trailing: {
                          PillTag(text: model.config.anonymousEnabled ? "已开启" : "已关闭",
                                  tint: model.config.anonymousEnabled ? Bencho.ok : Bencho.ink4)
                      }) {
            VStack(alignment: .leading, spacing: 8) {
                SettingRow(title: "允许匿名登录",
                           detail: "使用用户名 anonymous 或 ftp，口令任意填写") {
                    LiquidSwitch(isOn: model.config.anonymousEnabled,
                                 trackWidth: 42, trackHeight: 24,
                                 label: "允许匿名登录") {
                        binding(\.anonymousEnabled).wrappedValue.toggle()
                    }
                }

                Hairline()

                SettingRow(title: "匿名根目录", detail: model.config.anonymousRootPath) {
                    Button("选择…") {
                        DirectoryPicker.choose(title: "选择匿名共享目录",
                                               current: model.config.anonymousRootPath) { path in
                            guard let path = path else { return }
                            model.config.anonymousRootPath = path
                            model.saveConfig()
                        }
                    }
                    .buttonStyle(BenchoButtonStyle(kind: .secondary, compact: true))
                }

                Hairline()

                HStack(spacing: 10) {
                    toggleChip("上传", isOn: binding(\.anonymousCanUpload))
                    toggleChip("删除与重命名", isOn: binding(\.anonymousCanDelete))
                    toggleChip("创建目录", isOn: binding(\.anonymousCanCreateDirectory))
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)

                Text("匿名访问面向局域网内的临时共享，建议保持默认只读，仅按需开启上传。")
                    .font(.benchoMicro)
                    .foregroundStyle(Bencho.ink4)
                    .padding(.top, 2)
            }
        }
    }

    /// 权限开关做成「胶囊 + 短标签」，比一排 checkbox 更接近 bencho 的分段语言。
    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(Bencho.settle) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn.wrappedValue ? "checkmark" : "minus")
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.benchoMicro)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .foregroundStyle(isOn.wrappedValue ? Bencho.onInk : Bencho.ink4)
            .background(Capsule().fill(isOn.wrappedValue ? Bencho.fillOn : Bencho.inset))
            .overlay(Capsule().stroke(isOn.wrappedValue ? Color.clear : Bencho.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 账号列表

    private var accountsCard: some View {
        CardContainer(title: "账号列表",
                      systemImage: "person.badge.key",
                      trailing: {
                          Button {
                              draft = AccountDraft()
                          } label: {
                              Label("新建账号", systemImage: "plus")
                          }
                          .buttonStyle(BenchoButtonStyle(kind: .primary, compact: true))
                      }) {
            VStack(alignment: .leading, spacing: 0) {
                if model.config.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("尚未创建账号")
                            .font(.benchoLabel)
                            .foregroundStyle(Bencho.ink2)
                        Text("每个账号拥有独立根目录与权限。创建后即可用「用户名 + 口令」登录，与匿名访问相互独立。")
                            .font(.benchoMicro)
                            .foregroundStyle(Bencho.ink4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(model.config.accounts) { account in
                        accountRow(account)
                        if account.id != model.config.accounts.last?.id {
                            Hairline()
                        }
                    }
                }
            }
        }
    }

    private func accountRow(_ account: FTPAccount) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(account.enabled ? Bencho.inset : Bencho.insetDeep)
                Image(systemName: account.enabled ? "key.horizontal.fill" : "key.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(account.enabled ? Bencho.ink : Bencho.ink5)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(account.username)
                        .font(.benchoLabel)
                        .foregroundStyle(Bencho.ink)
                    if !account.enabled {
                        PillTag(text: "已禁用")
                    }
                }
                Text(account.effectiveRootPath)
                    .font(.benchoMonoSmall)
                    .foregroundStyle(Bencho.ink4)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(account.permissionSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(Bencho.ink5)
            }

            Spacer(minLength: 8)

            Button("编辑") {
                draft = AccountDraft.from(account)
            }
            .buttonStyle(BenchoButtonStyle(kind: .ghost, compact: true))

            Button("删除") {
                pendingDeleteID = account.id
                showDeleteConfirm = true
            }
            .buttonStyle(BenchoButtonStyle(kind: .danger, compact: true))
        }
        .padding(.vertical, 9)
    }
}

// MARK: - 账号编辑

struct AccountEditorSheet: View {
    @ObservedObject var model: ServerViewModel
    @State private var draft: AccountDraft
    @State private var validationMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(model: ServerViewModel, draft: AccountDraft) {
        self._model = ObservedObject(wrappedValue: model)
        self._draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text(draft.isNew ? "新建账号" : "编辑账号")
                    .font(.benchoHeadline)
                    .tracking(-0.3)
                    .foregroundStyle(Bencho.ink)
                Spacer()
            }
            .padding(.horizontal, Bencho.Space.l)
            .padding(.vertical, 18)

            Hairline()

            VStack(alignment: .leading, spacing: 14) {
                labeledField("用户名") {
                    TextField("例如 share", text: $draft.username)
                        .textFieldStyle(.plain)
                        .font(.benchoBody)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .benchoInset()
                        .disableAutocorrection(true)
                }

                labeledField(draft.isNew ? "口令" : "口令（留空表示不修改）") {
                    SecureField("至少 1 个字符", text: $draft.password)
                        .textFieldStyle(.plain)
                        .font(.benchoBody)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .benchoInset()
                }

                labeledField("根目录") {
                    HStack(spacing: 8) {
                        Text(draft.rootPath)
                            .font(.benchoMonoSmall)
                            .foregroundStyle(Bencho.ink2)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .benchoInset()
                        Button("选择…") {
                            DirectoryPicker.choose(title: "选择账号根目录",
                                                   current: draft.rootPath) { path in
                                if let path = path { draft.rootPath = path }
                            }
                        }
                        .buttonStyle(BenchoButtonStyle(kind: .secondary, compact: true))
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "权限")
                    VStack(alignment: .leading, spacing: 2) {
                        permissionRow("允许查看与下载（必需）", isOn: $draft.canDownload)
                        permissionRow("允许上传文件", isOn: $draft.canUpload)
                        permissionRow("允许删除与重命名", isOn: $draft.canDelete)
                        permissionRow("允许创建目录", isOn: $draft.canCreateDirectory)
                        permissionRow("启用该账号", isOn: $draft.enabled)
                    }
                }

                if let validationMessage = validationMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Bencho.danger)
                        Text(validationMessage)
                            .font(.benchoMicro)
                            .foregroundStyle(Bencho.danger)
                    }
                }
            }
            .padding(Bencho.Space.l)

            Hairline()

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(BenchoButtonStyle(kind: .ghost))
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "创建" : "保存") { save() }
                    .buttonStyle(BenchoButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Bencho.Space.l)
            .padding(.vertical, 16)
        }
        .frame(width: 470)
        .background(Bencho.bg)
    }

    private func permissionRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn.wrappedValue ? Bencho.fillOn : Bencho.inset)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isOn.wrappedValue ? Color.clear : Bencho.edgeStrong, lineWidth: 1)
                if isOn.wrappedValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Bencho.onInk)
                }
            }
            .frame(width: 15, height: 15)

            Text(title)
                .font(.benchoCaption)
                .foregroundStyle(isOn.wrappedValue ? Bencho.ink2 : Bencho.ink4)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Bencho.settle) { isOn.wrappedValue.toggle() }
        }
    }

    private func labeledField<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: title)
            content()
        }
    }

    private func save() {
        validationMessage = nil
        let name = draft.username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            validationMessage = "请填写用户名"
            return
        }
        guard !name.contains(" "), !name.contains("/"), !name.contains("\\") else {
            validationMessage = "用户名不能包含空格或斜杠"
            return
        }
        let duplicated = model.config.accounts.contains {
            $0.username.lowercased() == name.lowercased() && $0.id != draft.accountID
        }
        guard !duplicated else {
            validationMessage = "已存在同名账号"
            return
        }
        guard !draft.rootPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "请选择根目录"
            return
        }
        if draft.isNew {
            var account = FTPAccount(username: name, password: draft.password, rootPath: draft.rootPath)
            account.canDownload = draft.canDownload
            account.canUpload = draft.canUpload
            account.canDelete = draft.canDelete
            account.canCreateDirectory = draft.canCreateDirectory
            account.enabled = draft.enabled
            model.addAccount(account)
            ToastCenter.shared.show(.success, "已创建账号 \(name)")
        } else if let id = draft.accountID,
                  var account = model.config.accounts.first(where: { $0.id == id }) {
            account.username = name
            account.rootPath = draft.rootPath
            account.canDownload = draft.canDownload
            account.canUpload = draft.canUpload
            account.canDelete = draft.canDelete
            account.canCreateDirectory = draft.canCreateDirectory
            account.enabled = draft.enabled
            if !draft.password.isEmpty {
                account.setPassword(draft.password)
            }
            model.updateAccount(account)
            ToastCenter.shared.show(.success, "已保存账号 \(name)")
        }
        dismiss()
    }
}
