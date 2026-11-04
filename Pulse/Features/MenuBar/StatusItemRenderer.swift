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
enum StatusItemRenderer {
    private static let height: CGFloat = 18
    private static let segmentSpacing: CGFloat = 8
    private static let labelGap: CGFloat = 3
    private static let barWidth = CGFloat(StatusSegment.barSteps)
    private static let sparkWidth: CGFloat = 36
    private static let gaugeSize: CGFloat = 14

    /// Colours resolve against `appearance`, which is the menu bar's rather than the app's.
    static func image(for segments: [StatusSegment], scale: CGFloat = 2, appearance: NSAppearance = .currentDrawing()) -> NSImage {
        let widths = segments.map(width)
        let total = widths.reduce(0, +) + segmentSpacing * CGFloat(max(0, segments.count - 1))
        let size = NSSize(width: max(1, ceil(total)), height: height)
        // Drawn once into a bitmap, ready to hand to a layer.
        let image = NSImage(size: size)
        if let bitmap = NSBitmapImageRep(
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
        ) {
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            appearance.performAsCurrentDrawingAppearance {
                var originX: CGFloat = 0
                for (segment, width) in zip(segments, widths) {
                    draw(segment, at: originX)
                    originX += width + segmentSpacing
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        return image
    }

    private static func labelAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.labelColor]
    }

    private static func valueAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
    }

    private static func labelWidth(_ segment: StatusSegment) -> CGFloat {
        ceil((segment.label as NSString).size(withAttributes: labelAttributes()).width)
    }

    private static func width(_ segment: StatusSegment) -> CGFloat {
        let graphic: CGFloat
        switch segment.renderer {
        case .text: graphic = ceil((segment.widthTemplate as NSString).size(withAttributes: valueAttributes()).width)
        case .sparkline: graphic = sparkWidth
        case .bar: graphic = barWidth
        case .gauge: graphic = gaugeSize
        }
        return labelWidth(segment) + labelGap + graphic
    }

    private static func draw(_ segment: StatusSegment, at originX: CGFloat) {
        let label = segment.label as NSString
        let labelSize = label.size(withAttributes: labelAttributes())
        label.draw(at: NSPoint(x: originX, y: (height - labelSize.height) / 2), withAttributes: labelAttributes())

        let graphicX = originX + labelWidth(segment) + labelGap
        let color = segment.tint.color ?? NSColor.labelColor
        switch segment.renderer {
        case .text: drawText(segment, atX: graphicX)
        case .sparkline: drawSparkline(segment, atX: graphicX, color: color)
        case .bar: drawBar(segment, atX: graphicX, color: color)
        case .gauge: drawGauge(segment, atX: graphicX, color: color)
        }
    }

    private static func drawText(_ segment: StatusSegment, atX originX: CGFloat) {
        var attributes = valueAttributes()
        if let tint = segment.tint.color { attributes[.foregroundColor] = tint }
        let text = segment.text as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: originX, y: (height - size.height) / 2), withAttributes: attributes)
    }

    private static func drawSparkline(_ segment: StatusSegment, atX originX: CGFloat, color: NSColor) {
        let columnWidth = sparkWidth / CGFloat(StatusSegment.sparkColumns)
        let baseline = (height - CGFloat(StatusSegment.sparkSteps)) / 2
        color.setFill()
        // Newest values sit on the right, even before the history has filled up.
        let firstColumn = StatusSegment.sparkColumns - segment.spark.count
        for (index, steps) in segment.spark.enumerated() where steps > 0 {
            let columnX = originX + CGFloat(firstColumn + index) * columnWidth
            NSRect(x: columnX, y: baseline, width: max(1, columnWidth - 0.5), height: CGFloat(steps)).fill()
        }
        color.withAlphaComponent(0.3).setFill()
        NSRect(x: originX, y: baseline - 1, width: sparkWidth, height: 1).fill()
    }

    private static func drawBar(_ segment: StatusSegment, atX originX: CGFloat, color: NSColor) {
        let track = NSRect(x: originX, y: (height - 8) / 2, width: barWidth, height: 8)
        color.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        var fill = track
        fill.size.width = CGFloat(segment.fillSteps)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }

    private static func drawGauge(_ segment: StatusSegment, atX originX: CGFloat, color: NSColor) {
        let center = NSPoint(x: originX + gaugeSize / 2, y: height / 2)
        let radius = gaugeSize / 2 - 1.25
        let startAngle: CGFloat = 225
        let sweep: CGFloat = 270

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: startAngle - sweep, clockwise: true)
        track.lineWidth = 2.5
        color.withAlphaComponent(0.25).setStroke()
        track.stroke()

        guard segment.fillSteps > 0 else { return }
        let fraction = CGFloat(segment.fillSteps) / CGFloat(StatusSegment.barSteps)
        let value = NSBezierPath()
        value.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: startAngle - sweep * fraction, clockwise: true)
        value.lineWidth = 2.5
        color.setStroke()
        value.stroke()
    }
}
