import AppKit
import SwiftUI

/// Shared title/notes matching + note-line snippets for home, board, and remote grids.
enum BoardContentSearch {
    static func matches(_ haystacks: [String], query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return haystacks.contains { !$0.isEmpty && $0.localizedCaseInsensitiveContains(q) }
    }

    /// Collapse whitespace to a single line for grid / list previews.
    static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One-line snippet centered on the first case-insensitive match.
    static func matchSnippet(in text: String, query: String, radius: Int = 40) -> String {
        let collapsed = singleLine(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !collapsed.isEmpty else { return collapsed }

        let ns = collapsed as NSString
        let found = ns.range(of: q, options: [.caseInsensitive])
        guard found.location != NSNotFound else { return collapsed }

        let start = max(0, found.location - radius)
        let end = min(ns.length, NSMaxRange(found) + radius)
        var snippet = ns.substring(with: NSRange(location: start, length: end - start))
        if start > 0 { snippet = "…" + snippet }
        if end < ns.length { snippet += "…" }
        return snippet
    }

    /// Notes line under a grid cell while searching: prefer notes match, else title.
    static func gridPreviewLine(notes: String, title: String, query: String) -> (text: String, highlight: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return (notes, "") }
        if notes.localizedCaseInsensitiveContains(q) {
            return (matchSnippet(in: notes, query: q), q)
        }
        if title.localizedCaseInsensitiveContains(q) {
            return (matchSnippet(in: title, query: q), q)
        }
        return (notes, "")
    }

    /// Case-insensitive attributed preview with matching spans emphasized (grid note line).
    static func highlightedPreview(_ text: String, query: String, fontSize: CGFloat = TypeScale.t2) -> AttributedString {
        var output = AttributedString(text.isEmpty ? " " : text)
        output.font = .system(size: fontSize)
        output.foregroundColor = ColosseumTheme.secondaryText

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !text.isEmpty else { return output }

        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: q, options: [.caseInsensitive], range: search)
            if found.location == NSNotFound { break }
            if let swiftRange = Range(found, in: text),
               let attrRange = Range(swiftRange, in: output) {
                output[attrRange].font = .system(size: fontSize, weight: .bold)
                output[attrRange].foregroundColor = ColosseumTheme.primaryText
            }
            let next = found.location + max(found.length, 1)
            if next >= ns.length { break }
            search = NSRange(location: next, length: ns.length - next)
        }
        return output
    }
}
