// 化形 — macOS 图标候选生成器（v2）
//
// 6 个刻意拉开差异的风格方向，供选择用；本脚本只产出候选，不决定采用哪一个。
//
// Apple HIG 约定：
//   · 1024×1024 全幅不透明画布，**不自行加圆角**（系统统一套 squircle 蒙版）
//   · 主体居中，四周留约 10% 安全边距（图形控制在 ~824×824 内）
//   · 单一焦点、粗笔画、无小字，保证 16/32px 仍可辨识
//   · 输出 PNG 再由 build-icns.sh 生成 10 个尺寸的 .icns
//
// 用法：swift generate.swift <输出目录>

import AppKit
import CoreGraphics
import CoreText
import Foundation

let S: CGFloat = 1024
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

func transparent(_ c: CGColor) -> CGColor {
    let v = c.components ?? [1, 1, 1, 1]
    return CGColor(red: v[0], green: v[1], blue: v[2], alpha: 0)
}

func newCanvas() -> (CGContext, NSBitmapImageRep) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // 翻转为设计习惯的左上原点；注意阴影 offset 的 y 需取负值才朝视觉下方
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return (ctx, rep)
}

func linear(_ ctx: CGContext, _ colors: [CGColor],
            from: CGPoint = .zero, to: CGPoint? = nil) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: from, end: to ?? CGPoint(x: S, y: S), options: [])
}

func glow(_ ctx: CGContext, at: CGPoint, radius: CGFloat, alpha: CGFloat = 0.14) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(255, 255, 255, alpha), rgb(255, 255, 255, 0)] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: at, startRadius: 0,
                           endCenter: at, endRadius: radius, options: [])
}

func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

func triangle(_ ctx: CGContext, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ color: CGColor) {
    let p = CGMutablePath()
    p.move(to: p1); p.addLine(to: p2); p.addLine(to: p3); p.closeSubpath()
    ctx.setFillColor(color); ctx.addPath(p); ctx.fillPath()
}

/// 把渐变限制在路径内部（用于渐变形状的填充）。
func fillPathGradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor],
                      from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    linear(ctx, colors, from: from, to: to)
    ctx.restoreGState()
}

/// 用 CoreText 绘制单个汉字；坐标系临时还原为左下原点。
func glyph(_ ctx: CGContext, _ text: String, size: CGFloat, color: CGColor,
           fontName: String = "PingFangSC-Semibold", offset: CGPoint = .zero) {
    ctx.saveGState()
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 0, y: -S)
    let font = NSFont(name: fontName, size: size)
        ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color) ?? NSColor.white
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attrs))
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(
        x: (S - b.width) / 2 - b.origin.x + offset.x,
        y: (S - b.height) / 2 - b.origin.y + offset.y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func save(_ rep: NSBitmapImageRep, _ name: String) throws {
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: (outDir as NSString).appendingPathComponent(name)))
}

// MARK: - 1 墨印：朱砂印章 + 浮雕「化」字（东方 / 字形）

func icon1() throws {
    let (ctx, rep) = newCanvas()
    linear(ctx, [rgb(118, 30, 28), rgb(198, 82, 56)])
    glow(ctx, at: CGPoint(x: 470, y: 380), radius: 660, alpha: 0.13)

    let frame = roundRect(150, 150, 724, 724, 96)
    ctx.setStrokeColor(rgb(255, 236, 224, 0.42))
    ctx.setLineWidth(10)
    ctx.addPath(frame); ctx.strokePath()
    let inner = roundRect(176, 176, 672, 672, 80)
    ctx.setStrokeColor(rgb(255, 236, 224, 0.14))
    ctx.setLineWidth(4)
    ctx.addPath(inner); ctx.strokePath()

    glyph(ctx, "化", size: 580, color: rgb(70, 12, 12, 0.55), offset: CGPoint(x: 10, y: -10))
    glyph(ctx, "化", size: 580, color: rgb(255, 249, 240))
    try save(rep, "1-墨印.png")
}

// MARK: - 2 折光：玻璃棱镜分光（拟物 / 有体积感）

