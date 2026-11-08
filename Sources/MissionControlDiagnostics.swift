import AppKit

struct MissionControlDiagnostics: Equatable {
    struct Sample: Equatable {
        let point: CGPoint
        let polled: Bool
    }

    let referenceY: CGFloat
    let labelY: CGFloat
    let thumbnailSize: CGSize
    let centeredXs: [CGFloat]
    let trail: [Sample]
    let observedXs: [CGFloat]?
    let anchorX: CGFloat?
    let anchorSamples: [CGPoint]
    let anchorMethod: String?
    let selectedSpace: String?
    let appliedOffset: CGFloat?
    let firstShift: CGFloat?
    let recentered: Bool

    func draw(in bounds: CGRect) {
        if let observedXs {
            drawPreviews(centers: observedXs, color: .systemGreen, dashed: false)
        } else if let appliedOffset {
            if let firstShift, firstShift != appliedOffset {
                drawPreviews(centers: centeredXs.map { $0 + firstShift },
                             color: .systemGreen.withAlphaComponent(0.7), dashed: true)
            }
            drawPreviews(centers: centeredXs.map { $0 + appliedOffset }, color: .systemGreen, dashed: false)
        }

        let reference = NSBezierPath()
        reference.move(to: CGPoint(x: bounds.minX, y: referenceY))
        reference.line(to: CGPoint(x: bounds.maxX, y: referenceY))
        reference.setLineDash([7, 5], count: 2, phase: 0)
        stroke(reference, color: .systemYellow, width: 1.5)

        if let first = trail.first {
            let path = NSBezierPath()
            path.move(to: first.point)
            for sample in trail.dropFirst() { path.line(to: sample.point) }
            stroke(path, color: .systemCyan, width: 2)
            for sample in trail {
                let dot = marker(at: sample.point, size: sample.polled ? 7 : 4)
                if sample.polled {
                    stroke(dot, color: .systemCyan, width: 1)
                } else {
                    NSColor.systemCyan.setFill()
                    dot.fill()
                }
            }
        }
        for point in anchorSamples {
            stroke(marker(at: point, size: 13), color: .systemYellow, width: 1.5)
        }
        if let anchorX {
            let crossing = CGPoint(x: anchorX, y: referenceY)
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: crossing.x - 8, y: crossing.y))
            cross.line(to: CGPoint(x: crossing.x + 8, y: crossing.y))
            cross.move(to: CGPoint(x: crossing.x, y: crossing.y - 8))
            cross.line(to: CGPoint(x: crossing.x, y: crossing.y + 8))
            stroke(cross, color: .systemYellow, width: 2.5)
        }
        drawLegend(in: bounds)
    }

    private func drawPreviews(centers: [CGFloat], color: NSColor, dashed: Bool) {
        let path = NSBezierPath()
        for x in centers {
            path.appendRect(CGRect(x: x - thumbnailSize.width / 2, y: labelY + 15,
                                   width: thumbnailSize.width, height: thumbnailSize.height))
            if !dashed {
                path.move(to: CGPoint(x: x, y: labelY + 15))
                path.line(to: CGPoint(x: x, y: labelY + 25))
            }
        }
        if dashed { path.setLineDash([5, 4], count: 2, phase: 0) }
        stroke(path, color: color, width: 1.5)
    }

    private func drawLegend(in bounds: CGRect) {
        let reference = String(format: "Yellow: reference %.0f pt from top", bounds.maxY - referenceY)
        let crossing = anchorX.map { String(format: "x = %.1f pt", $0) }
        let anchor = [anchorMethod, crossing].compactMap { $0 }.joined(separator: ", ")
        let offset = observedXs.map { ($0.first ?? 0) - (centeredXs.first ?? 0) } ?? appliedOffset
        let shift = offset.map { String(format: "Applied shift %+.1f pt", $0) }
        let first = firstShift.flatMap { initial in
            appliedOffset == initial ? nil : String(format: "dashed: first shift %+.1f pt", initial)
        }
        let summary = [anchor.isEmpty ? nil : anchor, selectedSpace, shift,
                       recentered ? "recentered" : nil, first].compactMap { $0 }.joined(separator: " · ")
        let lines: [(String, NSColor)] = [
            ("Cyan: pointer samples (ring = poll)", .systemCyan),
            (reference + " · cross: chosen x · rings: samples used", .systemYellow),
            (observedXs == nil ? "Green: predicted preview bounds" : "Green: aligned to Dock positions", .systemGreen),
            (summary.isEmpty ? "Waiting for pointer entry" : summary, .white)
        ]
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let width = lines.map { ($0.0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        let legend = CGRect(x: 12, y: max(12, labelY - 92), width: min(ceil(width) + 20, bounds.width - 24), height: 72)
        NSColor(white: 0.08, alpha: 0.91).setFill()
        NSBezierPath(roundedRect: legend, xRadius: 7, yRadius: 7).fill()
        for (index, line) in lines.enumerated() {
            let rect = CGRect(x: legend.minX + 10, y: legend.maxY - CGFloat(index + 1) * 15 - 4,
                              width: legend.width - 20, height: 15)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (line.0 as NSString).draw(in: rect, withAttributes: [
                .font: font, .foregroundColor: line.1, .paragraphStyle: paragraph
            ])
        }
    }

    private func marker(at point: CGPoint, size: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
    }

    private func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        NSColor.black.withAlphaComponent(0.75).setStroke()
        path.lineWidth = width + 2
        path.stroke()
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }
}
