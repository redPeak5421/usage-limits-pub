#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments[1])
/// 图标变体：gauge（霓虹转速表，默认）| molten（熔金水位，保留备选）。
/// 用法：swift scripts/generate_brand_art.swift <项目根目录> [gauge|molten]
let iconVariant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "gauge"

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { fatalError("dest") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
    try! data.write(to: url)
    print("wrote", url.path, image.width, "x", image.height)
}

func ctx(_ w: Int, _ h: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// MARK: - App icon: 霓虹转速表（指针指向 80%、直奔白热红线，「快到上限」不言自明）
// 深墨紫底 + 紫→品红→琥珀色带 + 白热指针/红线刻度；Tinted=灰阶剪影（系统自行着色）。

/// clear：「透明底」替换图标——iOS 会把图标透明区渲染成纯黑（且 App Store 拒收带 alpha 的图标），
/// 所以直接画在纯黑上、去掉环境光与光池，只留表盘本体与自身光晕。
enum IconMode { case dark, tinted, clear, glass }

private let iconColorSpace = CGColorSpaceCreateDeviceRGB()

private func iconGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: iconColorSpace, colors: colors as CFArray, locations: locations)!
}

func makeAppIcon(_ mode: IconMode) -> CGImage {
    if mode == .glass { return makeGlassGaugeIcon() }
    return iconVariant == "molten" ? makeMoltenIcon(mode) : makeGaugeIcon(mode)
}