func icon2() throws {
    let (ctx, rep) = newCanvas()
    linear(ctx, [rgb(10, 16, 38), rgb(32, 44, 92)])
    glow(ctx, at: CGPoint(x: 200, y: 780), radius: 720, alpha: 0.10)

    // 入射白光：三层叠加做发光（线宽按 16px 可辨识度定，不能太细）
    for spec in [(104, 0.10), (64, 0.20), (30, 0.95)] as [(CGFloat, CGFloat)] {
        ctx.setStrokeColor(rgb(255, 255, 255, spec.1))
        ctx.setLineWidth(spec.0)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 108, y: 424))
        ctx.addLine(to: CGPoint(x: 430, y: 520))
        ctx.strokePath()
    }

    // 出射光谱：红→紫七色，按偏折顺序自上而下，从棱镜右边缘外侧扇形发散。
    // 棱镜右边缘是斜线 x(y) = 512 + (y - 224) * 244/508；旧版把三条带起点
    // 固定在同一 x，下方色带（红光）的起点因此落进棱镜内部。现在所有起点
    // 取 x = 662（在边缘外侧），且楔形斜率远小于边缘斜率，色带不会回穿棱镜。
    let spectrum: [CGColor] = [
        rgb(255, 76, 76),    // 红
        rgb(255, 152, 56),   // 橙
        rgb(255, 214, 74),   // 黄
        rgb(95, 214, 114),   // 绿
        rgb(63, 208, 208),   // 青
        rgb(76, 132, 255),   // 蓝
        rgb(158, 96, 232),   // 紫
    ]
    let x0: CGFloat = 662
    let x1: CGFloat = 944
    let spacing: CGFloat = 34
    let half: CGFloat = 15
    for (i, color) in spectrum.enumerated() {
        let k = CGFloat(i - 3)
        let yStart = 508 + k * 4            // 出射点附近，七色几乎汇聚
        let yEnd = 508 + k * spacing        // 向右发散，拉开七色
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: yStart - 3))
        p.addLine(to: CGPoint(x: x1, y: yEnd - half))
        p.addLine(to: CGPoint(x: x1, y: yEnd + half))
        p.addLine(to: CGPoint(x: x0, y: yStart + 3))
        p.closeSubpath()
        fillPathGradient(ctx, p, [color, transparent(color)],
                         from: CGPoint(x: x0, y: 0), to: CGPoint(x: x1, y: 0))
    }

    // 玻璃棱镜
    let prism = CGMutablePath()
    prism.move(to: CGPoint(x: 512, y: 224))
    prism.addLine(to: CGPoint(x: 268, y: 732))
    prism.addLine(to: CGPoint(x: 756, y: 732))
    prism.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 42,
                  color: rgb(0, 0, 0, 0.45))
    ctx.setFillColor(rgb(255, 255, 255, 0.10))
    ctx.addPath(prism); ctx.fillPath()
    ctx.restoreGState()

    // 棱镜内的斜向高光
    ctx.saveGState()
    ctx.addPath(prism); ctx.clip()
    ctx.setFillColor(rgb(255, 255, 255, 0.14))
    ctx.fill(CGRect(x: 352, y: 190, width: 80, height: 620))
    ctx.restoreGState()

    ctx.setStrokeColor(rgb(255, 255, 255, 0.86))
    ctx.setLineWidth(26)
    ctx.setLineJoin(.round)
    ctx.addPath(prism); ctx.strokePath()
    try save(rep, "2-折光.png")
}

// MARK: - 3 线环：浅底开口弧 + 圆心（极简 / 线性）

func icon3() throws {
    let (ctx, rep) = newCanvas()
    linear(ctx, [rgb(247, 249, 253), rgb(224, 231, 243)])

    let c = CGPoint(x: 512, y: 512)
    let r: CGFloat = 280
    ctx.saveGState()
    ctx.setLineWidth(92)
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.addArc(center: c, radius: r,
               startAngle: .pi * 0.75, endAngle: .pi * 0.75 + .pi * 1.5,
               clockwise: false)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, [rgb(58, 96, 255), rgb(38, 202, 190)],
           from: CGPoint(x: 180, y: 180), to: CGPoint(x: 844, y: 844))
    ctx.restoreGState()

    let dot = CGPath(ellipseIn: CGRect(x: 448, y: 448, width: 128, height: 128), transform: nil)
    fillPathGradient(ctx, dot, [rgb(58, 96, 255), rgb(38, 202, 190)],
                     from: CGPoint(x: 448, y: 448), to: CGPoint(x: 576, y: 576))
    try save(rep, "3-线环.png")
}

// MARK: - 4 叠片：磨砂后卡 + 渐变前卡（材质 / 前后景深）

