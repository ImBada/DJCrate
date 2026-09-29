import RekordboxKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import SwiftUI

/// 칩을 줄바꿈하며 배치한다. justified면 각 줄의 양쪽 끝을 맞춘다.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var justified = false
    var centerItems = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: justified && width.isFinite ? width : maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if justified {
            var rows: [(range: Range<Int>, width: CGFloat, height: CGFloat)] = []
            var start = 0, rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
            for index in 0..<subviews.count {
                let size = subviews[index].sizeThatFits(.unspecified)
                let nextWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
                if rowWidth > 0, nextWidth > bounds.width {
                    rows.append((start..<index, rowWidth, rowHeight))
                    start = index; rowWidth = size.width; rowHeight = size.height
                } else {
                    rowWidth = nextWidth
                    rowHeight = max(rowHeight, size.height)
                }
            }
            if start < subviews.count { rows.append((start..<subviews.count, rowWidth, rowHeight)) }
            var y = bounds.minY
            for row in rows {
                let extra = max(0, bounds.width - row.width)
                var x = bounds.minX + (row.range.count == 1 ? extra / 2 : 0)
                let gap = justified && row.range.count > 1 ? spacing + extra / CGFloat(row.range.count - 1) : spacing
                for index in row.range {
                    let size = subviews[index].sizeThatFits(.unspecified)
                    let itemY = centerItems ? y + (row.height - size.height) / 2 : y
                    subviews[index].place(at: CGPoint(x: x, y: itemY), proposal: ProposedViewSize(size))
                    x += size.width + gap
                }
                y += row.height + spacing
            }
            return
        }
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