// MARK: 替换图标「磨砂玻璃」：浅色磨砂底 + 炫光色玻璃质感表盘
// iOS 不允许真透明图标（alpha 会被填黑、App Store 拒收），用浅色磨砂玻璃模拟"透明"观感。
func makeGlassGaugeIcon() -> CGImage {
    let s = 1024
    let c = ctx(s, s)
    let center = CGPoint(x: 512, y: 448)
    let radius: CGFloat = 300
    let stroke: CGFloat = 78  // 74 → 78：计量条加粗 5%（用户 2026-08-30）
    let startDeg: CGFloat = 205
    let sweepDeg: CGFloat = 230
    func angle(_ t: CGFloat) -> CGFloat { (startDeg - t * sweepDeg) * .pi / 180 }
    func point(_ t: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle(t)) * r, y: center.y + sin(angle(t)) * r)
    }
    func arcPath(_ t0: CGFloat, _ t1: CGFloat, r: CGFloat = radius) -> CGMutablePath {
        let p = CGMutablePath()
        p.addArc(center: center, radius: r, startAngle: angle(t0), endAngle: angle(t1), clockwise: true)
        return p
    }
    let needleT: CGFloat = 0.8
    let tip = point(needleT, radius - stroke / 2 - 38)
    let tail = CGPoint(x: center.x - cos(angle(needleT)) * 56, y: center.y - sin(angle(needleT)) * 56)
    let tickIn = point(1, radius - stroke / 2 - 26)
    let tickOut = point(1, radius + stroke / 2 + 26)

    let amber = rgb(1.00, 0.60, 0.12)
    let hotPink = rgb(1.00, 0.24, 0.51)
    let violet = rgb(0.48, 0.17, 0.98)

    // 1. 磨砂玻璃底：浅灰白斜向渐变 + 顶部更亮
    c.drawLinearGradient(
        iconGradient([rgb(0.97, 0.975, 0.99), rgb(0.90, 0.91, 0.95), rgb(0.86, 0.87, 0.92)], [0, 0.6, 1]),
        start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: []
    )
    // 底色里透出一点点炫光色，像玻璃后面有光
    c.saveGState()
    c.setBlendMode(.normal)
    c.drawRadialGradient(
        iconGradient([violet.copy(alpha: 0.10)!, violet.copy(alpha: 0)!], [0, 1]),
        startCenter: CGPoint(x: 180, y: 420), startRadius: 0,
        endCenter: CGPoint(x: 180, y: 420), endRadius: 520, options: []
    )
    c.drawRadialGradient(
        iconGradient([amber.copy(alpha: 0.12)!, amber.copy(alpha: 0)!], [0, 1]),
        startCenter: CGPoint(x: 860, y: 420), startRadius: 0,
        endCenter: CGPoint(x: 860, y: 420), endRadius: 520, options: []
    )
    c.drawRadialGradient(
        iconGradient([hotPink.copy(alpha: 0.10)!, hotPink.copy(alpha: 0)!], [0, 1]),
        startCenter: CGPoint(x: 512, y: 760), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 760), endRadius: 520, options: []
    )
    c.restoreGState()
    // 磨砂颗粒：细密随机白/灰点，极低透明度
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rnd() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) & 0xFFFF) / 65535
    }
    c.saveGState()
    for _ in 0..<60000 {
        let x = rnd() * 1024, y = rnd() * 1024
        c.setFillColor(rnd() < 0.5 ? rgb(1, 1, 1, 0.09) : rgb(0, 0, 0.1, 0.03))
        c.fill(CGRect(x: x, y: y, width: 1.4, height: 1.4))
    }
    c.restoreGState()
    // 内侧高光边（玻璃厚度感）
    c.saveGState()
    c.setStrokeColor(rgb(1, 1, 1, 0.75))
    c.setLineWidth(6)
    c.stroke(CGRect(x: 3, y: 3, width: 1018, height: 1018))
    c.restoreGState()

    // 2. 表盘：炫光色玻璃条。先在下方铺一层彩色柔光（像光透过玻璃落在磨砂面上）
    c.saveGState()
    c.setLineCap(.round)
    c.setLineWidth(stroke + 30)
    for (t0, t1, col) in [(0.0, 0.38, violet), (0.33, 0.72, hotPink), (0.67, 1.0, amber)] as [(CGFloat, CGFloat, CGColor)] {
        c.setShadow(offset: CGSize(width: 0, height: -14), blur: 70, color: col.copy(alpha: 0.6)!)
        c.setStrokeColor(col.copy(alpha: 0.0001)!)
        c.addPath(arcPath(t0, t1))
        c.strokePath()
    }
    c.restoreGState()

    // 玻璃管本体（全部用渐变，无分段叠加，不会出现网格接缝）：
    //   1) 色相层：沿弧 60 段不透明色画进透明图层，整层 0.86 合成 → 半透明管体，透出磨砂底
    //   2) 截面层：以表心为圆心的径向渐变，内沿/外沿偏暗偏实、中心偏亮偏白（菲涅尔）
    //   3) 镜面高光：外上沿一条柔和白带（径向渐变，中心最亮向两侧渐隐）
    //   4) 极细半透明轮廓线 = 玻璃折射边
    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    let vio: (CGFloat, CGFloat, CGFloat) = (0.50, 0.22, 0.98)
    let pnk: (CGFloat, CGFloat, CGFloat) = (1.00, 0.30, 0.55)
    let amb: (CGFloat, CGFloat, CGFloat) = (1.00, 0.56, 0.12)
    func hue(_ t: CGFloat) -> CGColor {
        if t < 0.45 {
            let k = t / 0.45
            return rgb(lerp(vio.0, pnk.0, k), lerp(vio.1, pnk.1, k), lerp(vio.2, pnk.2, k))
        }
        let k = (t - 0.45) / 0.55
        return rgb(lerp(pnk.0, amb.0, k), lerp(pnk.1, amb.1, k), lerp(pnk.2, amb.2, k))
    }
    let tubeShape = arcPath(0, 1).copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let rIn = radius - stroke / 2
    let rOut = radius + stroke / 2

    c.saveGState()
    c.setAlpha(0.86)
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.addPath(tubeShape)
    c.clip()
    // 1) 色相层
    c.setLineCap(.butt)
    c.setLineWidth(stroke + 2)
    let segs = 60
    for i in 0..<segs {
        let t0 = CGFloat(i) / CGFloat(segs)
        let t1 = CGFloat(i + 1) / CGFloat(segs) + 0.004
        c.setStrokeColor(hue((t0 + t1) / 2))
        c.addPath(arcPath(t0, min(t1, 1)))
        c.strokePath()
    }
    c.setFillColor(hue(0))
    var cp = point(0, radius)
    c.fillEllipse(in: CGRect(x: cp.x - stroke / 2, y: cp.y - stroke / 2, width: stroke, height: stroke))
    c.setFillColor(hue(1))
    cp = point(1, radius)
    c.fillEllipse(in: CGRect(x: cp.x - stroke / 2, y: cp.y - stroke / 2, width: stroke, height: stroke))
    // 2) 截面层：内沿暗 → 中心亮白 → 外沿暗
    c.drawRadialGradient(
        iconGradient(
            [rgb(0.18, 0.06, 0.28, 0.34), rgb(0.18, 0.06, 0.28, 0.10), rgb(1, 1, 1, 0.30),
             rgb(1, 1, 1, 0.08), rgb(0.18, 0.06, 0.28, 0.30)],
            [0, 0.18, 0.46, 0.78, 1]
        ),
        startCenter: center, startRadius: rIn, endCenter: center, endRadius: rOut, options: []
    )
    // 3) 镜面高光：外上沿柔和白带（r ≈ 外沿向内 0.26 处，上下渐隐）
    c.drawRadialGradient(
        iconGradient(
            [rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.55), rgb(1, 1, 1, 0.85), rgb(1, 1, 1, 0.45), rgb(1, 1, 1, 0)],
            [0.62, 0.70, 0.76, 0.82, 0.90]
        ),
        startCenter: center, startRadius: rIn, endCenter: center, endRadius: rOut, options: []
    )
    // 高光在弧顶更强：再叠一段，用弧段裁剪
    c.saveGState()
    c.addPath(arcPath(0.30, 0.70).copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10))
    c.clip()
    c.drawRadialGradient(
        iconGradient([rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.55), rgb(1, 1, 1, 0)], [0.64, 0.76, 0.88]),
        startCenter: center, startRadius: rIn, endCenter: center, endRadius: rOut, options: []
    )
    c.restoreGState()
    c.endTransparencyLayer()
    c.restoreGState()

    // 4) 折射边：极细半透明深色轮廓
    c.saveGState()
    c.addPath(tubeShape)
    c.setStrokeColor(rgb(0.30, 0.16, 0.42, 0.28))
    c.setLineWidth(2.5)
    c.strokePath()
    c.restoreGState()

    // 3. 红线刻度与指针：白玻璃，带淡彩投影
    c.saveGState()
    c.setLineCap(.round)
    c.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: amber.copy(alpha: 0.55)!)
    c.setStrokeColor(rgb(1, 1, 1, 0.95))
    c.setLineWidth(20)
    c.move(to: tickIn); c.addLine(to: tickOut); c.strokePath()
    c.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: hotPink.copy(alpha: 0.45)!)
    c.setLineWidth(26)
    c.move(to: tail); c.addLine(to: tip); c.strokePath()
    c.setFillColor(rgb(1, 1, 1, 0.95))
    c.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))
    c.restoreGState()
    // 指针深色轴心（玻璃下的暗点）
    c.setFillColor(rgb(0.22, 0.20, 0.30, 0.9))
    c.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
    // 指针上的细高光
    c.saveGState()
    c.setStrokeColor(rgb(1, 1, 1, 0.9))
    c.setLineWidth(5)
    c.setLineCap(.round)
    c.move(to: CGPoint(x: tail.x, y: tail.y + 7)); c.addLine(to: CGPoint(x: tip.x, y: tip.y + 7)); c.strokePath()
    c.restoreGState()
    return c.makeImage()!
}