func icon4() throws {
    let (ctx, rep) = newCanvas()
    linear(ctx, [rgb(26, 36, 56), rgb(60, 78, 112)])
    glow(ctx, at: CGPoint(x: 760, y: 200), radius: 700, alpha: 0.09)

    let back = roundRect(196, 196, 430, 430, 84)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 40,
                  color: rgb(0, 0, 0, 0.35))
    ctx.setFillColor(rgb(255, 255, 255, 0.12))
    ctx.addPath(back); ctx.fillPath()
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(255, 255, 255, 0.42))
    ctx.setLineWidth(10)
    ctx.addPath(back); ctx.strokePath()

    let front = roundRect(398, 398, 430, 430, 84)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 52,
                  color: rgb(0, 0, 0, 0.50))
    ctx.setFillColor(white)
    ctx.addPath(front); ctx.fillPath()
    ctx.restoreGState()
    fillPathGradient(ctx, front, [rgb(46, 214, 192), rgb(61, 123, 255)],
                     from: CGPoint(x: 398, y: 398), to: CGPoint(x: 828, y: 828))
    ctx.saveGState()
    ctx.addPath(front); ctx.clip()
    ctx.setFillColor(rgb(255, 255, 255, 0.18))
    ctx.fill(CGRect(x: 398, y: 398, width: 430, height: 118))
    ctx.restoreGState()

    ctx.setStrokeColor(white)
    ctx.setLineWidth(38)
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 508, y: 613))
    ctx.addLine(to: CGPoint(x: 690, y: 613))
    ctx.strokePath()
    triangle(ctx, CGPoint(x: 654, y: 551), CGPoint(x: 744, y: 613),
             CGPoint(x: 654, y: 675), white)
    try save(rep, "4-叠片.png")
}

// MARK: - 5 融形：两滴融合的液态轮廓（抽象 / 字面「化形」）

func icon5() throws {
    let (ctx, rep) = newCanvas()
    linear(ctx, [rgb(24, 14, 52), rgb(70, 32, 126)])
    glow(ctx, at: CGPoint(x: 320, y: 260), radius: 680, alpha: 0.10)

    // 左右两滴 + 中间腰部的 metaball 轮廓
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 150, y: 512))
    p.addCurve(to: CGPoint(x: 512, y: 420),
               control1: CGPoint(x: 150, y: 330), control2: CGPoint(x: 330, y: 330))
    p.addCurve(to: CGPoint(x: 874, y: 512),
               control1: CGPoint(x: 694, y: 330), control2: CGPoint(x: 874, y: 330))
    p.addCurve(to: CGPoint(x: 512, y: 604),
               control1: CGPoint(x: 874, y: 694), control2: CGPoint(x: 694, y: 694))
    p.addCurve(to: CGPoint(x: 150, y: 512),
               control1: CGPoint(x: 330, y: 694), control2: CGPoint(x: 150, y: 694))
    p.closeSubpath()

    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    linear(ctx, [rgb(64, 224, 208), rgb(150, 92, 255)],
           from: CGPoint(x: 150, y: 300), to: CGPoint(x: 874, y: 720))
    // 玻璃高光
    ctx.setStrokeColor(rgb(255, 255, 255, 0.34))
    ctx.setLineWidth(26)
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 244, y: 430))
    ctx.addCurve(to: CGPoint(x: 512, y: 372),
                 control1: CGPoint(x: 320, y: 372), control2: CGPoint(x: 410, y: 358))
    ctx.addCurve(to: CGPoint(x: 780, y: 430),
                 control1: CGPoint(x: 614, y: 358), control2: CGPoint(x: 704, y: 372))
    ctx.strokePath()
    // 底部暗部用渐变，避免出现水平硬边
    let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(20, 10, 48, 0), rgb(20, 10, 48, 0.30)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: 500),
                           end: CGPoint(x: 0, y: 740), options: [])
    ctx.restoreGState()
    try save(rep, "5-融形.png")
}

// MARK: - 6 化圆：左方右圆的单色符号（极简 / 几何，直译「化形」）

func icon6() throws {
    let (ctx, rep) = newCanvas()
    linear(ctx, [rgb(18, 21, 28), rgb(40, 46, 62)])

    let p = CGMutablePath()
    p.move(to: CGPoint(x: 296, y: 268))
    p.addLine(to: CGPoint(x: 512, y: 268))
    p.addCurve(to: CGPoint(x: 756, y: 512),
               control1: CGPoint(x: 647, y: 268), control2: CGPoint(x: 756, y: 377))
    p.addCurve(to: CGPoint(x: 512, y: 756),
               control1: CGPoint(x: 756, y: 647), control2: CGPoint(x: 647, y: 756))
    p.addLine(to: CGPoint(x: 296, y: 756))
    p.closeSubpath()

    fillPathGradient(ctx, p, [rgb(246, 249, 253), rgb(96, 214, 206)],
                     from: CGPoint(x: 296, y: 268), to: CGPoint(x: 756, y: 756))
    // 左半「方」用横向渐变压暗，强化方 → 圆且不留下竖直硬边
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(18, 21, 28, 0.16), rgb(18, 21, 28, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 296, y: 0),
                           end: CGPoint(x: 610, y: 0), options: [])
    ctx.restoreGState()
    try save(rep, "6-化圆.png")
}

try icon1(); try icon2(); try icon3()
try icon4(); try icon5(); try icon6()
print("v2 生成完成：1-墨印 / 2-折光 / 3-线环 / 4-叠片 / 5-融形 / 6-化圆 → \(outDir)")
