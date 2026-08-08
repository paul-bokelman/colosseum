import AppKit
import SwiftUI

enum ChromeMetrics {
    /// Are.na control sizes: sm 24, md 34. Icon buttons match the md height so they
    /// sit level with text buttons in a shared row (Are.na's 24 icon is standalone).
    static let controlHeight: CGFloat = 34
    static let controlHeightSmall: CGFloat = 24
    static let iconButtonWidth: CGFloat = 34
    static let controlRadius: CGFloat = 3
    static let homeIconSize: CGFloat = 22
    static let boardColumnsMin = 2
    static let boardColumnsMax = 8
    static let boardColumnsDefault = 4
    /// Magnification delta required to move one column step (higher = less sensitive).
    static let pinchStepThreshold: CGFloat = 0.22
    /// Match board grid content inset so trailing toolbar controls line up.
    static let contentInset: CGFloat = Space.s5
    /// Centered tag strip / search field width in the window header.
    static let headerCenterWidth: CGFloat = 400

    static var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: controlRadius)
    }
}

/// Bordered chrome control matching the home Import button look.
struct ChromeButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: TypeScale.t2, weight: .bold))
            .foregroundStyle(emphasized ? ColosseumTheme.canvas : ColosseumTheme.linkText)
            // Are.na: white-space: nowrap; flex-shrink: 0. A label never wraps to
            // fit its row — the row gives way instead.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Space.s3)
            .frame(height: ChromeMetrics.controlHeight)
            .background(
                emphasized ? ColosseumTheme.linkText : ColosseumTheme.surface,
                in: ChromeMetrics.controlShape
            )
            .overlay(ChromeMetrics.controlShape.stroke(ColosseumTheme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ChromeIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: TypeScale.t1))
            .foregroundStyle(active ? ColosseumTheme.primaryText : ColosseumTheme.secondaryText)
            .frame(width: ChromeMetrics.iconButtonWidth, height: ChromeMetrics.controlHeight)
            .background(
                active ? ColosseumTheme.elevated : ColosseumTheme.surface,
                in: ChromeMetrics.controlShape
            )
            .overlay(ChromeMetrics.controlShape.stroke(ColosseumTheme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// DESIGN.md §6.2. Never `.roundedBorder` — the system style is not part of the language.
struct ColosseumFieldBackground: ViewModifier {
    var focused: Bool
    var prominent = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: prominent ? TypeScale.t3 : TypeScale.t2))
            .foregroundStyle(ColosseumTheme.primaryText)
            .padding(.horizontal, Space.s3)
            .frame(height: prominent ? Space.s7 : ChromeMetrics.controlHeight)
            .background(ColosseumTheme.surface, in: ChromeMetrics.controlShape)
            .overlay(
                ChromeMetrics.controlShape.stroke(
                    focused ? ColosseumTheme.focus : ColosseumTheme.border,
                    lineWidth: 1
                )
            )
            .focusEffectDisabled()
    }
}

extension View {
    func colosseumField(focused: Bool = false, prominent: Bool = false) -> some View {
        modifier(ColosseumFieldBackground(focused: focused, prominent: prominent))
    }
}

struct ShortcutHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: TypeScale.t0, design: .monospaced))
            .foregroundStyle(ColosseumTheme.tertiaryText)
            .contentShape(Rectangle())
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func colosseumPlainToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

struct WindowContainerBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(ColosseumTheme.canvas, for: .window)
        } else {
            content
        }
    }
}

/// Keeps window titlebar/toolbar chrome identical across board transitions.
struct WindowChromeStabilizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        if #available(macOS 15.0, *) {
            window.isMovableByWindowBackground = true
        }
    }
}

/// Breadcrumb path: older segments fade; current is full opacity (and optionally tinted).
struct BoardPathBreadcrumb: View {
    let segments: [BoardPathSegment]
    var currentColor: Color = ColosseumTheme.primaryText
    var onSegmentTap: (Int) -> Void

    private struct DisplaySegment: Identifiable {
        let id: String
        let title: String
        let originalIndex: Int
        let helpTitle: String
    }

    private var displaySegments: [DisplaySegment] {
        guard segments.count > 3 else {
            return segments.enumerated().map { index, segment in
                DisplaySegment(
                    id: segment.id,
                    title: segment.title,
                    originalIndex: index,
                    helpTitle: segment.title
                )
            }
        }

        let lastHiddenIndex = segments.count - 3
        let visibleIndices = [0, segments.count - 2, segments.count - 1]
        return [
            DisplaySegment(
                id: segments[0].id,
                title: segments[0].title,
                originalIndex: 0,
                helpTitle: segments[0].title
            ),
            DisplaySegment(
                id: "collapsed-middle",
                title: "…",
                originalIndex: lastHiddenIndex,
                helpTitle: segments[lastHiddenIndex].title
            )
        ] + visibleIndices.dropFirst().map { index in
            DisplaySegment(
                id: segments[index].id,
                title: segments[index].title,
                originalIndex: index,
                helpTitle: segments[index].title
            )
        }
    }