// MARK: 变体二：熔金水位（保留备选。整枚图标是额度池，白热波线即水位）

/// 波形液面：surfaceY 处的正弦波。asLine=false 时闭合到画布底部。
private func iconWave(surfaceY: CGFloat, amplitude: CGFloat, phase: CGFloat, asLine: Bool) -> CGMutablePath {
    let p = CGMutablePath()
    let steps = 96
    if !asLine {
        p.move(to: CGPoint(x: 0, y: 0))
    }
    for i in 0...steps {
        let x = CGFloat(i) / CGFloat(steps) * 1024
        let y = surfaceY + sin(phase + x / 1024 * .pi * 2.2) * amplitude
        if i == 0, asLine {
            p.move(to: CGPoint(x: x, y: y))
        } else {
            p.addLine(to: CGPoint(x: x, y: y))
        }
    }
    if !asLine {
        p.addLine(to: CGPoint(x: 1024, y: 0))
        p.closeSubpath()
    }
    return p
}

func makeMoltenIcon(_ mode: IconMode) -> CGImage {
    let s = 1024
    let c = ctx(s, s)
    let surfaceY: CGFloat = 560
    let amp: CGFloat = 30
    let phase: CGFloat = .pi * 0.3
    let body = iconWave(surfaceY: surfaceY, amplitude: amp, phase: phase, asLine: false)
    let line = iconWave(surfaceY: surfaceY, amplitude: amp, phase: phase, asLine: true)

    if mode == .tinted {
        // 灰阶剪影：白波线 + 半透明液面，交给系统着色
        c.clear(CGRect(x: 0, y: 0, width: s, height: s))
        c.saveGState()
        c.addPath(body)
        c.clip()
        c.setFillColor(rgb(1, 1, 1, 0.45))
        c.fill(CGRect(x: 0, y: 0, width: s, height: s))
        c.restoreGState()
        c.setStrokeColor(rgb(1, 1, 1))
        c.setLineWidth(26)
        c.setLineCap(.round)
        c.addPath(line)
        c.strokePath()
        return c.makeImage()!
    }

    let inkViolet = rgb(0.045, 0.04, 0.09)
    let amber = rgb(1.00, 0.60, 0.12)
    let hotPink = rgb(1.00, 0.24, 0.51)
    let violet = rgb(0.48, 0.17, 0.98)
    let hotCore = rgb(1.00, 0.95, 0.88)

    c.setFillColor(inkViolet)
    c.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // 顶部两角微弱极光
    c.saveGState()
    c.setBlendMode(.plusLighter)
    c.drawRadialGradient(
        iconGradient([violet.copy(alpha: 0.16)!, violet.copy(alpha: 0)!], [0, 1]),
        startCenter: CGPoint(x: 150, y: 960), startRadius: 0,
        endCenter: CGPoint(x: 150, y: 960), endRadius: 560, options: []
    )
    c.drawRadialGradient(
        iconGradient([hotPink.copy(alpha: 0.12)!, hotPink.copy(alpha: 0)!], [0, 1]),
        startCenter: CGPoint(x: 900, y: 900), startRadius: 0,
        endCenter: CGPoint(x: 900, y: 900), endRadius: 520, options: []
    )
    c.restoreGState()

    // 熔岩：紫（深处）→ 品红 → 琥珀（近液面）
    c.saveGState()
    c.addPath(body)
    c.clip()
    c.drawLinearGradient(
        iconGradient([violet, hotPink, amber], [0, 0.55, 1]),
        start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: surfaceY + amp),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    c.restoreGState()

    // 液面白热线：琥珀光晕 + 白热核心
    c.saveGState()
    c.setLineCap(.round)
    c.setShadow(offset: .zero, blur: 90, color: amber.copy(alpha: 0.9)!)
    c.setStrokeColor(amber)
    c.setLineWidth(18)
    c.addPath(line)
    c.strokePath()
    c.setShadow(offset: .zero, blur: 28, color: hotCore.copy(alpha: 0.9)!)
    c.setStrokeColor(hotCore)
    c.setLineWidth(10)
    c.addPath(line)
    c.strokePath()
    c.restoreGState()

    // 三颗光点（多账号暗示）
    let orbs: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: 300, y: 700), 16, 0.45),
        (CGPoint(x: 540, y: 790), 22, 0.7),
        (CGPoint(x: 760, y: 680), 13, 0.35),
    ]
    c.saveGState()
    for (pt, r, a) in orbs {
        c.setShadow(offset: .zero, blur: 40, color: amber.copy(alpha: a)!)
        c.setFillColor(hotCore.copy(alpha: a + 0.25)!)
        c.fillEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
    }
    c.restoreGState()
    return c.makeImage()!
}

