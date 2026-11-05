import AppKit
import PulseCore

/// Everything that decides what one module looks like. Comparing these skips needless redraws.
struct StatusSegment: Hashable, Sendable {
    static let barSteps = 28
    static let sparkColumns = 18
    static let sparkSteps = 14

    let label: String
    let renderer: RendererKind
    let tint: ModuleTint
    let text: String
    /// Reserves a fixed width, so that the menu bar does not shift as digits change.
    /// Two words, as for network, draw as two lines in compact layout.
    let widthTemplate: String
    /// 0...barSteps
    let fillSteps: Int
    /// 0...sparkSteps per column, oldest first.
    let spark: [Int]
}

extension ModuleTint {
    var color: NSColor? {
        switch self {
        case .system: nil
        case .blue: .systemBlue
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        case .purple: .systemPurple
        case .teal: .systemTeal
        }
    }
}

/// Draws status items by hand, since a menu-bar item can only show an image or a title.
///
/// Compact layout stacks each label above its value. The combined item needs it, because at
/// full width it did not fit beside the notch on a built-in display.
enum StatusItemRenderer {
    private static let height: CGFloat = 18
    private static let labelGap: CGFloat = 3
    private static let compactGraphicHeight: CGFloat = 9.5

    private static func spacing(compact: Bool) -> CGFloat { compact ? 6 : 8 }

