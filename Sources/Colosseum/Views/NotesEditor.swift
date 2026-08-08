import AppKit
import SwiftUI

/// Plain, borderless notes field with live #tag coloring, autocomplete, and ⌘-click to filter.
struct NotesEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "notes…"
    /// Popularity-ranked board tags for `#` autocomplete (existing tags only).
    var suggestionTags: [String] = []
    /// Normalized tag → how many board items currently use it.
    var suggestionCounts: [String: Int] = [:]
    var onTagTap: (String) -> Void
    /// Increment to force the field to become first responder (e.g. Tab in block preview).
    var focusNonce: Int = 0
    /// Fired after edits are committed to the binding (debounced or on end editing).
    var onCommit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = TagAwareTextView()
        textView.delegate = context.coordinator
        textView.onTagTap = onTagTap
        textView.placeholderString = placeholder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor(ColosseumTheme.secondaryText)
        textView.insertionPointColor = ColosseumTheme.nsPrimaryText
        textView.font = .systemFont(ofSize: 13)
        textView.typingAttributes = Coordinator.baseTypingAttributes
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        context.coordinator.applyHighlighting(to: textView)

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.configureSuggest(for: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? TagAwareTextView else { return }
        textView.onTagTap = onTagTap
        textView.placeholderString = placeholder

        // While the user is typing, the text view is source of truth — never clobber it
        // with a stale (debounced) binding value.
        if !context.coordinator.isEditing, textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            context.coordinator.applyHighlighting(to: textView)
            let max = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, max), length: 0))
        }

        if focusNonce != context.coordinator.lastFocusNonce {
            context.coordinator.lastFocusNonce = focusNonce
            DispatchQueue.main.async {
                scroll.window?.makeFirstResponder(textView)
            }
        }

        // Live parent catalogs update outside an active tag token only.
        // Mid-token we keep a frozen session catalog so typing / debounce can't
        // make a "new" tag look pre-existing before Enter or Space.
        if context.coordinator.tagSessionTags == nil {
            context.coordinator.cachedSuggestionTags = suggestionTags
            context.coordinator.cachedSuggestionCounts = suggestionCounts
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let baseTypingAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(ColosseumTheme.secondaryText),
            .font: NSFont.systemFont(ofSize: 13)
        ]

        private static let tagRegex = try! NSRegularExpression(
            pattern: #"(?<![\w/])#([A-Za-z0-9][A-Za-z0-9_-]*)"#,
            options: []
        )

        var parent: NotesEditor
        weak var textView: TagAwareTextView?
        private var applying = false
        var isEditing = false
        var lastFocusNonce = 0
        var cachedSuggestionTags: [String] = []
        var cachedSuggestionCounts: [String: Int] = [:]
        /// Frozen when a `#tag` token becomes active; cleared on Space / Enter / blur.
        var tagSessionTags: [String]?
        var tagSessionCounts: [String: Int]?
        /// Once we offer "new" for this token, keep offering it until the token ends.
        private var stickyNewForToken = false
        let suggest = TagSuggestOverlay()
        /// Keep selection stable across filter updates when the same query family continues.
        private var lastQuery: String?
        private var lastHighlighted: String?
        private var pendingCommit: DispatchWorkItem?

        init(_ parent: NotesEditor) {
            self.parent = parent
            self.cachedSuggestionTags = parent.suggestionTags
            self.cachedSuggestionCounts = parent.suggestionCounts
        }

        private var activeTags: [String] {
            tagSessionTags ?? cachedSuggestionTags
        }

        private var activeCounts: [String: Int] {
            tagSessionCounts ?? cachedSuggestionCounts
        }

        private func beginTagSessionIfNeeded() {
            guard tagSessionTags == nil else { return }
            tagSessionTags = parent.suggestionTags
            tagSessionCounts = parent.suggestionCounts
            cachedSuggestionTags = parent.suggestionTags
            cachedSuggestionCounts = parent.suggestionCounts
        }

        private func endTagSession() {
            tagSessionTags = nil
            tagSessionCounts = nil
            stickyNewForToken = false
            lastQuery = nil
        }

        func configureSuggest(for textView: TagAwareTextView) {
            suggest.onSelect = { [weak self] item in
                self?.accept(item)
            }
            textView.onSuggestCommand = { [weak self] command in
                self?.handleSuggestCommand(command) ?? false
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !applying else { return }
            applyHighlighting(to: textView)
            refreshSuggestions()
            scheduleCommit(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, isEditing else { return }
            refreshSuggestions()
        }

        func textDidEndEditing(_ notification: Notification) {
            suggest.hide()
            endTagSession()
            isEditing = false
            flushCommit()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            handleSuggestCommand(commandSelector)
        }

        private func handleSuggestCommand(_ commandSelector: Selector) -> Bool {
            guard suggest.isVisible else { return false }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                suggest.moveSelection(-1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                suggest.moveSelection(1)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertTab(_:))
                || commandSelector == #selector(NSResponder.insertTabIgnoringFieldEditor(_:)) {
                suggest.acceptSelection()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                suggest.hide()
                lastQuery = nil
                return true
            }
            return false
        }

        private func scheduleCommit(_ value: String) {
            pendingCommit?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.commit(value)
            }
            pendingCommit = work
            // Short debounce keeps SwiftUI/SwiftData off the hot path while typing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }

        private func flushCommit() {
            pendingCommit?.cancel()
            pendingCommit = nil
            guard let textView else { return }
            commit(textView.string)
        }

        private func commit(_ value: String) {
            guard parent.text != value else { return }
            parent.text = value
            parent.onCommit?()
        }

        func refreshSuggestions() {
            guard let textView else {
                suggest.hide()
                return
            }
            guard textView.window?.firstResponder === textView else {
                suggest.hide()
                endTagSession()
                return
            }

            let selected = textView.selectedRange()
            guard selected.length == 0,
                  let edit = TagParser.activeTagEdit(in: textView.string, caret: selected.location)
            else {
                // Space / leaving the token ends the "new" offer.
                suggest.hide()
                endTagSession()
                return
            }

            beginTagSessionIfNeeded()
            let catalog = activeTags
            let counts = activeCounts

            if edit.query.isEmpty {
                stickyNewForToken = false
                let matches = TagParser.autocomplete(query: "", from: catalog, limit: 3)
                guard !matches.isEmpty else {
                    suggest.hide()
                    return
                }
                let items = matches.map { tag -> TagSuggestOverlay.Item in
                    .tag(tag, count: counts[TagParser.normalize(tag)] ?? 0)
                }
                let selectedIndex = (lastQuery == edit.query && suggest.isVisible)
                    ? min(suggest.selectedIndex, items.count - 1)
                    : 0
                lastQuery = edit.query
                presentSuggestions(items, selectedIndex: selectedIndex, in: textView, caret: selected.location)
                return
            }

            let matches = TagParser.autocomplete(
                query: edit.query,
                from: catalog,
                limit: 3
            )
            let queryKey = TagParser.normalize(edit.query)
            // Use the frozen session catalog so debounced note writes can't create a
            // false "already exists" and strip the new pill before Enter / Space.
            if counts[queryKey] == nil {
                stickyNewForToken = true
            }

            var items = matches.map { tag -> TagSuggestOverlay.Item in
                .tag(tag, count: counts[TagParser.normalize(tag)] ?? 0)
            }
            if stickyNewForToken {
                items.append(.newTag(edit.query))
            }
            guard !items.isEmpty else {
                suggest.hide()
                return
            }

            let wasOnNew: Bool = {
                guard suggest.isVisible,
                      suggest.items.indices.contains(suggest.selectedIndex),
                      case .newTag = suggest.items[suggest.selectedIndex]
                else { return false }
                return true
            }()
            let selectedIndex: Int
            if wasOnNew, let newIdx = items.firstIndex(where: {
                if case .newTag = $0 { return true }
                return false
            }) {
                selectedIndex = newIdx
            } else if lastQuery == edit.query, suggest.isVisible {
                selectedIndex = min(suggest.selectedIndex, items.count - 1)
            } else {
                selectedIndex = 0
            }
            lastQuery = edit.query
            presentSuggestions(items, selectedIndex: selectedIndex, in: textView, caret: selected.location)
        }

        private func presentSuggestions(
            _ items: [TagSuggestOverlay.Item],
            selectedIndex: Int,
            in textView: NSTextView,
            caret: Int
        ) {
            let caretRange = NSRange(location: caret, length: 0)
            var rect = textView.firstRect(forCharacterRange: caretRange, actualRange: nil)
            if rect == .zero {
                let local = NSPoint(x: 0, y: textView.bounds.minY)
                let windowPoint = textView.convert(local, to: nil)
                rect = textView.window?.convertToScreen(NSRect(origin: windowPoint, size: .zero)) ?? .zero
            }
            let point = NSPoint(x: rect.minX, y: rect.minY)
            suggest.update(items: items, selectedIndex: selectedIndex, screenPoint: point)
        }

        private func accept(_ item: TagSuggestOverlay.Item) {
            guard let textView else { return }
            let selected = textView.selectedRange()
            guard let edit = TagParser.activeTagEdit(in: textView.string, caret: selected.location)
            else { return }

            let tag = item.tagName
            let replacement = TagParser.displayLabel(tag) + " "
            if textView.shouldChangeText(in: edit.range, replacementString: replacement) {
                textView.replaceCharacters(in: edit.range, with: replacement)
                textView.didChangeText()
                let caret = edit.range.location + (replacement as NSString).length
                textView.setSelectedRange(NSRange(location: caret, length: 0))
            }
            suggest.hide()
            endTagSession()
            applyHighlighting(to: textView)
            flushCommit()
        }

        func applyHighlighting(to textView: NSTextView) {
            let string = textView.string
            // Skip full restyle when content is unchanged (selection-only updates).
            if string == lastHighlighted { return }

            applying = true
            defer { applying = false }

            let storage = textView.textStorage
            let full = NSRange(location: 0, length: storage?.length ?? 0)
            let selected = textView.selectedRange()

            storage?.beginEditing()
            storage?.setAttributes(Self.baseTypingAttributes, range: full)

            var tagRanges: [(NSRange, String)] = []
            if full.length > 0 {
                let matches = Self.tagRegex.matches(in: string, options: [], range: full)
                for match in matches {
                    guard match.numberOfRanges > 1 else { continue }
                    let tagRange = match.range(at: 1)
                    let tag = (string as NSString).substring(with: tagRange)
                    let color = TagColor.nsColor(for: tag)
                    storage?.addAttributes([
                        .foregroundColor: color,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: color.withAlphaComponent(0.35),
                        .cursor: NSCursor.pointingHand
                    ], range: match.range)
                    tagRanges.append((match.range, tag))
                }
            }
            storage?.endEditing()

            if let tagView = textView as? TagAwareTextView {
                tagView.tagRanges = tagRanges
            }
            textView.setSelectedRange(selected)
            lastHighlighted = string
        }
    }
}