// MARK: 变体一：霓虹转速表（默认）

func makeGaugeIcon(_ mode: IconMode) -> CGImage {
    let s = 1024
    let c = ctx(s, s)

    let center = CGPoint(x: 512, y: 448)
    let radius: CGFloat = 300
    let stroke: CGFloat = 78  // 74 → 78：计量条加粗 5%（用户 2026-08-30）
    // 表盘：左下 205° 顺时针扫到右下 -25°，共 230°
    let startDeg: CGFloat = 205
    let sweepDeg: CGFloat = 230
    func angle(_ t: CGFloat) -> CGFloat { (startDeg - t * sweepDeg) * .pi / 180 }
    func point(_ t: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle(t)) * r, y: center.y + sin(angle(t)) * r)
    }
    func arcPath(_ t0: CGFloat, _ t1: CGFloat) -> CGMutablePath {
        let p = CGMutablePath()
        p.addArc(
            center: center, radius: radius,
            startAngle: angle(t0), endAngle: angle(t1), clockwise: true
        )
        return p
    }

    // 指针几何：指向 0.8（琥珀区、将进红线）
    let needleT: CGFloat = 0.8
    let tip = point(needleT, radius - stroke / 2 - 38)
    let tail = CGPoint(
        x: center.x - cos(angle(needleT)) * 56,
        y: center.y - sin(angle(needleT)) * 56
    )
    // 红线刻度：末端径向短杠
    let tickIn = point(1, radius - stroke / 2 - 26)
    let tickOut = point(1, radius + stroke / 2 + 26)

    if mode == .tinted {
        // 灰阶剪影：半透明白色带 + 实白指针/轴心/红线刻度，交给系统着色
        c.clear(CGRect(x: 0, y: 0, width: s, height: s))
        c.setLineCap(.round)
        c.setLineWidth(stroke)
        c.setStrokeColor(rgb(1, 1, 1, 0.5))
        c.addPath(arcPath(0, 1))
        c.strokePath()
        c.setStrokeColor(rgb(1, 1, 1))
        c.setLineWidth(20)
        c.move(to: tickIn)
        c.addLine(to: tickOut)
        c.strokePath()
        c.setLineWidth(26)
        c.move(to: tail)
        c.addLine(to: tip)
        c.strokePath()
        c.setFillColor(rgb(1, 1, 1))
        c.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))
        c.setFillColor(rgb(1, 1, 1, 0))
        c.setBlendMode(.clear)
        c.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
        c.setBlendMode(.normal)
        return c.makeImage()!
    }

    let inkViolet = mode == .clear ? rgb(0, 0, 0) : rgb(0.045, 0.04, 0.09)
    let amber = rgb(1.00, 0.60, 0.12)
    let hotPink = rgb(1.00, 0.24, 0.51)
    let violet = rgb(0.48, 0.17, 0.98)
    let hotCore = rgb(1.00, 0.95, 0.88)

    c.setFillColor(inkViolet)
    c.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // 顶部两角微弱极光（clear 模式不画环境光）
    if mode != .clear {
    c.saveGState()
    c.setBlendMode(.plusLighter)
    c.drawRadialGradient(
        iconGradient([violet.copy(alpha: 0.16)!, violet.copy(alpha: 0)!], [0, 1]),
        startCenter: CGPoint(x: 150, y: 960), startRadius: 0,
        endCenter: CGPoint(x: 150, y: 960), endRadius: 560, options: []
    )
    c.drawRadialGradient(
        iconGradient([hotPink.copy(alpha: 0.12)!, hotPink.copy(alpha: 0)!], [0, 1]),
        startCenter: CGPoint(x: 900, y: 900), startRadius: 0,
        endCenter: CGPoint(x: 900, y: 900), endRadius: 520, options: []
    )
    c.restoreGState()

    // 灯光落地：表盘下方一滩椭圆光池
    c.saveGState()
    c.translateBy(x: 512, y: 150)
    c.scaleBy(x: 1.0, y: 0.30)
    c.drawRadialGradient(
        iconGradient([amber.copy(alpha: 0.20)!, amber.copy(alpha: 0)!], [0, 1]),
        startCenter: .zero, startRadius: 0,
        endCenter: .zero, endRadius: 430, options: []
    )
    c.restoreGState()
    }

    // 分段光晕：左段紫、中段品红、右段琥珀（真实弧段，无接缝）
    c.saveGState()
    c.setLineCap(.round)
    c.setLineWidth(stroke)
    c.setShadow(offset: .zero, blur: 100, color: violet.copy(alpha: 0.5)!)
    c.setStrokeColor(violet.copy(alpha: 0.8)!)
    c.addPath(arcPath(0, 0.38))
    c.strokePath()
    c.setShadow(offset: .zero, blur: 100, color: hotPink.copy(alpha: 0.5)!)
    c.setStrokeColor(hotPink.copy(alpha: 0.8)!)
    c.addPath(arcPath(0.33, 0.72))
    c.strokePath()
    c.setShadow(offset: .zero, blur: 90, color: amber.copy(alpha: 0.8)!)
    c.setStrokeColor(amber)
    c.addPath(arcPath(0.67, 1.0))
    c.strokePath()
    c.restoreGState()

    // 表盘本体：60 段逐段插值，紫 → 品红 → 琥珀（白热留给红线刻度）
    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    func mix(_ c0: (CGFloat, CGFloat, CGFloat), _ c1: (CGFloat, CGFloat, CGFloat), _ t: CGFloat) -> CGColor {
        rgb(lerp(c0.0, c1.0, t), lerp(c0.1, c1.1, t), lerp(c0.2, c1.2, t))
    }
    let vio: (CGFloat, CGFloat, CGFloat) = (0.48, 0.17, 0.98)
    let pnk: (CGFloat, CGFloat, CGFloat) = (1.00, 0.24, 0.51)
    let amb: (CGFloat, CGFloat, CGFloat) = (1.00, 0.60, 0.12)
    func tone(_ t: CGFloat) -> CGColor {
        if t < 0.45 { return mix(vio, pnk, t / 0.45) }
        return mix(pnk, amb, (t - 0.45) / 0.55)
    }
    c.setLineCap(.butt)
    c.setLineWidth(stroke)
    let segs = 60
    for i in 0..<segs {
        let t0 = CGFloat(i) / CGFloat(segs)
        let t1 = CGFloat(i + 1) / CGFloat(segs) + 0.004  // 微量重叠防缝
        c.setStrokeColor(tone((t0 + t1) / 2))
        c.addPath(arcPath(t0, min(t1, 1)))
        c.strokePath()
    }
    // 两端圆头补帽
    c.setFillColor(tone(0))
    var cap = point(0, radius)
    c.fillEllipse(in: CGRect(x: cap.x - stroke / 2, y: cap.y - stroke / 2, width: stroke, height: stroke))
    c.setFillColor(tone(1))
    cap = point(1, radius)
    c.fillEllipse(in: CGRect(x: cap.x - stroke / 2, y: cap.y - stroke / 2, width: stroke, height: stroke))

    // 红线刻度：末端一枚白热短杠（上限记号）
    c.saveGState()
    c.setShadow(offset: .zero, blur: 34, color: hotCore.copy(alpha: 0.95)!)
    c.setStrokeColor(hotCore)
    c.setLineWidth(20)
    c.setLineCap(.round)
    c.move(to: tickIn)
    c.addLine(to: tickOut)
    c.strokePath()
    c.restoreGState()

    // 指针（白热发光 + 尾配重）与轴心
    c.saveGState()
    c.setLineCap(.round)
    c.setShadow(offset: .zero, blur: 46, color: amber.copy(alpha: 0.9)!)
    c.setStrokeColor(hotCore)
    c.setLineWidth(26)
    c.move(to: tail)
    c.addLine(to: tip)
    c.strokePath()
    c.setShadow(offset: .zero, blur: 30, color: hotPink.copy(alpha: 0.9)!)
    c.setFillColor(hotCore)
    c.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))
    c.restoreGState()
    c.setFillColor(inkViolet)
    c.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
    return c.makeImage()!
}

