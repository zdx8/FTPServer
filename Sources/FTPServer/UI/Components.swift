import SwiftUI
import AppKit

// MARK: - 基础零件

/// 发丝分隔线。bencho 全库不用投影，只用 1px 描边，这是同一套语言的一部分。
struct Hairline: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Bencho.edge)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

/// 小号分区标题。
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.benchoMicro)
            .foregroundStyle(Bencho.ink4)
            .tracking(0.2)
    }
}

// MARK: - 状态指示

struct StatusDot: View {
    let state: FTPServerState
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.16))
                .frame(width: size * 2.3, height: size * 2.3)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }

    private var color: Color {
        switch state {
        case .running:              return Bencho.ok
        case .starting, .stopping:  return Bencho.warn
        case .failed:               return Bencho.danger
        case .stopped:              return Bencho.ink5
        }
    }
}

/// 日志级别胶囊。bencho 的 tone 取值：success / error / warning / info。
struct LevelChip: View {
    let level: LogLevel

    var body: some View {
        Text(level.label)
            .font(.system(size: 10, weight: .medium))
            .tracking(0.2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
            .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 1))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch level {
        case .debug:   return Bencho.ink4
        case .info:    return Bencho.signal
        case .warning: return Bencho.warn
        case .error:   return Bencho.danger
        }
    }
}

/// 中性标签，用于「已禁用」「只读」这类状态。
struct PillTag: View {
    let text: String
    var tint: Color = Bencho.ink4

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
    }
}

// MARK: - 按钮

/// bencho 的按键语言：胶囊、1px 描边、按下缩到 0.96，不用系统 bezel。
struct BenchoButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, link, danger }

    var kind: Kind = .secondary
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        BenchoButtonBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct BenchoButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let compact: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.benchoLabel)
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 9 : 14)
                .frame(height: compact ? 26 : 32)
                .background(
                    Capsule().fill(background)
                )
                .overlay(
                    Capsule().stroke(border, lineWidth: 1)
                )
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(Bencho.press, value: configuration.isPressed)
                .animation(Bencho.fade, value: hovering)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary:   return Bencho.onInk
            case .secondary: return Bencho.ink
            case .ghost:     return Bencho.ink2
            case .link:      return Bencho.pick
            case .danger:    return Bencho.danger
            }
        }

        private var background: Color {
            switch kind {
            case .primary:   return Bencho.fillOn
            case .secondary: return hovering ? Bencho.insetDeep : Bencho.inset
            case .ghost:     return hovering ? Bencho.inset : Color.clear
            case .link:      return hovering ? Bencho.pick.opacity(0.10) : Color.clear
            case .danger:    return Bencho.danger.opacity(hovering ? 0.18 : 0.11)
            }
        }

        private var border: Color {
            switch kind {
            case .secondary, .ghost: return Bencho.edge
            default:                 return .clear
            }
        }
    }
}

// MARK: - 液体开关

/// bencho 的 `liq-toggle` 移植。
///
/// 上游用 SVG 的 goo 滤镜（高斯模糊 + alpha 阈值）把轨道和液滴融成一团金属球。
/// SwiftUI 没有等价的 metaball 滤镜，这里改用**胶囊拉伸**近似同一动作：
/// 按压/拖拽时液滴沿行进方向拉长，松手回弹，轨道与液滴仍按 bencho 的规则反色
/// （关＝浅轨深滴，开＝深轨浅滴），色彩与 420ms 的过渡曲线与上游一致。
struct LiquidSwitch: View {
    var isOn: Bool
    var isEnabled: Bool = true
    var trackWidth: CGFloat = 48
    var trackHeight: CGFloat = 27
    /// 无障碍名称。默认是服务总开关，其他用途（匿名登录、自动滚动等）必须覆盖。
    var label: String = "服务开关"
    var action: () -> Void

    @State private var dragging = false
    @State private var dragProgress: CGFloat?
    @State private var cursorPushed = false