final class TagAwareTextView: NSTextView {
    var onTagTap: ((String) -> Void)?
    var tagRanges: [(NSRange, String)] = []
    var placeholderString: String = "notes…"
    /// Return true when a suggest overlay consumed the command.
    var onSuggestCommand: ((Selector) -> Bool)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(ColosseumTheme.tertiaryText),
            .font: font ?? .systemFont(ofSize: 13)
        ]
        let origin = CGPoint(
            x: textContainerOrigin.x + textContainerInset.width,
            y: textContainerOrigin.y + textContainerInset.height
        )
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func doCommand(by selector: Selector) {
        if onSuggestCommand?(selector) == true { return }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(nil)
            return
        }
        super.doCommand(by: selector)
    }

    override func keyDown(with event: NSEvent) {
        // Tab often bypasses doCommand in free-standing NSTextViews; route it
        // through suggest accept the same way Enter does.
        if event.keyCode == 48,
           !event.modifierFlags.contains(.shift),
           onSuggestCommand?(#selector(NSResponder.insertTab(_:))) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if tag(at: event) != nil {
            NSCursor.pointingHand.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if tag(at: event) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let tag = tag(at: event) {
            onTagTap?(tag)
            return
        }
        super.mouseDown(with: event)
    }

    private func tag(at event: NSEvent) -> String? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        for (range, tag) in tagRanges where NSLocationInRange(index, range) {
            return tag
        }
        return nil
    }
}
