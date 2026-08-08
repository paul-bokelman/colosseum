import AppKit
import SwiftUI

/// Notes text with Are.na-style `#tag` coloring (matches block preview notes).
enum ColoredNotesText {
    static func attributed(_ text: String, fontSize: CGFloat = TypeScale.t2) -> AttributedString {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return AttributedString("") }

        let pattern = try! NSRegularExpression(
            pattern: #"(?<![\w/])#([A-Za-z0-9][A-Za-z0-9_-]*)"#,
            options: []
        )
        let font = Font.system(size: fontSize)
        var output = AttributedString()
        var cursor = 0

        for match in pattern.matches(in: text, options: [], range: full) {
            if match.range.location > cursor {
                let range = NSRange(location: cursor, length: match.range.location - cursor)
                var plain = AttributedString(ns.substring(with: range))
                plain.font = font
                plain.foregroundColor = ColosseumTheme.secondaryText
                output += plain
            }
            let tag = ns.substring(with: match.range(at: 1))
            var tagged = AttributedString(ns.substring(with: match.range))
            tagged.font = font
            tagged.foregroundColor = TagColor.color(for: tag)
            output += tagged
            cursor = NSMaxRange(match.range)
        }

        if cursor < full.length {
            var plain = AttributedString(ns.substring(from: cursor))
            plain.font = font
            plain.foregroundColor = ColosseumTheme.secondaryText
            output += plain
        }

        return output
    }
}

/// Single truncated notes line under a grid block.
struct NotesPreviewLine: View {
    let text: String
    /// When non-empty, emphasize matches instead of `#tag` coloring.
    var highlightQuery: String = ""

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if highlightQuery.isEmpty {
                Text(ColoredNotesText.attributed(trimmed.isEmpty ? " " : trimmed, fontSize: TypeScale.t2))
            } else {
                Text(BoardContentSearch.highlightedPreview(
                    trimmed.isEmpty ? " " : trimmed,
                    query: highlightQuery,
                    fontSize: TypeScale.t2
                ))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(trimmed.isEmpty ? 0 : 1)
        .accessibilityHidden(trimmed.isEmpty)
    }
}

/// Square cell + optional one-line notes preview.
struct GridBlockChrome<Content: View>: View {
    let notes: String
    var title: String = ""
    var searchQuery: String = ""
    var isSelected: Bool = false
    var showsNotes: Bool = true
    /// When true, reports the square (not the notes line) for tag-assign elevation.
    var captureTagAssignAnchor: Bool = false
    @ViewBuilder var content: () -> Content

    private var preview: (text: String, highlight: String) {
        BoardContentSearch.gridPreviewLine(notes: notes, title: title, query: searchQuery)
    }

    private var notesVisible: Bool {
        if showsNotes { return true }
        return !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: notesVisible ? 8 : 0) {
            content()
                .gridSelectionRing(isActive: isSelected)
                .anchorPreference(key: TagAssignAnchorKey.self, value: .bounds) {
                    captureTagAssignAnchor ? $0 : nil
                }

            if notesVisible {
                NotesPreviewLine(text: preview.text, highlightQuery: preview.highlight)
                    .frame(height: 16)
            }
        }
    }
}