    private var thumbSize: CGFloat { trackHeight - 5 }
    private var travel: CGFloat { max(1, trackWidth - thumbSize - 5) }
    private var progress: CGFloat { dragProgress ?? (isOn ? 1 : 0) }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? Bencho.fillOn : Bencho.fillSlab)

            Capsule()
                .stroke(Bencho.edge, lineWidth: 1)

            Capsule()
                .fill(thumbFill)
                .frame(width: thumbSize + (dragging ? 9 : 0), height: thumbSize)
                .offset(x: 2.5 + progress * travel)
                .animation(dragging ? nil : Bencho.spring, value: progress)
                .animation(Bencho.spring, value: dragging)
        }
        .frame(width: trackWidth, height: trackHeight)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isEnabled else { return }
                    dragging = true
                    let base: CGFloat = isOn ? 1 : 0
                    dragProgress = min(1, max(0, base + value.translation.width / travel))
                }
                .onEnded { value in
                    guard isEnabled else { return }
                    let base: CGFloat = isOn ? 1 : 0
                    let landed = min(1, max(0, base + value.translation.width / travel))
                    let moved = abs(value.translation.width)
                    // 位移不足 3pt 视为点击；否则以是否越过中线判定
                    let shouldToggle = moved < 3 || (landed >= 0.5) != isOn
                    if shouldToggle {
                        // 停在落点等父视图翻状态，避免松手瞬间先弹回原位再跳到新位置
                        withAnimation(Bencho.spring) {
                            dragging = false
                            dragProgress = landed
                        }
                        action()
                    } else {
                        // 没越过中线：回弹到真实状态
                        withAnimation(Bencho.spring) {
                            dragging = false
                            dragProgress = nil
                        }
                    }
                }
        )
        .onChange(of: isOn) { _, _ in
            // 状态已翻，交还控制权
            withAnimation(Bencho.spring) { dragProgress = nil }
        }
        .onHover { inside in
            // push/pop 必须成对：视图在悬停中被移除或变成禁用时也要 pop，
            // 否则光标会永远停在手形（NSCursor 是全局栈）。
            if inside && isEnabled {
                if !cursorPushed {
                    NSCursor.pointingHand.push()
                    cursorPushed = true
                }
            } else if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "已启动" : "已停止")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        // 有意不做 .focusable()：本视图自己画胶囊，系统焦点环会在药丸外再套一圈
        // 与设计冲突的高亮，且窗口启动时首个可聚焦视图会自动取得焦点、常驻一圈光晕。
        // 键盘用户的路径是 ⌘R（启停服务）；VoiceOver 通过上面的 accessibilityAction 操作。
    }

    /// 关：轨道取 fill-slab，液滴是往轨道方向混 19% 墨色。
    /// 用叠层透明度做 color-mix，避免依赖不可用的动态取色运算。
    private var thumbFill: AnyShapeStyle {
        if isOn {
            return AnyShapeStyle(Bencho.fillSlab)
        }
        return AnyShapeStyle(Bencho.fillOn.opacity(0.19))
    }
}

// MARK: - 分段控件

/// bencho 的 `magnet-select` 语言：一个凹槽轨道，选中项是一枚会滑动的深色胶囊。
struct BenchoSegmented<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Text(title(item))
                    .font(.benchoLabel)
                    .foregroundStyle(selected ? Bencho.onInk : Bencho.ink3)
                    .padding(.horizontal, 11)
                    .frame(height: 25)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Bencho.fillOn)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(Bencho.settle) { selection = item }
                    }
            }
        }
        .padding(3)
        .background(Capsule().fill(Bencho.inset))
        .overlay(Capsule().stroke(Bencho.edge, lineWidth: 1))
    }
}

// MARK: - Toast

enum BenchoToastKind {
    case success, error, warning, info

    var color: Color {
        switch self {
        case .success: return Bencho.success
        case .error:   return Bencho.danger
        case .warning: return Bencho.warn
        case .info:    return Bencho.ink3
        }
    }

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }
}

struct BenchoToast: Identifiable {
    let id = UUID()
    let kind: BenchoToastKind
    let title: String
    let detail: String?
}