// MARK: - WeChat: two green bubbles

func makeWeChat() -> CGImage {
    let s = 256
    let c = ctx(s, s)
    c.clear(CGRect(x: 0, y: 0, width: s, height: s))
    let green = rgb(0.03, 0.76, 0.38)
    func bubble(_ rect: CGRect, tail: CGPoint) {
        c.setFillColor(green)
        c.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height * 0.48, cornerHeight: rect.height * 0.48, transform: nil))
        c.fillPath()
        c.move(to: CGPoint(x: tail.x - 10, y: tail.y + 8))
        c.addLine(to: tail)
        c.addLine(to: CGPoint(x: tail.x + 16, y: tail.y + 14))
        c.closePath()
        c.fillPath()
    }
    bubble(CGRect(x: 22, y: 38, width: 150, height: 112), tail: CGPoint(x: 40, y: 36))
    bubble(CGRect(x: 98, y: 108, width: 132, height: 100), tail: CGPoint(x: 214, y: 206))
    // eyes
    c.setFillColor(rgb(1, 1, 1))
    c.fillEllipse(in: CGRect(x: 62, y: 86, width: 18, height: 22))
    c.fillEllipse(in: CGRect(x: 100, y: 86, width: 18, height: 22))
    c.fillEllipse(in: CGRect(x: 136, y: 150, width: 16, height: 20))
    c.fillEllipse(in: CGRect(x: 170, y: 150, width: 16, height: 20))
    return c.makeImage()!
}

