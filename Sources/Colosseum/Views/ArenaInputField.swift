import AppKit
import SwiftUI

/// Are.na-style capture field: one large, centered, borderless text area.
///
/// Return inserts a newline; ⌘Return submits. Pasting media (images/files)
/// is intercepted so it can be resolved instead of dropped in as text.
struct ArenaInputField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = TypeScale.t6
    /// Bumped by the parent to pull focus back into the field.
    var focusRequest: Int = 0
    var onSubmit: () -> Void
    /// Return true to swallow the paste (media was handled elsewhere).
    var onPasteMedia: () -> Bool
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Esc while editing — defaults to blurring back to the grid.
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CenteringTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.onPasteMedia = { context.coordinator.parent.onPasteMedia() }
        textView.onFocusChange = { focused in
            let handler = context.coordinator.parent.onFocusChange
            DispatchQueue.main.async { handler(focused) }
        }
        textView.onEscape = {
            let handler = context.coordinator.parent.onEscape
            DispatchQueue.main.async { handler() }
        }

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.allowsUndo = true
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.alignment = .center
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 8, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none

        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CenteringTextView else { return }

        if textView.string != text {
            textView.string = text
            textView.recenter()
        }
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
            textView.recenter()
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ArenaInputField
        weak var textView: CenteringTextView?
        var lastFocusRequest = 0

        init(_ parent: ArenaInputField) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CenteringTextView else { return }
            parent.text = textView.string
            textView.recenter()
        }
    }
}

/// Keeps its content vertically centered, the way are.na's capture pane reads.
final class CenteringTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteMedia: (() -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let hasCommand = event.modifierFlags.contains(.command)
        if isReturn && hasCommand {
            onSubmit?()
            return
        }
        if event.keyCode == 53 { // esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if onPasteMedia?() == true { return }
        pasteAsPlainText(sender)
    }

    override func layout() {
        super.layout()
        recenter()
    }

    /// Adjusts the top inset so the used text rect sits in the middle.
    func recenter() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let available = enclosingScrollView?.contentSize.height ?? bounds.height
        let inset = max(0, (available - used) / 2)
        if abs(textContainerInset.height - inset) > 0.5 {
            textContainerInset = NSSize(width: textContainerInset.width, height: inset)
            needsDisplay = true
        }
    }
}
