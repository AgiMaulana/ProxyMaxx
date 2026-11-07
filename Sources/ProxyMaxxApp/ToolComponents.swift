import SwiftUI
import AppKit

/// Pieces the Settings pane and the Certificate sheet share, so the two read as one place.
///
/// These are layout only: each wraps state the app already has. The one thing they add is
/// presentation, not behaviour.

/// A grouped surface: rounded, bordered card whose contents form a vertical stack.
///
/// Used instead of `GroupBox` because the design keeps the heading outside the card and
/// lets a card hold full-bleed rows.
struct ToolCard<Content: View>: View {
    var padding: CGFloat = 14
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

/// A row that leads somewhere: icon, title, one line of detail, and a chevron. The whole
/// row is the target, because the row is what reads as the button.
///
/// `.firstTextBaseline` keeps the chevron and icon level with the title. At `.top` the
/// chevron floats above the title and reads as the row's first word.
struct ToolRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(title)) { action() }
    }
}

/// Trust state of the root CA, in words as well as icon: "Not trusted" is the one condition
/// that stops HTTPS being decrypted, so it must not depend on colour alone.
struct CertificateStatusChip: View {
    let trusted: Bool

    var body: some View {
        let tint: Color = trusted ? .green : .orange
        Label(
            trusted ? L10n.string("cert.statusTrusted") : L10n.string("cert.statusNotTrusted"),
            systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// Copy a command to the pasteboard, and say so for a moment. Says "Copied" without a timer
/// for the same reason the command line panel does: the next action replaces the label.
struct CopyTextButton: View {
    let text: String
    var accessibilityLabel: String

    @State private var copied = false

    var body: some View {
        Button(copied ? "common.copied" : "common.copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        }
        .controlSize(.small)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// The list of data that is never sent, as chips rather than a sentence, so each claim can
/// be checked against `docs/privacy.md` on its own.
struct SpanChips: View {
    private static let items: [String] = [
        "settings.neverTraffic", "settings.neverHeaders", "settings.neverCookies",
        "settings.neverCredentials", "settings.neverURLs", "settings.neverLogs"
    ]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { _, key in
                Text(verbatim: L10n.string(key))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wraps its children onto as many lines as the width allows.
///
/// SwiftUI on macOS 14 has no flow container, and these chips are one list: a grid would
/// leave holes where the widths differ, especially once localized.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var cursor = Cursor(spacing: spacing)
        for subview in subviews {
            _ = cursor.place(subview.sizeThatFits(.unspecified), in: width)
        }
        return CGSize(width: proposal.width ?? cursor.rowWidth, height: cursor.rowTop + cursor.rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursor = Cursor(spacing: spacing)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let origin = cursor.place(size, in: bounds.width, originX: bounds.minX)
            subview.place(at: CGPoint(x: origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(size))
        }
    }

    /// Tracks where the next chip goes. Shared by measuring and placing so the two cannot
    /// disagree about where a line breaks.
    private struct Cursor {
        let spacing: CGFloat
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowTop: CGFloat = 0

        mutating func place(_ size: CGSize, in width: CGFloat, originX: CGFloat = 0) -> CGPoint {
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                rowTop += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            let origin = CGPoint(x: originX + rowWidth, y: rowTop)
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
            return origin
        }
    }
}
