import AppKit
import SwiftUI

struct TagPill: View {
    let tag: String
    var isSelected: Bool
    var isFocused: Bool = false
    var action: () -> Void

    private var color: Color { TagColor.color(for: tag) }

    var body: some View {
        Button(action: action) {
            Text(TagParser.displayLabel(tag))
                .font(.system(size: TypeScale.t0))
                .foregroundStyle(isSelected ? color : (isFocused ? ColosseumTheme.primaryText : ColosseumTheme.tertiaryText))
                .overlay(alignment: .bottom) {
                    if isFocused {
                        Rectangle()
                            .fill(ColosseumTheme.primaryText)
                            .frame(height: 1)
                            .offset(y: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .animation(ColosseumMotion.soft, value: isSelected)
        .animation(ColosseumMotion.soft, value: isFocused)
    }
}

/// Plain ∩/∪ glyph matching the column-density icon treatment.
struct TagMatchModeIcon: View {
    @Binding var mode: TagMatchMode

    var body: some View {
        Button {
            withAnimation(ColosseumMotion.soft) {
                mode = mode == .intersection ? .union : .intersection
            }
        } label: {
            Text(mode == .intersection ? "∩" : "∪")
                .font(.system(size: TypeScale.t0, design: .rounded))
                .foregroundStyle(ColosseumTheme.tertiaryText)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            mode == .intersection
                ? "Intersection — items with every selected tag (U to toggle union)."
                : "Union — items with any selected tag (U to toggle intersection)."
        )
        .pointingHandCursor()
    }
}

/// Period toggle — show only untagged blocks (no nested/Are.na boards).
struct UncategorizedFilterIcon: View {
    @Binding var isActive: Bool

    var body: some View {
        Button {
            withAnimation(ColosseumMotion.soft) {
                isActive.toggle()
            }
        } label: {
            Text(".")
                .font(.system(size: TypeScale.t0, design: .monospaced))
                .foregroundStyle(isActive ? ColosseumTheme.primaryText : ColosseumTheme.tertiaryText)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            isActive
                ? "Showing uncategorized blocks only (.). Click to show all."
                : "Uncategorized — blocks with no tags (.)"
        )
        .pointingHandCursor()
        .animation(ColosseumMotion.soft, value: isActive)
    }
}

/// Lowercase `b` toggle — show only nested boards and Are.na channel boards.
struct BoardsOnlyFilterIcon: View {
    @Binding var isActive: Bool

    var body: some View {
        Button {
            withAnimation(ColosseumMotion.soft) {
                isActive.toggle()
            }
        } label: {
            Text("b")
                .font(.system(size: TypeScale.t0, design: .monospaced))
                .foregroundStyle(isActive ? ColosseumTheme.primaryText : ColosseumTheme.tertiaryText)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            isActive
                ? "Showing boards only — nested + Are.na (B). Click to show all."
                : "Boards only — nested + Are.na (B)"
        )
        .pointingHandCursor()
        .animation(ColosseumMotion.soft, value: isActive)
    }
}

/// Centered, horizontally scrollable tag strip for the board header.
struct TagHeaderScroller: View {
    let tags: [String]
    @Binding var selected: Set<String>
    @Binding var selectionOrder: [String]

    private var displayedTags: [String] {
        TagParser.displayedTags(tags, selected: selected, selectionOrder: selectionOrder)
    }

    var body: some View {
        Group {
            if tags.isEmpty {
                Color.clear.frame(width: 1, height: 1)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s2) {
                        ForEach(displayedTags, id: \.self) { tag in
                            let key = TagParser.normalize(tag)
                            TagPill(tag: tag, isSelected: selected.contains(key)) {
                                toggle(tag)
                            }
                        }
                    }
                    .padding(.horizontal, Space.s1)
                }
                .frame(
                    width: ChromeMetrics.headerCenterWidth,
                    height: ChromeMetrics.controlHeight
                )
            }
        }
        .animation(ColosseumMotion.soft, value: selectionOrder)
        .animation(ColosseumMotion.soft, value: selected)
    }

    private func toggle(_ tag: String) {
        let key = TagParser.normalize(tag)
        withAnimation(ColosseumMotion.soft) {
            if selected.contains(key) {
                selected.remove(key)
                selectionOrder.removeAll { $0 == key }
            } else {
                selected.insert(key)
                selectionOrder.removeAll { $0 == key }
                selectionOrder.insert(key, at: 0)
            }
        }
    }
}