    /// Colours resolve against `appearance`, which is the menu bar's rather than the app's.
    static func image(
        for segments: [StatusSegment],
        scale: CGFloat = 2,
        appearance: NSAppearance = .currentDrawing(),
        compact: Bool = false
    ) -> NSImage {
        let widths = segments.map { compact ? compactWidth($0) : fullWidth($0) }
        let gap = spacing(compact: compact)
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, segments.count - 1))
        let size = NSSize(width: max(1, ceil(total)), height: height)
        let image = NSImage(size: size)
        // Drawn once into a bitmap, ready to hand to a layer.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        appearance.performAsCurrentDrawingAppearance {
            var originX: CGFloat = 0
            for (segment, width) in zip(segments, widths) {
                if compact {
                    drawCompact(segment, at: originX, width: width)
                } else {
                    drawFull(segment, at: originX)
                }
                originX += width + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        return image
    }

    // MARK: - Text

    private static func attributes(size: CGFloat, weight: NSFont.Weight, digits: Bool = false, color: NSColor = .labelColor)
        -> [NSAttributedString.Key: Any] {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return [.font: font, .foregroundColor: color]
    }

    private static func textWidth(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private static func draw(_ text: String, originX: CGFloat, centerY: CGFloat, _ attributes: [NSAttributedString.Key: Any]) {
        let nsText = text as NSString
        let size = nsText.size(withAttributes: attributes)
        nsText.draw(at: NSPoint(x: originX, y: centerY - size.height / 2), withAttributes: attributes)
    }

    // MARK: - Full layout: label beside value

    private static func fullWidth(_ segment: StatusSegment) -> CGFloat {
        let graphic: CGFloat
        switch segment.renderer {
        case .text: graphic = textWidth(segment.widthTemplate, attributes(size: 11, weight: .medium, digits: true))
        case .sparkline: graphic = 36
        case .bar: graphic = 28
        case .gauge: graphic = 14
        }
        return textWidth(segment.label, attributes(size: 9, weight: .semibold)) + labelGap + graphic
    }

    private static func drawFull(_ segment: StatusSegment, at originX: CGFloat) {
        let labelAttributes = attributes(size: 9, weight: .semibold)
        draw(segment.label, originX: originX, centerY: height / 2, labelAttributes)
        let graphicX = originX + textWidth(segment.label, labelAttributes) + labelGap
        let color = segment.tint.color ?? NSColor.labelColor
        switch segment.renderer {
        case .text:
            draw(segment.text, originX: graphicX, centerY: height / 2, attributes(size: 11, weight: .medium, digits: true, color: color))
        case .sparkline:
            drawSparkline(segment, in: NSRect(x: graphicX, y: 2, width: 36, height: 14), color: color)
        case .bar:
            drawBar(segment, in: NSRect(x: graphicX, y: 5, width: 28, height: 8), color: color)
        case .gauge:
            drawGauge(segment, in: NSRect(x: graphicX, y: 2, width: 14, height: 14), lineWidth: 2.5, color: color)
        }
    }

    // MARK: - Compact layout: label above value

    private static func twoLines(_ text: String) -> [String]? {
        let parts = text.split(separator: " ").map(String.init)
        return parts.count == 2 ? parts : nil
    }

    private static func compactWidth(_ segment: StatusSegment) -> CGFloat {
        if segment.renderer == .text, let lines = twoLines(segment.widthTemplate) {
            let lineAttributes = attributes(size: 8.5, weight: .medium, digits: true)
            return lines.map { textWidth($0, lineAttributes) }.max() ?? 0
        }
        let graphic: CGFloat
        switch segment.renderer {
        case .text: graphic = textWidth(segment.widthTemplate, attributes(size: 10, weight: .medium, digits: true))
        case .sparkline, .bar: graphic = 24
        case .gauge: graphic = 10
        }
        return max(textWidth(segment.label, attributes(size: 7.5, weight: .semibold)), graphic)
    }

    private static func drawCompact(_ segment: StatusSegment, at originX: CGFloat, width: CGFloat) {
        let color = segment.tint.color ?? NSColor.labelColor
        // The arrows already identify network, so its two lines replace the label.
        if segment.renderer == .text, twoLines(segment.widthTemplate) != nil, let lines = twoLines(segment.text) {
            let lineAttributes = attributes(size: 8.5, weight: .medium, digits: true, color: color)
            draw(lines[0], originX: originX, centerY: height * 0.75, lineAttributes)
            draw(lines[1], originX: originX, centerY: height * 0.25, lineAttributes)
            return
        }
        draw(segment.label, originX: originX, centerY: height - 4, attributes(size: 7.5, weight: .semibold))
        let graphic = NSRect(x: originX, y: 0, width: width, height: compactGraphicHeight)
        switch segment.renderer {
        case .text:
            draw(segment.text, originX: originX, centerY: graphic.midY, attributes(size: 10, weight: .medium, digits: true, color: color))
        case .sparkline:
            drawSparkline(segment, in: graphic.insetBy(dx: 0, dy: 0.5), color: color)
        case .bar:
            drawBar(segment, in: NSRect(x: originX, y: 2, width: width, height: 5), color: color)
        case .gauge:
            drawGauge(segment, in: NSRect(x: originX, y: 0, width: 10, height: 10), lineWidth: 2, color: color)
        }
    }

    // MARK: - Graphics

    private static func drawSparkline(_ segment: StatusSegment, in rect: NSRect, color: NSColor) {
        let columnWidth = rect.width / CGFloat(StatusSegment.sparkColumns)
        let stepHeight = rect.height / CGFloat(StatusSegment.sparkSteps)
        color.setFill()
        // Newest values sit on the right, even before the history has filled up.
        let firstColumn = StatusSegment.sparkColumns - segment.spark.count
        for (index, steps) in segment.spark.enumerated() where steps > 0 {
            let columnX = rect.minX + CGFloat(firstColumn + index) * columnWidth
            NSRect(x: columnX, y: rect.minY, width: max(1, columnWidth - 0.5), height: CGFloat(steps) * stepHeight).fill()
        }
        color.withAlphaComponent(0.3).setFill()
        NSRect(x: rect.minX, y: rect.minY - 0.5, width: rect.width, height: 0.5).fill()
    }

    private static func drawBar(_ segment: StatusSegment, in rect: NSRect, color: NSColor) {
        color.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        var fill = rect
        fill.size.width = rect.width * CGFloat(segment.fillSteps) / CGFloat(StatusSegment.barSteps)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }

    private static func drawGauge(_ segment: StatusSegment, in rect: NSRect, lineWidth: CGFloat, color: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - lineWidth / 2
        let startAngle: CGFloat = 225
        let sweep: CGFloat = 270

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: startAngle - sweep, clockwise: true)
        track.lineWidth = lineWidth
        color.withAlphaComponent(0.25).setStroke()
        track.stroke()

        guard segment.fillSteps > 0 else { return }
        let fraction = CGFloat(segment.fillSteps) / CGFloat(StatusSegment.barSteps)
        let value = NSBezierPath()
        value.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: startAngle - sweep * fraction, clockwise: true)
        value.lineWidth = lineWidth
        color.setStroke()
        value.stroke()
    }
}
