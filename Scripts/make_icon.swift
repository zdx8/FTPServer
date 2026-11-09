import AppKit
import CoreGraphics

// 生成应用图标：绿色渐变底 + 白色渐变的几何字母 F。
// 用法：make_icon <输出目录.iconset>
//
// 字母用矩形拼成而非字样绘制：16px 尺寸下笔画边缘依然锐利，
// 不依赖系统字体，也不受字体缺失影响。

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/icon.iconset"

let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

/// iconset 文件名 → 像素尺寸
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - 配色

/// 绿色渐变底：左上偏亮 → 右下偏深
let backgroundStart = NSColor(srgbRed: 0.16, green: 0.76, blue: 0.40, alpha: 1.0)
let backgroundEnd   = NSColor(srgbRed: 0.03, green: 0.45, blue: 0.24, alpha: 1.0)

/// 字母白色的渐变：顶部纯白 → 底部带透明度，透出底色形成白色渐变质感
let glyphStart = NSColor.white
let glyphEnd   = NSColor.white.withAlphaComponent(0.76)

/// 字母 F 的三段矩形，坐标为相对底板的比例（0 = 底边，1 = 顶边）。
/// 竖笔 + 顶横 + 中横，构成长宽比协调的块状无衬线 F。
typealias UnitRect = (x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat)

let stemRect: UnitRect      = (x0: 0.285, y0: 0.215, x1: 0.415, y1: 0.785)
let topArmRect: UnitRect    = (x0: 0.285, y0: 0.655, x1: 0.715, y1: 0.785)
let middleArmRect: UnitRect = (x0: 0.285, y0: 0.418, x1: 0.605, y1: 0.543)

func makeGradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient? {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors.map { $0.cgColor } as CFArray,
               locations: locations)
}

func renderIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels,
                                     pixelsHigh: pixels,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context

    let cg = context.cgContext
    let size = CGFloat(pixels)

    // 圆角底板
    let inset = size * 0.055
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * 0.225
    let bodyPath = CGPath(roundedRect: body,
                          cornerWidth: radius,
                          cornerHeight: radius,
                          transform: nil)

    // 1) 绿色渐变底
    cg.saveGState()
    cg.addPath(bodyPath)
    cg.clip()
    if let gradient = makeGradient([backgroundStart, backgroundEnd], [0, 1]) {
        cg.drawLinearGradient(gradient,
                              start: CGPoint(x: body.minX, y: body.maxY),
                              end: CGPoint(x: body.maxX, y: body.minY),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    cg.restoreGState()

    // 2) 白色渐变字母 F
    func glyphRect(_ r: (x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat)) -> CGRect {
        CGRect(x: body.minX + body.width * r.x0,
               y: body.minY + body.height * r.y0,
               width: body.width * (r.x1 - r.x0),
               height: body.height * (r.y1 - r.y0))
    }

    let glyphPath = CGMutablePath()
    glyphPath.addRect(glyphRect(stemRect))
    glyphPath.addRect(glyphRect(topArmRect))
    glyphPath.addRect(glyphRect(middleArmRect))

    cg.saveGState()
    cg.addPath(glyphPath)
    cg.clip()
    if let gradient = makeGradient([glyphStart, glyphEnd], [0, 1]) {
        // 渐变贴合字母自身的高度范围（0.215–0.785），而不是铺满整个画布，
        // 这样字母顶端才是纯白、底部才明显透出底色。
        cg.drawLinearGradient(gradient,
                              start: CGPoint(x: body.midX, y: body.minY + body.height * 0.785),
                              end: CGPoint(x: body.midX, y: body.minY + body.height * 0.215),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    cg.restoreGState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - 入口

for variant in variants {
    guard let data = renderIcon(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("渲染 \(variant.name) 失败\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(variant.name)
    do {
        try data.write(to: url)
    } catch {
        FileHandle.standardError.write(Data("写入 \(variant.name) 失败：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

print("已生成 \(variants.count) 个图标尺寸 → \(outputDirectory)")