    var body: some View {
        HStack(spacing: Space.s1) {
            ForEach(Array(displaySegments.enumerated()), id: \.element.id) { displayIndex, segment in
                HStack(spacing: Space.s1) {
                    if displayIndex > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: TypeScale.t0, weight: .bold))
                            .foregroundStyle(ColosseumTheme.tertiaryText)
                    }
                    let isCurrent = segment.originalIndex == segments.count - 1
                    let opacity = breadcrumbOpacity(index: segment.originalIndex, count: segments.count)
                    Text(segment.title)
                        .font(.system(size: TypeScale.t2))
                        .foregroundStyle(isCurrent ? currentColor : ColosseumTheme.primaryText)
                        .opacity(opacity)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isCurrent else { return }
                            onSegmentTap(segment.originalIndex)
                        }
                        .pointingHandCursor(enabled: !isCurrent)
                        .help(isCurrent ? segment.helpTitle : "Go to \(segment.helpTitle)")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        // Path transitions should move app content, not interpolate toolbar glyphs.
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func breadcrumbOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        if index == count - 1 { return 1 }
        // Older boards sit further back.
        let stepsFromCurrent = count - 1 - index
        return max(0.28, 1.0 - Double(stepsFromCurrent) * 0.28)
    }
}

/// Board-only leading chrome (path). App icon lives on RootView so it never shifts.
struct ColosseumBoardHeaderToolbar: ToolbarContent {
    let segments: [BoardPathSegment]
    var currentColor: Color = ColosseumTheme.primaryText
    var onSegmentTap: (Int) -> Void

    /// Convenience for a single-title board (no nesting).
    init(
        title: String,
        currentColor: Color = ColosseumTheme.primaryText,
        onTitleTap: @escaping () -> Void
    ) {
        self.segments = [BoardPathSegment(id: "current", title: title)]
        self.currentColor = currentColor
        self.onSegmentTap = { _ in onTitleTap() }
    }

    init(
        segments: [BoardPathSegment],
        currentColor: Color = ColosseumTheme.primaryText,
        onSegmentTap: @escaping (Int) -> Void
    ) {
        self.segments = segments
        self.currentColor = currentColor
        self.onSegmentTap = onSegmentTap
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            BoardPathBreadcrumb(
                segments: segments,
                currentColor: currentColor,
                onSegmentTap: onSegmentTap
            )
            .frame(height: ChromeMetrics.controlHeight, alignment: .center)
        }
        .colosseumPlainToolbarItem()
    }
}

struct ColumnDensityControl: View {
    @Binding var columnCount: Int

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: TypeScale.t0))
                .foregroundStyle(ColosseumTheme.tertiaryText)

            Slider(
                value: Binding(
                    get: { Double(columnCount) },
                    set: { columnCount = Int($0.rounded()) }
                ),
                in: Double(ChromeMetrics.boardColumnsMin)...Double(ChromeMetrics.boardColumnsMax),
                step: 1
            )
            .controlSize(.mini)
            .tint(ColosseumTheme.borderStrong)
            .frame(width: 88)

            Text("\(columnCount)")
                .font(.system(size: TypeScale.t0, design: .monospaced))
                .foregroundStyle(ColosseumTheme.tertiaryText)
                .frame(width: 15, alignment: .trailing)
        }
        .help("Items per column")
    }
}

struct ColosseumColumnSliderToolbar: ToolbarContent {
    @Binding var columnCount: Int
    @Binding var tagMatchMode: TagMatchMode
    @Binding var boardsOnly: Bool
    @Binding var uncategorizedOnly: Bool
    var flattened: Binding<Bool>? = nil
    var showTagMode = false
    var showBoardsFilter = true
    var showUncategorizedFilter = true
    var isImporting = false
    var visible = true

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(alignment: .center, spacing: Space.s2) {
                if isImporting {
                    ProgressView().controlSize(.small)
                }
                if showUncategorizedFilter {
                    UncategorizedFilterIcon(isActive: $uncategorizedOnly)
                }
                if let flattened {
                    FlattenToggleIcon(isActive: flattened)
                }
                if showBoardsFilter {
                    BoardsOnlyFilterIcon(isActive: $boardsOnly)
                }
                if showTagMode {
                    TagMatchModeIcon(mode: $tagMatchMode)
                }
                ColumnDensityControl(columnCount: $columnCount)
            }
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(ColosseumMotion.overlay, value: visible)
            // System toolbar already insets a bit; pad the rest to match grid content (28).
            .padding(.trailing, max(0, ChromeMetrics.contentInset - Space.s2))
        }
        .colosseumPlainToolbarItem()
    }
}