// MARK: - Moments: rainbow aperture

func makeMoments() -> CGImage {
    let s = 256
    let c = ctx(s, s)
    c.clear(CGRect(x: 0, y: 0, width: s, height: s))
    let colors: [CGColor] = [
        rgb(0.98, 0.78, 0.12),
        rgb(0.30, 0.82, 0.28),
        rgb(0.12, 0.72, 0.88),
        rgb(0.22, 0.42, 0.96),
        rgb(0.55, 0.28, 0.92),
        rgb(0.92, 0.22, 0.55),
        rgb(0.96, 0.28, 0.22),
        rgb(0.98, 0.52, 0.12),
    ]
    let center = CGPoint(x: 128, y: 128)
    let outer: CGFloat = 118
    let inner: CGFloat = 34
    for i in 0..<8 {
        let a0 = CGFloat(i) * .pi / 4 - .pi / 8
        let a1 = a0 + .pi / 4
        c.setFillColor(colors[i])
        c.move(to: CGPoint(x: center.x + cos(a0) * inner, y: center.y + sin(a0) * inner))
        c.addLine(to: CGPoint(x: center.x + cos(a0) * outer, y: center.y + sin(a0) * outer))
        c.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        c.addLine(to: CGPoint(x: center.x + cos(a1) * inner, y: center.y + sin(a1) * inner))
        c.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        c.closePath()
        c.fillPath()
    }
    return c.makeImage()!
}