/// Toast 队列。bencho 的 toast-stack 只保留最近三张，新的压在最上面。
@MainActor
final class ToastCenter: ObservableObject {

    static let shared = ToastCenter()

    @Published private(set) var toasts: [BenchoToast] = []
    private var timers: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func show(_ kind: BenchoToastKind, _ title: String, detail: String? = nil) {
        let toast = BenchoToast(kind: kind, title: title, detail: detail)
        withAnimation(Bencho.spring) {
            toasts.insert(toast, at: 0)
            if toasts.count > 3 { toasts.removeLast() }
        }
        timers[toast.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    func dismiss(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        withAnimation(Bencho.fade) {
            toasts.removeAll { $0.id == id }
        }
    }
}

/// 右上角浮层。挂在根视图的 overlay 上，不参与布局。
struct ToastStackView: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                toastRow(toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 只占内容本身的尺寸：此前用 maxWidth/maxHeight 铺满整层，
        // 一旦有 Toast 就把整个内容区变成可命中区域，2.6 秒内点哪儿都没反应。
        .padding(.bottom, 18)
        .padding(.trailing, 18)
    }

    private func toastRow(_ toast: BenchoToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind.icon)
                .font(.system(size: 14))
                .foregroundStyle(toast.kind.color)

            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.benchoLabel)
                    .foregroundStyle(Bencho.ink)
                    .lineLimit(1)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.benchoMicro)
                        .foregroundStyle(Bencho.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            Button {
                center.dismiss(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Bencho.ink4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: 302, height: 52)
        .benchoSurface(corner: 14)
    }
}

// MARK: - 悬停倾斜

/// bencho 的 `tilt` 移植：指针在卡片上时按位置做极小角度的三维偏转。
/// 幅度刻意压到 3.5 度——桌面端反复悬停时，大角度会变成干扰。
struct BenchoTilt: ViewModifier {
    var maxAngle: Double = 3.5

    @State private var size: CGSize = .zero
    @State private var point: CGPoint = .zero
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angleX), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
            .rotation3DEffect(.degrees(angleY), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, newValue in size = newValue }
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    point = location
                    hovering = true
                case .ended:
                    hovering = false
                }
            }
            .animation(Bencho.fade, value: hovering)
            .animation(.easeOut(duration: 0.1), value: point)
    }

    private var angleX: Double {
        guard hovering, size.height > 0 else { return 0 }
        return -((point.y / size.height) * 2 - 1) * maxAngle
    }

    private var angleY: Double {
        guard hovering, size.width > 0 else { return 0 }
        return ((point.x / size.width) * 2 - 1) * maxAngle
    }
}

extension View {
    func benchoTilt(_ angle: Double = 3.5) -> some View {
        modifier(BenchoTilt(maxAngle: angle))
    }
}

// MARK: - 卡片容器

struct CardContainer<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let systemImage = systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Bencho.ink4)
                    }
                    Text(title)
                        .font(.benchoTitle)
                        .tracking(-0.2)
                        .foregroundStyle(Bencho.ink)
                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.benchoMicro)
                            .foregroundStyle(Bencho.ink4)
                    }
                }
                Spacer(minLength: 0)
                trailing()
            }
            content()
        }
        .padding(Bencho.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchoSurface()
    }
}

extension CardContainer where Trailing == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         systemImage: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title,
                  subtitle: subtitle,
                  systemImage: systemImage,
                  trailing: { EmptyView() },
                  content: content)
    }
}

// MARK: - 统计卡

