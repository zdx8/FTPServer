import AppKit

/// 图标验收：对生成的 PNG 逐点采样，核对「绿色渐变底 + 白色渐变字母 F」。
/// 用法：iconcheck <AppIcon.iconset 目录>
///
/// 之所以逐点断言而不是目视：图标是构建产物，改一次脚本就要重新生成，
/// 需要一条可重复执行、能自动判定的检查。

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("用法：iconcheck <AppIcon.iconset 目录>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)

var failureCount = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    print("  [\(condition ? "PASS" : "FAIL")] \(name)\(condition ? "" : "  → \(detail)")")
    if !condition { failureCount += 1 }
}

// 与 make_icon.swift 保持一致的几何参数
let bodyInsetRatio: CGFloat = 0.055
let stemX: CGFloat = 0.35           // 竖笔横向中心
let topArmY: CGFloat = 0.72         // 顶横纵向位置
let middleArmY: CGFloat = 0.478     // 中横纵向位置
let gapY: CGFloat = 0.60            // 顶横与中横之间的空白
let armRightX: CGFloat = 0.65       // 顶横右段（只有顶横延伸到这么右）
let backgroundX: CGFloat = 0.18     // 竖笔左侧的底色区域

// MARK: - 文件完整性

print("== 图标文件 ==")
let expected = ["icon_16x16.png", "icon_16x16@2x.png", "icon_32x32.png", "icon_32x32@2x.png",
                "icon_128x128.png", "icon_128x128@2x.png", "icon_256x256.png",
                "icon_256x256@2x.png", "icon_512x512.png", "icon_512x512@2x.png"]
var missing: [String] = []
for name in expected {
    let path = directory.appendingPathComponent(name).path
    if !FileManager.default.fileExists(atPath: path) { missing.append(name) }
}
check("10 个尺寸文件齐全", missing.isEmpty, missing.joined(separator: ", "))

guard let imageData = try? Data(contentsOf: directory.appendingPathComponent("icon_512x512.png")),
      let rep = NSBitmapImageRep(data: imageData) else {
    print("  无法读取 icon_512x512.png")
    exit(1)
}

// MARK: - 像素采样

let size = CGFloat(rep.pixelsWide)
let inset = size * bodyInsetRatio

/// 以底板比例坐标取色。x、y 均以底板左下角为原点。
func sample(_ x: CGFloat, _ y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    let bodySize = size - inset * 2
    let px = Int(inset + bodySize * x)
    let py = Int(size - (inset + bodySize * y))   // 位图 y 轴自顶向下
    guard px >= 0, px < rep.pixelsWide, py >= 0, py < rep.pixelsHigh,
          let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else {
        return (0, 0, 0, 0)
    }
    return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
}

print("")
print("== 底图与透明区 ==")
let corner = sample(-0.20, -0.20)
check("圆角之外为透明", corner.a < 0.1, "alpha=\(String(format: "%.2f", corner.a))")
check("画布尺寸为 512", rep.pixelsWide == 512, "\(rep.pixelsWide)")

let background = sample(backgroundX, 0.50)
check("底色为绿色（G 明显高于 R）",
      background.g > background.r + 0.20 && background.g > background.b + 0.10 && background.a > 0.9,
      String(format: "R=%.3f G=%.3f B=%.3f", background.r, background.g, background.b))
check("底色为绿色（G 通道占优）",
      background.g > 0.45, String(format: "G=%.3f", background.g))

print("")
print("== 字母 F 的形状 ==")
let stem = sample(stemX, 0.50)
check("竖笔为白色",
      stem.r > 0.85 && stem.g > 0.85 && stem.b > 0.85,
      String(format: "R=%.3f G=%.3f B=%.3f", stem.r, stem.g, stem.b))

let topArm = sample(armRightX, topArmY)
check("顶横延伸到右侧且为白色",
      topArm.r > 0.85 && topArm.g > 0.85 && topArm.b > 0.85,
      String(format: "R=%.3f G=%.3f B=%.3f", topArm.r, topArm.g, topArm.b))

let middleArm = sample(0.55, middleArmY)
check("中横为白色",
      middleArm.r > 0.85 && middleArm.g > 0.85 && middleArm.b > 0.85,
      String(format: "R=%.3f G=%.3f B=%.3f", middleArm.r, middleArm.g, middleArm.b))

let gap = sample(armRightX, gapY)
check("顶横与中横之间为底色（说明是 F 不是 E）",
      gap.g > gap.r + 0.20,
      String(format: "R=%.3f G=%.3f B=%.3f", gap.r, gap.g, gap.b))

let belowMiddleArm = sample(0.55, 0.30)
check("中横下方为底色",
      belowMiddleArm.g > belowMiddleArm.r + 0.20,
      String(format: "R=%.3f G=%.3f B=%.3f", belowMiddleArm.r, belowMiddleArm.g, belowMiddleArm.b))

print("")
print("== 白色渐变 ==")
let stemTop = sample(stemX, 0.76)
let stemBottom = sample(stemX, 0.24)
let topIsPureWhite = stemTop.r > 0.97 && stemTop.g > 0.97 && stemTop.b > 0.97
check("字母顶部接近纯白", topIsPureWhite,
      String(format: "R=%.3f G=%.3f B=%.3f", stemTop.r, stemTop.g, stemTop.b))
check("字母底部透出绿意，形成渐变",
      stemBottom.g > stemBottom.r + 0.02,
      String(format: "顶部 G=%.3f，底部 G=%.3f / R=%.3f",
             stemTop.g, stemBottom.g, stemBottom.r))
check("渐变方向自上而下（顶部比底部更亮）",
      min(stemTop.r, stemTop.g, stemTop.b) > min(stemBottom.r, stemBottom.g, stemBottom.b),
      "顶部与底部亮度接近，渐变不可辨")

print("")
print(failureCount == 0 ? "图标验收通过" : "图标验收失败 \(failureCount) 项")
exit(failureCount == 0 ? 0 : 1)
