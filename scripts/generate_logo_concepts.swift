#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

/// 在 docs/logo/ 输出「炫酷」方向稿。
/// 参考结论（2026 图标趋势 + iOS 26 Liquid Glass）：
/// 深底优先、霓虹光晕（亮核心 + 外发光）、同类色渐变（橙→粉→紫）、单一大形、剪影要强。

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = root.appendingPathComponent("docs/logo")

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        fatalError("dest")
    }
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

// 色板：墨紫底 + 琥珀→品红→紫的同类色带
let inkViolet = rgb(0.045, 0.04, 0.09)
let amber = rgb(1.00, 0.60, 0.12)
let hotPink = rgb(1.00, 0.24, 0.51)
let violet = rgb(0.48, 0.17, 0.98)
let hotCore = rgb(1.00, 0.95, 0.88)   // 白热核心

let colorSpace = CGColorSpaceCreateDeviceRGB()

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func fillBase(_ c: CGContext) {
    c.setFillColor(inkViolet)
    c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
}

/// 顶部两角的微弱极光，给深底一点氛围（透明度极低，不抢主体）。
func auroraHints(_ c: CGContext) {
    c.saveGState()
    c.setBlendMode(.plusLighter)
    let leftGlow = gradient([violet.copy(alpha: 0.16)!, violet.copy(alpha: 0)!], [0, 1])
    c.drawRadialGradient(
        leftGlow, startCenter: CGPoint(x: 150, y: 960), startRadius: 0,
        endCenter: CGPoint(x: 150, y: 960), endRadius: 560, options: []
    )
    let rightGlow = gradient([hotPink.copy(alpha: 0.12)!, hotPink.copy(alpha: 0)!], [0, 1])
    c.drawRadialGradient(
        rightGlow, startCenter: CGPoint(x: 900, y: 900), startRadius: 0,
        endCenter: CGPoint(x: 900, y: 900), endRadius: 520, options: []
    )
    c.restoreGState()
}

/// 波形液面路径：surfaceY 处的正弦波，闭合到画布底部。
func wavePath(surfaceY: CGFloat, amplitude: CGFloat, phase: CGFloat) -> CGMutablePath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: 0))
    p.addLine(to: CGPoint(x: 0, y: surfaceY + sin(phase) * amplitude))
    let steps = 96
    for i in 1...steps {
        let x = CGFloat(i) / CGFloat(steps) * 1024
        let y = surfaceY + sin(phase + x / 1024 * .pi * 2.2) * amplitude
        p.addLine(to: CGPoint(x: x, y: y))
    }
    p.addLine(to: CGPoint(x: 1024, y: 0))
    p.closeSubpath()
    return p
}