struct StatCard: View {
    let title: String
    let value: String
    var caption: String? = nil
    var systemImage: String? = nil
    var tint: Color = Bencho.ink4

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.benchoMicro)
                    .foregroundStyle(Bencho.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(value)
                .font(.benchoNumber)
                .tracking(-0.6)
                .foregroundStyle(Bencho.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
                .animation(Bencho.settle, value: value)

            if let caption = caption {
                Text(caption)
                    .font(.benchoMicro)
                    .foregroundStyle(Bencho.ink5)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .benchoSurface()
        .benchoTilt()
    }
}

// MARK: - 顶部控制条

struct ServerControlBar: View {
    @ObservedObject var model: ServerViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    StatusDot(state: model.state, size: 8)
                    Text(model.state.label)
                        .font(.system(size: 17, weight: .medium))
                        .tracking(-0.3)
                        .foregroundStyle(Bencho.ink)
                    if model.state.isBusy {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(subtitle)
                    .font(.benchoMonoSmall)
                    .foregroundStyle(Bencho.ink4)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            LiquidSwitch(isOn: model.server.isRunning,
                         isEnabled: !model.state.isBusy) {
                model.toggleServer()
            }

            Button(model.server.isRunning ? "停止服务" : "启动服务") {
                model.toggleServer()
            }
            .buttonStyle(BenchoButtonStyle(kind: .primary))
            .disabled(model.state.isBusy)
            .keyboardShortcut("r", modifiers: [.command])
        }
        .padding(.horizontal, Bencho.Space.card)
        .padding(.vertical, 16)
        .benchoSurface()
    }

    private var subtitle: String {
        switch model.state {
        case .running:
            return "监听端口 \(model.config.port) · 已运行 \(model.server.uptimeText)"
        case .stopped:
            return "端口 \(model.config.port) · 未在监听"
        case .starting:
            return "正在绑定端口 \(model.config.port)…"
        case .stopping:
            return "正在关闭连接…"
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - 地址行

struct AddressRow: View {
    let name: String
    let url: String
    @ObservedObject var model: ServerViewModel

    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.benchoMicro)
                .foregroundStyle(Bencho.ink4)
                .frame(width: 58, alignment: .leading)

            Text(url)
                .font(.benchoMono)
                .foregroundStyle(Bencho.ink)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Button {
                model.copyToPasteboard(url)
                withAnimation(Bencho.settle) { copied = true }
                ToastCenter.shared.show(.success, "已复制接入地址", detail: url)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation(Bencho.fade) { copied = false }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                    Text(copied ? "已复制" : "复制")
                }
            }
            .buttonStyle(BenchoButtonStyle(kind: copied ? .ghost : .link, compact: true))
            .animation(Bencho.fade, value: copied)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Bencho.Radius.inner, style: .continuous)
                .fill(hovering ? Bencho.inset : Color.clear)
        )
        .animation(Bencho.fade, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - 空状态

struct EmptyHint: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Bencho.ink5)
            Text(title)
                .font(.benchoTitle)
                .foregroundStyle(Bencho.ink2)
            Text(message)
                .font(.benchoCaption)
                .foregroundStyle(Bencho.ink4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
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
                Text(title)
                    .font(.benchoLabel)
                    .foregroundStyle(Bencho.ink)
                if let detail = detail, !detail.isEmpty {
                    Text(detail)
                        .font(.benchoMonoSmall)
                        .foregroundStyle(Bencho.ink4)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            control()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 搜索框

struct BenchoSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Bencho.ink4)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.benchoCaption)
                .foregroundStyle(Bencho.ink)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Bencho.ink5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .benchoInset(corner: Bencho.Radius.pill)
    }
}

// MARK: - 窗口外壳

/// 让系统标题栏与内容区同色。
///
/// 默认情况下 `NSToolbar` 会画一层材质：深色下偏灰、浅色下偏灰白，
/// 与 bencho 的纯黑 / 纸白底色并置就出现一条明显不同的横带。
/// 需要三步一起做才干净——SwiftUI 侧 `.toolbarBackground(.hidden, for: .windowToolbar)`
/// 去掉工具栏材质，这里把标题栏设为透明、窗口自身底色设为页面底色，
/// 再去掉标题栏下方的发丝线。三步缺任何一步都会留下色差或一条分隔线。
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 主题切换会重建视图树，这里重新施加一次，避免窗口底色停留在旧值。
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    private static func apply(to window: NSWindow?) {
        guard let window = window else { return }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = Bencho.bgNS
    }
}

// MARK: - 目录选择

enum DirectoryPicker {
    static func choose(title: String, current: String, completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK {
            completion(panel.url?.path)
        } else {
            completion(nil)
        }
    }
}