struct FlattenToggleIcon: View {
    @Binding var isActive: Bool

    var body: some View {
        Button {
            withAnimation(ColosseumMotion.soft) { isActive.toggle() }
        } label: {
            Text("f")
                .font(.system(size: TypeScale.t0, design: .monospaced))
                .foregroundStyle(isActive ? ColosseumTheme.primaryText : ColosseumTheme.tertiaryText)
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "Flattened (F). Click to show child boards." : "Flatten child boards (F)")
        .pointingHandCursor()
        .animation(ColosseumMotion.soft, value: isActive)
    }
}

/// Compact search field for the centered header slot (home / board / remote).
struct BoardHeaderSearchField: View {
    @Binding var query: String
    var placeholder: String = "Search…"
    var onDismiss: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: TypeScale.t1))
                .foregroundStyle(ColosseumTheme.tertiaryText)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.t1))
                .foregroundStyle(ColosseumTheme.primaryText)
                .focused($focused)
                .onExitCommand {
                    onDismiss?()
                }
        }
        .frame(
            width: ChromeMetrics.headerCenterWidth,
            height: ChromeMetrics.controlHeight,
            alignment: .leading
        )
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// Shared principal header slot: idle content ↔ search field (fixed width, opacity swap).
struct ColosseumCenterHeaderToolbar<Idle: View>: ToolbarContent {
    var isSearching: Bool
    @Binding var searchQuery: String
    var placeholder: String = "Search…"
    var visible = true
    var onDismissSearch: (() -> Void)?
    @ViewBuilder var idle: () -> Idle

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ColosseumCenterHeaderSlot(
                isSearching: isSearching,
                searchQuery: $searchQuery,
                placeholder: placeholder,
                visible: visible,
                onDismissSearch: onDismissSearch,
                idle: idle
            )
        }
        .colosseumPlainToolbarItem()
    }
}

/// Center slot content used by window toolbar and Arena inline chrome.
struct ColosseumCenterHeaderSlot<Idle: View>: View {
    var isSearching: Bool
    @Binding var searchQuery: String
    var placeholder: String = "Search…"
    var visible = true
    var onDismissSearch: (() -> Void)?
    @ViewBuilder var idle: () -> Idle

    var body: some View {
        ZStack {
            if isSearching {
                BoardHeaderSearchField(
                    query: $searchQuery,
                    placeholder: placeholder,
                    onDismiss: onDismissSearch
                )
                .transition(.opacity)
            } else {
                idle()
                    .transition(.opacity)
            }
        }
        .frame(width: ChromeMetrics.headerCenterWidth, height: ChromeMetrics.controlHeight)
        .opacity(visible || isSearching ? 1 : 0)
        .allowsHitTesting(visible || isSearching)
        .animation(ColosseumMotion.overlay, value: isSearching)
        .animation(ColosseumMotion.overlay, value: visible)
    }
}

/// Centered tag strip / search field in the window toolbar (same row as path + density).
struct ColosseumTagHeaderToolbar: ToolbarContent {
    let tags: [String]
    @Binding var selected: Set<String>
    @Binding var selectionOrder: [String]
    var isSearching = false
    @Binding var searchQuery: String
    var visible = true
    var onDismissSearch: (() -> Void)?

    var body: some ToolbarContent {
        ColosseumCenterHeaderToolbar(
            isSearching: isSearching,
            searchQuery: $searchQuery,
            visible: visible,
            onDismissSearch: onDismissSearch
        ) {
            if tags.isEmpty {
                Color.clear
                    .frame(
                        width: ChromeMetrics.headerCenterWidth,
                        height: ChromeMetrics.controlHeight
                    )
            } else {
                TagHeaderScroller(
                    tags: tags,
                    selected: $selected,
                    selectionOrder: $selectionOrder
                )
                .frame(
                    width: ChromeMetrics.headerCenterWidth,
                    height: ChromeMetrics.controlHeight,
                    alignment: .center
                )
            }
        }
    }
}

struct AppHomeButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let image = Bundle.module.image(forResource: "AppIcon") {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: TypeScale.t3))
                        .foregroundStyle(ColosseumTheme.primaryText)
                }
            }
            .frame(width: ChromeMetrics.homeIconSize, height: ChromeMetrics.homeIconSize)
            .frame(height: ChromeMetrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Boards")
        .pointingHandCursor()
    }
}