/// 只取波形的表面线（不闭合），用于描白热边。
func waveLine(surfaceY: CGFloat, amplitude: CGFloat, phase: CGFloat) -> CGMutablePath {
    let p = CGMutablePath()
    let steps = 96
    for i in 0...steps {
        let x = CGFloat(i) / CGFloat(steps) * 1024
        let y = surfaceY + sin(phase + x / 1024 * .pi * 2.2) * amplitude
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    return p
}

// MARK: - A. 熔金水位：额度是一池熔岩，液面白热发光

func makeMolten() -> CGImage {
    let c = ctx(1024, 1024)
    fillBase(c)
    auroraHints(c)

    let surfaceY: CGFloat = 560   // 液面约在 55%（CG 原点在下）
    let amp: CGFloat = 30
    let phase: CGFloat = .pi * 0.3

    // 液体：紫（深处）→ 品红 → 琥珀（近液面），越浅越烫
    let body = wavePath(surfaceY: surfaceY, amplitude: amp, phase: phase)
    c.saveGState()
    c.addPath(body)
    c.clip()
    c.drawLinearGradient(
        gradient([violet, hotPink, amber], [0, 0.55, 1]),
        start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: surfaceY + amp),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    c.restoreGState()

    // 液面白热线：两层光晕 + 亮核心
    let line = waveLine(surfaceY: surfaceY, amplitude: amp, phase: phase)
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

    // 三颗上升的光点（多账号暗示）：越接近液面越亮
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

// MARK: - B. 霓虹 U（优化版）：结构不动，灯芯只点亮到 5/8 水位
// U 型连通管本身就是量表：两臂液面等高。白热灯芯 = 已用水位，
// 上段是仍通电但未「烧白」的色玻璃；液面处两臂各一枚亮点（弯月面）。

func makeNeonU() -> CGImage {
    let c = ctx(1024, 1024)
    fillBase(c)
    auroraHints(c)

    let stroke: CGFloat = 88
    let midR: CGFloat = 224
    let center = CGPoint(x: 512, y: 478)
    let topY: CGFloat = 800
    let bottomY = center.y - midR                    // 管底中轴
    let levelY = bottomY + (topY - bottomY) * 0.625  // 5/8 水位

    let u = CGMutablePath()
    u.move(to: CGPoint(x: center.x - midR, y: topY))
    u.addLine(to: CGPoint(x: center.x - midR, y: center.y))
    u.addArc(center: center, radius: midR, startAngle: .pi, endAngle: 0, clockwise: false)
    u.addLine(to: CGPoint(x: center.x + midR, y: topY))

    // 灯光落地：U 底下方一滩椭圆光池
    c.saveGState()
    c.translateBy(x: 512, y: 168)
    c.scaleBy(x: 1.0, y: 0.30)
    c.drawRadialGradient(
        gradient([amber.copy(alpha: 0.22)!, amber.copy(alpha: 0)!], [0, 1]),
        startCenter: .zero, startRadius: 0,
        endCenter: .zero, endRadius: 440, options: []
    )
    c.restoreGState()

    // 分色光晕：按真实路径分段发光（矩形裁剪会在背景上留硬接缝）。
    // 上段两根立管溢紫光，下段 U 碗溢品红/琥珀光，两段小幅重叠自然过渡。
    let stems = CGMutablePath()
    stems.move(to: CGPoint(x: center.x - midR, y: center.y + 30))
    stems.addLine(to: CGPoint(x: center.x - midR, y: topY))
    stems.move(to: CGPoint(x: center.x + midR, y: center.y + 30))
    stems.addLine(to: CGPoint(x: center.x + midR, y: topY))
    let bowl = CGMutablePath()
    bowl.move(to: CGPoint(x: center.x - midR, y: center.y + 70))
    bowl.addLine(to: CGPoint(x: center.x - midR, y: center.y))
    bowl.addArc(center: center, radius: midR, startAngle: .pi, endAngle: 0, clockwise: false)
    bowl.addLine(to: CGPoint(x: center.x + midR, y: center.y + 70))

    c.saveGState()
    c.setLineCap(.round)
    c.setLineWidth(stroke)
    c.setShadow(offset: .zero, blur: 110, color: violet.copy(alpha: 0.50)!)
    c.setStrokeColor(violet.copy(alpha: 0.85)!)
    c.addPath(stems)
    c.strokePath()
    c.setShadow(offset: .zero, blur: 110, color: hotPink.copy(alpha: 0.55)!)
    c.setStrokeColor(hotPink.copy(alpha: 0.85)!)
    c.addPath(bowl)
    c.strokePath()
    c.setShadow(offset: .zero, blur: 42, color: amber.copy(alpha: 0.85)!)
    c.setStrokeColor(amber)
    c.addPath(bowl)
    c.strokePath()
    c.restoreGState()

    // 灯管本体：底琥珀 → 中品红 → 顶紫
    c.saveGState()
    c.addPath(u)
    c.setLineWidth(stroke)
    c.setLineCap(.round)
    c.replacePathWithStrokedPath()
    c.clip()
    c.drawLinearGradient(
        gradient([amber, hotPink, violet], [0, 0.55, 1]),
        start: CGPoint(x: 512, y: bottomY - stroke / 2), end: CGPoint(x: 512, y: topY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    c.restoreGState()

    // 白热灯芯：真实局部路径，只烧到水位线（已用 5/8），圆头收口即弯月面
    let core = CGMutablePath()
    core.move(to: CGPoint(x: center.x - midR, y: levelY))
    core.addLine(to: CGPoint(x: center.x - midR, y: center.y))
    core.addArc(center: center, radius: midR, startAngle: .pi, endAngle: 0, clockwise: false)
    core.addLine(to: CGPoint(x: center.x + midR, y: levelY))
    c.saveGState()
    c.setLineCap(.round)
    c.setLineWidth(20)
    c.setShadow(offset: .zero, blur: 20, color: hotCore.copy(alpha: 0.9)!)
    c.setStrokeColor(hotCore.copy(alpha: 0.95)!)
    c.addPath(core)
    c.strokePath()
    c.restoreGState()

    // 弯月面：两臂液面处各一枚发光亮点，收掉灯芯的切口
    for x in [center.x - midR, center.x + midR] {
        c.saveGState()
        c.setShadow(offset: .zero, blur: 36, color: hotCore.copy(alpha: 0.95)!)
        c.setFillColor(hotCore)
        let w = stroke * 0.76
        c.addPath(CGPath(
            roundedRect: CGRect(x: x - w / 2, y: levelY - 11, width: w, height: 22),
            cornerWidth: 11, cornerHeight: 11, transform: nil
        ))
        c.fillPath()
        c.restoreGState()
    }
    return c.makeImage()!
}

// MARK: - C. 双色斜波：对照组，紫 / 琥珀双域 + 白线分界（无光晕）

func makeDuotone() -> CGImage {
    let c = ctx(1024, 1024)
    // 上域：深紫
    c.setFillColor(rgb(0.13, 0.08, 0.26))
    c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let surfaceY: CGFloat = 540
    let amp: CGFloat = 46
    let phase: CGFloat = .pi * 0.8
    // 下域：琥珀→品红
    let body = wavePath(surfaceY: surfaceY, amplitude: amp, phase: phase)
    c.saveGState()
    c.addPath(body)
    c.clip()
    c.drawLinearGradient(
        gradient([hotPink, amber], [0, 1]),
        start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: surfaceY + amp),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    c.restoreGState()
    // 分界白线
    let line = waveLine(surfaceY: surfaceY, amplitude: amp, phase: phase)
    c.setStrokeColor(hotCore)
    c.setLineWidth(16)
    c.setLineCap(.round)
    c.addPath(line)
    c.strokePath()
    return c.makeImage()!
}

func iosMask(_ image: CGImage) -> CGImage {
    let s = image.width
    let c = ctx(s, s)
    let radius = CGFloat(s) * 0.2237
    c.addPath(CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    ))
    c.clip()
    c.draw(image, in: CGRect(x: 0, y: 0, width: s, height: s))
    return c.makeImage()!
}

func makeSheet(_ images: [CGImage]) -> CGImage {
    let tile = 1024
    let gap = 48
    let w = tile * images.count + gap * (images.count + 1)
    let h = tile + gap * 2
    let c = ctx(w, h)
    c.setFillColor(rgb(0.85, 0.86, 0.88))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for (i, image) in images.enumerated() {
        let x = gap + i * (tile + gap)
        c.draw(iosMask(image), in: CGRect(x: x, y: gap, width: tile, height: tile))
    }
    return c.makeImage()!
}

// MARK: - D. 霓虹转速表：指针快进红线区，「快到上限」不言自明

func makeGauge() -> CGImage {
    let c = ctx(1024, 1024)
    fillBase(c)
    auroraHints(c)

    let center = CGPoint(x: 512, y: 448)
    let radius: CGFloat = 300
    let stroke: CGFloat = 74
    // 表盘：左下 205° 顺时针扫到右下 -25°，共 230°
    let startDeg: CGFloat = 205
    let sweepDeg: CGFloat = 230
    func angle(_ t: CGFloat) -> CGFloat { (startDeg - t * sweepDeg) * .pi / 180 }
    func point(_ t: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle(t)) * r, y: center.y + sin(angle(t)) * r)
    }

    // 灯光落地
    c.saveGState()
    c.translateBy(x: 512, y: 150)
    c.scaleBy(x: 1.0, y: 0.30)
    c.drawRadialGradient(
        gradient([amber.copy(alpha: 0.20)!, amber.copy(alpha: 0)!], [0, 1]),
        startCenter: .zero, startRadius: 0,
        endCenter: .zero, endRadius: 430, options: []
    )
    c.restoreGState()

    // 分段光晕：左段紫、中段品红、右段琥珀（真实弧段，无接缝）
    func arcPath(_ t0: CGFloat, _ t1: CGFloat) -> CGMutablePath {
        let p = CGMutablePath()
        p.addArc(
            center: center, radius: radius,
            startAngle: angle(t0), endAngle: angle(t1), clockwise: true
        )
        return p
    }
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

    // 表盘本体：60 段逐段插值，紫 → 品红 → 琥珀 → 白热（末端红线区）
    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    func mix(_ c0: (CGFloat, CGFloat, CGFloat), _ c1: (CGFloat, CGFloat, CGFloat), _ t: CGFloat) -> CGColor {
        rgb(lerp(c0.0, c1.0, t), lerp(c0.1, c1.1, t), lerp(c0.2, c1.2, t))
    }
    let vio: (CGFloat, CGFloat, CGFloat) = (0.48, 0.17, 0.98)
    let pnk: (CGFloat, CGFloat, CGFloat) = (1.00, 0.24, 0.51)
    let amb: (CGFloat, CGFloat, CGFloat) = (1.00, 0.60, 0.12)
    // 色带只走紫→品红→琥珀；白热留给红线刻度（白上叠白会糊）
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

    // 红线终点刻度：末端一枚白热短杠（径向），上限记号
    c.saveGState()
    c.setShadow(offset: .zero, blur: 34, color: hotCore.copy(alpha: 0.95)!)
    c.setStrokeColor(hotCore)
    c.setLineWidth(20)
    c.setLineCap(.round)
    let tickIn = point(1, radius - stroke / 2 - 26)
    let tickOut = point(1, radius + stroke / 2 + 26)
    c.move(to: tickIn)
    c.addLine(to: tickOut)
    c.strokePath()
    c.restoreGState()

    // 指针：指向 0.8（琥珀区、将进红线），白热发光 + 尾配重
    let needleT: CGFloat = 0.8
    let tip = point(needleT, radius - stroke / 2 - 38)
    let tail = CGPoint(
        x: center.x - cos(angle(needleT)) * 56,
        y: center.y - sin(angle(needleT)) * 56
    )
    c.saveGState()
    c.setLineCap(.round)
    c.setShadow(offset: .zero, blur: 46, color: amber.copy(alpha: 0.9)!)
    c.setStrokeColor(hotCore)
    c.setLineWidth(26)
    c.move(to: tail)
    c.addLine(to: tip)
    c.strokePath()
    // 轴心
    c.setShadow(offset: .zero, blur: 30, color: hotPink.copy(alpha: 0.9)!)
    c.setFillColor(hotCore)
    c.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))
    c.restoreGState()
    c.setFillColor(inkViolet)
    c.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
    return c.makeImage()!
}

let molten = makeMolten()
let neonU = makeNeonU()
let duotone = makeDuotone()
let gauge = makeGauge()

writePNG(molten, to: outDir.appendingPathComponent("cool-a-molten.png"))
writePNG(neonU, to: outDir.appendingPathComponent("cool-b-neon-u.png"))
writePNG(duotone, to: outDir.appendingPathComponent("cool-c-duotone.png"))
writePNG(gauge, to: outDir.appendingPathComponent("cool-d-gauge.png"))
writePNG(makeSheet([gauge, neonU, molten]), to: outDir.appendingPathComponent("logo-sheet.png"))
