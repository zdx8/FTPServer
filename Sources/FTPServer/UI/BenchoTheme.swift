import SwiftUI
import AppKit

/// bencho 设计令牌在 SwiftUI 中的映射。
///
/// 数值取自 bencho 仓库的 `tokens.css`（MIT，https://github.com/cabralorenzo/bencho）。
/// 颜色用 AppKit 的动态 `NSColor` 提供者实现：同一份常量在浅色与深色外观下解析出不同值，
/// 因此界面切换主题时不需要重建视图树，与 `ThemeController` 施加的窗口外观天然同步。
///
/// 与上游的差异只有一处：`--font-ui` 首选 Inter，本机未安装，故全量使用系统字体（SF Pro）。
/// SF 与 Inter 同为中性无衬线，字重与字号层级按 Inter 的实测值给出，观感偏差在可接受范围内。
enum Bencho {

    // MARK: - 颜色

    /// 构造随外观自动解析的 `NSColor`。窗口底色这类要交给 AppKit 的场合用它。
    static func dynamicNS(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// 构造随外观自动解析的颜色。
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: dynamicNS(light, dark))
    }

    /// sRGB 十六进制字面量。
    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: alpha)
    }

    /// 页面底色。浅色为纸白，深色为纯黑——这是 bencho 深色主题的定义，不改成灰。
    static let bg = dynamic(hex(0xFFFFFF), hex(0x000000))
    /// 同一个底色的 `NSColor` 版本，供 `NSWindow.backgroundColor` 使用：
    /// 窗口标题栏只有在「透明 + 自身背景不透明」时才会与内容区同色。
    static let bgNS = dynamicNS(hex(0xFFFFFF), hex(0x000000))
    /// 卡片底色。深色下一律比页面亮一级，卡片才是「浮在纸上的一张纸」。
    static let card = dynamic(hex(0xF7F7F6), hex(0x0F0F0F))
    /// 卡片内部的凹槽（搜索框、日志面、分段控件的轨道）。
    static let inset = dynamic(hex(0xF1F1F0), hex(0x181818))
    static let insetDeep = dynamic(hex(0xECEBE7), hex(0x202020))

    static let ink = dynamic(hex(0x17181A), hex(0xFFFFFF))
    static let ink2 = dynamic(hex(0x3C3B37), hex(0xB4B4B4))
    static let ink3 = dynamic(hex(0x5C5B56), hex(0x9A9A9A))
    static let ink4 = dynamic(hex(0x6F6E68), hex(0x828282))
    static let ink5 = dynamic(hex(0x85847E), hex(0x6B6B6B))
    /// 墨色底上的文字色，随墨色一起反转。
    static let onInk = dynamic(hex(0xFFFFFF), hex(0x000000))

    /// 开关/滑块的「亮端」与「暗端」，对应 tokens 的 fill-slab / fill-on。
    static let fillSlab = dynamic(hex(0xFFFFFF), hex(0x262626))
    static let fillOn = dynamic(hex(0x17181A), hex(0xFFFFFF))

    /// 发丝线。bencho 一律用 1px 描边代替投影，这是全库的视觉基线。
    static let edge = dynamic(hex(0x17181A, 0.08), hex(0xFFFFFF, 0.08))
    static let edgeStrong = dynamic(hex(0x17181A, 0.16), hex(0xFFFFFF, 0.16))

    static let pick = dynamic(hex(0x0D99FF), hex(0x3AA9FF))
    static let signal = dynamic(hex(0x2231DD), hex(0x8FA0FF))
    static let ok = dynamic(hex(0x15803D), hex(0x34D17A))
    static let warn = dynamic(hex(0xE09A12), hex(0xE0A73A))
    static let danger = dynamic(hex(0xC0362C), hex(0xE5484D))
    static let ember = dynamic(hex(0xB8431C), hex(0xE4674A))
    static let success = dynamic(hex(0x1F9D55), hex(0x34D17A))

    // MARK: - 尺寸

    enum Radius {
        /// 主卡片。bencho 的 block 外壳用 18–20，取其下限。
        static let card: CGFloat = 18
        /// 卡片内部元件。
        static let inner: CGFloat = 12
        /// 输入框与内嵌凹槽。
        static let field: CGFloat = 10
        /// 胶囊。
        static let pill: CGFloat = 999
    }

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 14
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
        /// 页面内边距。
        static let page: CGFloat = 22
        /// 卡片内边距。
        static let card: CGFloat = 18
        /// 卡片之间的纵向间隔。
        static let stack: CGFloat = 14
    }

    // MARK: - 动效

    /// 按下与松开。bencho 的 `scale 0.96 / 160ms cubic-bezier(0.22, 1, 0.36, 1)`。
    static let press = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.16)
    /// 布局与选中态迁移。
    static let settle = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// 开关滑块、Toast 入场这类有质量的运动。
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.72)
    /// 透明度与色彩过渡。
    static let fade = Animation.easeOut(duration: 0.22)
}

// MARK: - 排版

extension Font {
    /// 卡片标题。Inter 15 / 500。
    static let benchoTitle = Font.system(size: 15, weight: .medium)
    /// 页面主标题。
    static let benchoHeadline = Font.system(size: 19, weight: .medium)
    /// 正文。Inter 13 / 400。
    static let benchoBody = Font.system(size: 13)
    /// 小标签。Inter 12 / 500。
    static let benchoLabel = Font.system(size: 12, weight: .medium)
    /// 说明文字。Inter 12 / 400。
    static let benchoCaption = Font.system(size: 12)
    /// 最小号。Inter 11。
    static let benchoMicro = Font.system(size: 11)
    /// 统计卡里的大数字。bencho 的 rolling counter 用 30 / 500、tabular、字距 -0.02em。
    static let benchoNumber = Font.system(size: 26, weight: .medium).monospacedDigit()
    static let benchoMono = Font.system(size: 12, design: .monospaced)
    static let benchoMonoSmall = Font.system(size: 11, design: .monospaced)
}

// MARK: - 通用修饰

extension View {
    /// 发丝描边卡片。
    func benchoSurface(corner: CGFloat = Bencho.Radius.card) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Bencho.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Bencho.edge, lineWidth: 1)
            )
    }

    /// 凹槽（输入框、日志面、分段轨道）。
    func benchoInset(corner: CGFloat = Bencho.Radius.field) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Bencho.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Bencho.edge, lineWidth: 1)
            )
    }
}
