import SwiftUI
import Branding
import FlowKit
import RuleKit

/// A layout that arranges views left to right, wrapping to a new line when width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var layoutX: CGFloat = 0
        var layoutY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if layoutX > 0, layoutX + size.width > maxWidth {
                layoutX = 0
                layoutY += rowHeight + spacing
                rowHeight = 0
            }
            widest = max(widest, layoutX + size.width)
            layoutX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(
            width: maxWidth.isFinite ? maxWidth : widest,
            height: subviews.isEmpty ? 0 : layoutY + rowHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var layoutX = bounds.minX
        var layoutY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if layoutX > bounds.minX, layoutX + size.width > bounds.maxX {
                layoutX = bounds.minX
                layoutY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: layoutX, y: layoutY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            layoutX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Reusable scenario chip view matching local override scenario designs.
struct ScenarioChipView: View {
    let name: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text(name).font(.callout)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.format("mapLocal.removeScenarioHelp", name)))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
        .overlay(Capsule().stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }
}

/// Reusable status pill view for active or modified scenarios.
struct ScenarioStatusPillView: View {
    let title: String
    let isModified: Bool
    var onReset: (() -> Void)?

    var body: some View {
        let tint: Color = isModified ? .orange : .green
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.15)))
                .lineLimit(1)
                .help("mapLocal.scenarioHelp")

            if isModified, let onReset {
                Button("mapLocal.resetScenario", action: onReset)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("mapLocal.resetScenarioHelp")
            }
        }
    }
}
