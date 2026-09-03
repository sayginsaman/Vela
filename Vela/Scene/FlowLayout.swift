import SwiftUI

/// Wraps subviews into centred rows. Used for word-level lyric lines so long lines wrap
/// without clipping while every word stays an individually styled view.
struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 6

    struct Row { var indices: [Int]; var width: CGFloat; var height: CGFloat }

    private func rows(sizes: [CGSize], maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)
        for (index, size) in sizes.enumerated() {
            let extra = current.indices.isEmpty ? 0 : spacing
            if !current.indices.isEmpty, current.width + extra + size.width > maxWidth {
                rows.append(current)
                current = Row(indices: [], width: 0, height: 0)
            }
            let gap = current.indices.isEmpty ? 0 : spacing
            current.indices.append(index)
            current.width += gap + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(sizes: sizes, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth.isFinite ? min(maxWidth, width) : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(sizes: sizes, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}
