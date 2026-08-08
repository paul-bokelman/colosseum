import SwiftUI

/// Draws a rectangular border, optionally segmented into per-tag colors around the perimeter.
struct SegmentedTagBorder: View {
    let colors: [Color]
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            if colors.isEmpty {
                stroke(context: context, size: size, color: ColosseumTheme.border)
                return
            }
            if colors.count == 1 {
                stroke(context: context, size: size, color: colors[0])
                return
            }
            strokeSegmented(context: context, size: size, colors: colors)
        }
        .allowsHitTesting(false)
    }

    private func stroke(context: GraphicsContext, size: CGSize, color: Color) {
        let inset = lineWidth / 2
        let path = Path(
            CGRect(
                x: inset,
                y: inset,
                width: max(0, size.width - lineWidth),
                height: max(0, size.height - lineWidth)
            )
        )
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private func strokeSegmented(context: GraphicsContext, size: CGSize, colors: [Color]) {
        let inset = lineWidth / 2
        let rect = CGRect(
            x: inset,
            y: inset,
            width: max(0, size.width - lineWidth),
            height: max(0, size.height - lineWidth)
        )
        guard rect.width > 0, rect.height > 0 else { return }

        let perimeter = 2 * (rect.width + rect.height)
        let segment = perimeter / CGFloat(colors.count)
        let samples = max(24, colors.count * 16)

        for (index, color) in colors.enumerated() {
            let start = CGFloat(index) * segment
            let end = start + segment
            var path = Path()
            let steps = max(4, Int((end - start) / (perimeter / CGFloat(samples))))
            for step in 0...steps {
                let distance = start + (end - start) * CGFloat(step) / CGFloat(steps)
                let point = pointOnPerimeter(rect: rect, distance: distance)
                if step == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter)
            )
        }
    }

    /// Clockwise from top-left.
    private func pointOnPerimeter(rect: CGRect, distance: CGFloat) -> CGPoint {
        let w = rect.width
        let h = rect.height
        let perimeter = 2 * (w + h)
        var d = distance.truncatingRemainder(dividingBy: perimeter)
        if d < 0 { d += perimeter }

        if d <= w {
            return CGPoint(x: rect.minX + d, y: rect.minY)
        }
        d -= w
        if d <= h {
            return CGPoint(x: rect.maxX, y: rect.minY + d)
        }
        d -= h
        if d <= w {
            return CGPoint(x: rect.maxX - d, y: rect.maxY)
        }
        d -= w
        return CGPoint(x: rect.minX, y: rect.maxY - d)
    }
}

extension View {
    /// Default muted border, or tag-colored / segmented border when tags are present.
    func blockTagBorder(tags: [String], lineWidth: CGFloat = 1) -> some View {
        let colors = tags.map { TagColor.color(for: $0) }
        return overlay {
            SegmentedTagBorder(colors: colors, lineWidth: lineWidth)
        }
    }

    /// Focus ring drawn outside the cell with a gap, preserving the inner border.
    /// Uses an overlay so layout / content position does not shift when active.
    func gridSelectionRing(
        isActive: Bool,
        gap: CGFloat = ColosseumTheme.selectionRingGap,
        lineWidth: CGFloat = ColosseumTheme.selectionRingWidth
    ) -> some View {
        overlay {
            if isActive {
                Rectangle()
                    .stroke(ColosseumTheme.selectionRingColor, lineWidth: lineWidth)
                    .padding(-(gap + lineWidth / 2))
                    .allowsHitTesting(false)
            }
        }
    }
}