func writeImageset(_ name: String, image: CGImage, filename: String) {
    let dir = root.appendingPathComponent("SharedUI/Assets.xcassets/\(name).imageset")
    writePNG(image, to: dir.appendingPathComponent(filename))
    let json = """
    {
      "images" : [{ "filename" : "\(filename)", "idiom" : "universal" }],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try! json.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

let darkIcon = makeAppIcon(.dark)
let tintedIcon = makeAppIcon(.tinted)
let clearIcon = makeAppIcon(.glass)

// 替换图标「磨砂玻璃」（AppIconClear 资源名保留）：单独一个 appiconset，project.yml 里登记 ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES
let clearIconDir = root.appendingPathComponent("App/Assets.xcassets/AppIconClear.appiconset")
writePNG(clearIcon, to: clearIconDir.appendingPathComponent("AppIconClear.png"))
try! """
{
  "images" : [
    {
      "filename" : "AppIconClear.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: clearIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
// 图标选择页的缩略图：目录编译后的替换图标无法按名加载，另放一份 App 内 imageset
let clearPreviewDir = root.appendingPathComponent("App/Assets.xcassets/AppIconClearPreview.imageset")
writePNG(clearIcon, to: clearPreviewDir.appendingPathComponent("AppIconClearPreview.png"))
try! """
{
  "images" : [{ "filename" : "AppIconClearPreview.png", "idiom" : "universal" }],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: clearPreviewDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// iPhone 图标：Any 与 Dark 都是深底（恒深色）；Tinted 交给系统着色。
let appIconDir = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
writePNG(darkIcon, to: appIconDir.appendingPathComponent("AppIcon.png"))
writePNG(darkIcon, to: appIconDir.appendingPathComponent("AppIcon-dark.png"))
writePNG(tintedIcon, to: appIconDir.appendingPathComponent("AppIcon-tinted.png"))
let appIconJSON = """
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [{ "appearance" : "luminosity", "value" : "dark" }],
      "filename" : "AppIcon-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [{ "appearance" : "luminosity", "value" : "tinted" }],
      "filename" : "AppIcon-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! appIconJSON.write(
    to: appIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
)

// 手表不支持外观变体，表盘环境本就偏黑：恒用深色版。
writePNG(darkIcon, to: root.appendingPathComponent("Watch/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
// 分享长图的品牌位画在白卡上：用深色版最醒目。
writePNG(darkIcon, to: root.appendingPathComponent("SharedUI/Assets.xcassets/ShareAppIcon.imageset/AppIcon.png"))
// LogoWeChat / LogoMoments 用官方原图（SharedUI/Assets），不要用几何草稿覆盖。
