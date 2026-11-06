import SwiftUI
import AppKit

/// A multi-line editor that owns an `NSTextView`, so the system Find support applies.
///
/// `TextEditor` cannot answer Find. Its backing text view never becomes a find client,
/// so ⌘F reaches the app and no find bar appears. Hosting the text view directly makes
/// the two AppKit switches for this job meaningful: `usesFindBar` gives the enclosing
/// scroll view the inline find bar, and `isIncrementalSearchingEnabled` searches as the
/// query is typed. `NSScrollView` already implements `NSTextFinderBarContainer`, so the
/// bar is placed by AppKit; nothing is drawn here.
///
/// The binding is the only source of truth. Edits are written back on every change so
/// Save sees them, and text changed elsewhere (`Insert Default Template`) is pushed in
/// with an undo coalescing break so the two writers undo independently.
struct SearchableTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        guard textView.string != text else { return }
        textView.string = text
        textView.breakUndoCoalescing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: SearchableTextEditor

        init(_ parent: SearchableTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}