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
            VStack(alignment: .leading, spacing: 16) {
                ServerControlBar(model: model)
                anonymousCard
                accountsCard
            }
            .padding(20)
        }
        .navigationTitle("用户账号")
        .sheet(item: $draft) { item in
            AccountEditorSheet(model: model, draft: item)
        }
        .alert("删除账号", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { pendingDeleteID = nil }
            Button("删除", role: .destructive) {
                if let id = pendingDeleteID { model.removeAccount(id: id) }
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
                      subtitle: model.config.anonymousEnabled ? "已开启" : "已关闭",
                      systemImage: "person.crop.circle.badge.questionmark") {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "允许匿名登录",
                           detail: "使用用户名 anonymous 或 ftp，口令任意填写") {
                    Toggle("", isOn: binding(\.anonymousEnabled)).labelsHidden()
                }

                Divider()

                SettingRow(title: "匿名根目录", detail: model.config.anonymousRootPath) {
                    Button("选择…") {
                        DirectoryPicker.choose(title: "选择匿名共享目录",
                                               current: model.config.anonymousRootPath) { path in
                            guard let path = path else { return }
                            model.config.anonymousRootPath = path
                            model.saveConfig()
                        }
                    }
                }

                Divider()

                SettingRow(title: "允许上传", detail: "匿名用户可写入文件") {
                    Toggle("", isOn: binding(\.anonymousCanUpload)).labelsHidden()
                }
                SettingRow(title: "允许删除与重命名") {
                    Toggle("", isOn: binding(\.anonymousCanDelete)).labelsHidden()
                }
                SettingRow(title: "允许创建目录") {
                    Toggle("", isOn: binding(\.anonymousCanCreateDirectory)).labelsHidden()
                }

                Text("提示：匿名访问面向局域网内的临时共享，建议保持默认只读，仅按需开启上传。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - 账号列表

    private var accountsCard: some View {
        CardContainer(title: "账号列表",
                      subtitle: "\(model.config.accounts.count) 个账号",
                      systemImage: "person.badge.key") {
            VStack(alignment: .leading, spacing: 0) {
                if model.config.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("尚未创建账号")
                            .font(.system(size: 12, weight: .medium))
                        Text("每个账号拥有独立根目录与权限。创建后即可用「用户名 + 口令」登录，与匿名访问相互独立。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(model.config.accounts) { account in
                        accountRow(account)
                        if account.id != model.config.accounts.last?.id {
                            Divider()
                        }
                    }
                }

                HStack {
                    Button {
                        draft = AccountDraft()
                    } label: {
                        Label("新建账号", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.top, 12)
            }
        }
    }

    private func accountRow(_ account: FTPAccount) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.enabled ? "key.horizontal.fill" : "key.slash")
                .font(.system(size: 13))
                .foregroundStyle(account.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(account.username)
                        .font(.system(size: 13, weight: .medium))
                    if !account.enabled {
                        Text("已禁用")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(account.effectiveRootPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(account.permissionSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button("编辑") {
                draft = AccountDraft.from(account)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))

            Button("删除") {
                pendingDeleteID = account.id
                showDeleteConfirm = true
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .foregroundStyle(Color.red)
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
            HStack(spacing: 8) {
                Image(systemName: draft.isNew ? "person.badge.plus" : "person.badge.key")
                    .foregroundStyle(Color.accentColor)
                Text(draft.isNew ? "新建账号" : "编辑账号")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                labeledField("用户名") {
                    TextField("例如 share", text: $draft.username)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                labeledField(draft.isNew ? "口令" : "口令（留空表示不修改）") {
                    SecureField("至少 1 个字符", text: $draft.password)
                        .textFieldStyle(.roundedBorder)
                }

                labeledField("根目录") {
                    HStack(spacing: 8) {
                        Text(draft.rootPath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        Button("选择…") {
                            DirectoryPicker.choose(title: "选择账号根目录",
                                                   current: draft.rootPath) { path in
                                if let path = path { draft.rootPath = path }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("权限")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Toggle("允许查看与下载（必需）", isOn: $draft.canDownload)
                    Toggle("允许上传文件", isOn: $draft.canUpload)
                    Toggle("允许删除与重命名", isOn: $draft.canDelete)
                    Toggle("允许创建目录", isOn: $draft.canCreateDirectory)
                    Toggle("启用该账号", isOn: $draft.enabled)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

                if let validationMessage = validationMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.red)
                        Text(validationMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "创建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
    }

    private func labeledField<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
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
        }
        dismiss()
    }
}

// MARK: - 设置行

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let detail = detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            control()
        }
        .padding(.vertical, 3)
    }
}
