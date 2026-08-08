import SwiftData
import SwiftUI

private enum BoardLibraryEntry: Identifiable {
    case board(Board)
    case connection(source: Board, connection: Connection)

    var id: String {
        switch self {
        case .board(let board): return "board-\(board.id.uuidString)"
        case .connection(let source, let connection):
            return "connection-\(source.id.uuidString)-\(connection.id.uuidString)"
        }
    }
}

struct BoardLibraryView: View {
    let boards: [Board]
    var showsToolbar = true
    var onOpen: (Board) -> Void
    var onOpenFlattened: (Board, Connection) -> Void
    var onDelete: (Board) -> Void
    var onCreate: () -> Void
    var onImportArena: () -> Void

    @State private var gridFocusID: String?
    @State private var gridWidth: CGFloat = 900
    @State private var keyMonitor = KeyNavMonitor()
    @FocusState private var homeFocused: Bool
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var flattened = false

    private let minCardWidth: CGFloat = 200

    private var columnCount: Int {
        let inner = max(minCardWidth, gridWidth - 56)
        return max(1, Int((inner + ColosseumTheme.gridGap) / (minCardWidth + ColosseumTheme.gridGap)))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minCardWidth, maximum: 280), spacing: ColosseumTheme.gridGap)]
    }

    private var displayedEntries: [BoardLibraryEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries: [BoardLibraryEntry]
        if flattened {
            entries = boards.flatMap { board in
                board.sortedConnections.map { BoardLibraryEntry.connection(source: board, connection: $0) }
            }
        } else {
            entries = boards.map(BoardLibraryEntry.board)
        }
        guard showSearch, !query.isEmpty else { return entries }
        return entries.filter { entry in
            switch entry {
            case .board(let board):
                return BoardContentSearch.matches([board.title], query: query)
            case .connection(let source, let connection):
                return BoardContentSearch.matches(
                    [source.title, title(for: connection), notes(for: connection)],
                    query: query
                )
            }
        }
    }

    private var filteredListIdentity: GridListIdentity<String> {
        var hasher = Hasher()
        hasher.combine(boards.count)
        hasher.combine(showSearch)
        hasher.combine(searchQuery)
        hasher.combine(flattened)
        if let first = boards.first { hasher.combine(first.updatedAt.timeIntervalSinceReferenceDate) }
        if let last = boards.last { hasher.combine(last.updatedAt.timeIntervalSinceReferenceDate) }
        return GridListIdentity(
            count: displayedEntries.count,
            firstID: displayedEntries.first?.id,
            lastID: displayedEntries.last?.id,
            revision: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    /// Grid nav active (not while the search field owns typing).
    private var isBrowsingGrid: Bool { showsToolbar && !showSearch }
    /// Keep the key monitor alive during search so Esc still dismisses.
    private var ownsKeyboard: Bool { showsToolbar }

    var body: some View {
        libraryContent
            .background(ColosseumTheme.canvas)
            .navigationTitle("")
            .navigationBarBackButtonHidden(true)
            .toolbarBackground(ColosseumTheme.canvas, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbarColorScheme(.dark, for: .windowToolbar)
            .toolbar { libraryToolbar }
            .focusable()
            .focused($homeFocused)
            .focusEffectDisabled()
            .onAppear { syncHomeKeyboard() }
            .onDisappear { keyMonitor.remove() }
            .onChange(of: showsToolbar) { _, active in
                if !active { dismissSearch() }
                syncHomeKeyboard()
            }
            .onChange(of: ownsKeyboard) { _, owns in
                if owns {
                    syncHomeKeyboard()
                } else {
                    keyMonitor.remove()
                }
            }
            .onChange(of: showSearch) { _, searching in
                if !searching, ownsKeyboard {
                    syncHomeKeyboard()
                }
            }
            .onChange(of: filteredListIdentity) { _, _ in
                gridFocusID = GridListIdentity.revalidatedFocus(
                gridFocusID,
                    in: displayedEntries.lazy.map(\.id)
                )
            }
            .onExitCommand {
                if showSearch {
                    withAnimation(ColosseumMotion.overlay) {
                        dismissSearch()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .colosseumSearch)) { _ in
                guard showsToolbar else { return }
                toggleSearch()
            }
            .animation(ColosseumMotion.overlay, value: showSearch)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if showsToolbar {
                ColosseumCenterHeaderToolbar(
                    isSearching: showSearch,
                    searchQuery: $searchQuery,
                    placeholder: "Search boards…",
                    visible: true,
                    onDismissSearch: {
                        withAnimation(ColosseumMotion.overlay) {
                            dismissSearch()
                        }
                    }
                ) {
                    Color.clear
                        .frame(
                            width: ChromeMetrics.headerCenterWidth,
                            height: ChromeMetrics.controlHeight
                        )
                }
                ToolbarItem(placement: .primaryAction) {
                    FlattenToggleIcon(isActive: $flattened)
                        .padding(.trailing, max(0, ChromeMetrics.contentInset - 10))
                }
                .colosseumPlainToolbarItem()
            }
        }

    private var libraryContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                libraryScrollBody
            }
            .onPreferenceChange(HomeGridWidthKey.self) { gridWidth = $0 }
            .onChange(of: gridFocusID) { _, id in
                guard let id, isBrowsingGrid else { return }
                withAnimation(ColosseumMotion.soft) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var libraryScrollBody: some View {
        if boards.isEmpty {
            emptyState
        } else if displayedEntries.isEmpty {
            Text(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (flattened ? "No blocks in these boards" : "Type to filter boards")
                : "No boards match")
                .font(.system(size: TypeScale.t2))
                .foregroundStyle(ColosseumTheme.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s9)
        } else {
            boardGrid
        }
    }

    private var boardGrid: some View {
        LazyVGrid(columns: columns, spacing: ColosseumTheme.gridGap) {
            ForEach(displayedEntries) { entry in
                switch entry {
                case .board(let board):
                    boardCell(board, entryID: entry.id)
                case .connection(let source, let connection):
                    flattenedConnectionCell(source: source, connection: connection, entryID: entry.id)
                }
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.top, Space.s4)
        .padding(.bottom, Space.s7)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HomeGridWidthKey.self, value: geo.size.width)
            }
        )
        .animation(ColosseumMotion.soft, value: filteredListIdentity)
    }

    private func boardCell(_ board: Board, entryID: String) -> some View {
        let focused = entryID == gridFocusID && isBrowsingGrid
        return Button {
            gridFocusID = entryID
            onOpen(board)
        } label: {
            BoardCardView(
                board: board,
                searchQuery: showSearch ? searchQuery : ""
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .id(entryID)
        .contextMenu {
            Button("Delete board", role: .destructive) {
                onDelete(board)
            }
        }
        .overlay {
            if focused {
                focusRing
            }
        }
    }

    private func flattenedConnectionCell(
        source: Board,
        connection: Connection,
        entryID: String
    ) -> some View {
        let focused = entryID == gridFocusID && isBrowsingGrid
        return Button {
            gridFocusID = entryID
            onOpenFlattened(source, connection)
        } label: {
            GridBlockChrome(
                notes: notes(for: connection),
                title: title(for: connection),
                searchQuery: showSearch ? searchQuery : "",
                isSelected: focused,
                showsNotes: true
            ) {
                connectionContent(connection)
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .id(entryID)
        .help("From \(source.title)")
    }

    @ViewBuilder
    private func connectionContent(_ connection: Connection) -> some View {
        if let nested = connection.nestedBoard {
            NestedBoardCell(board: nested)
        } else if let block = connection.block {
            switch block.kind {
            case .image, .video, .audio: MediaBlockCell(block: block)
            case .text: TextBlockCell(block: block)
            case .link: LinkBlockCell(block: block)
            case .arenaChannel: ArenaBlockCell(block: block)
            }
        }
    }

    private func title(for connection: Connection) -> String {
        connection.nestedBoard?.title ?? connection.block?.title ?? ""
    }

    private func notes(for connection: Connection) -> String {
        connection.nestedBoard?.notes ?? connection.block?.notes ?? ""
    }

    private var focusRing: some View {
        let gap = ColosseumTheme.selectionRingGap
        let lineWidth = ColosseumTheme.selectionRingWidth
        let outset = gap + lineWidth / 2
        return Rectangle()
            .stroke(ColosseumTheme.selectionRingColor, lineWidth: lineWidth)
            .padding(.bottom, 22 - outset)
            .padding(.top, -outset)
            .padding(.horizontal, -outset)
            .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: Space.s2) {
            Text("No boards yet")
                .font(.system(size: TypeScale.t3))
                .foregroundStyle(ColosseumTheme.primaryText)
            Text("Create a board with ⌘↩, or import with ⌘I.")
                .font(.system(size: TypeScale.t1))
                .foregroundStyle(ColosseumTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.s9)
        .padding(.horizontal, Space.s7)
    }

    private func toggleSearch() {
        withAnimation(ColosseumMotion.overlay) {
            if showSearch {
                dismissSearch()
            } else {
                searchQuery = ""
                showSearch = true
            }
        }
    }

    private func dismissSearch() {
        showSearch = false
        searchQuery = ""
        syncHomeKeyboard()
    }

    private func syncHomeKeyboard() {
        guard ownsKeyboard else {
            keyMonitor.remove()
            return
        }
        homeFocused = true
        keyMonitor.onLeft = { moveFocus(delta: -1) }
        keyMonitor.onRight = { moveFocus(delta: 1) }
        keyMonitor.onUp = { moveFocus(delta: -columnCount) }
        keyMonitor.onDown = { moveFocus(delta: columnCount) }
        keyMonitor.onEnter = { openFocused() }
        keyMonitor.onCharacter = { character in
            guard character == "f", isBrowsingGrid else { return false }
            DispatchQueue.main.async {
                withAnimation(ColosseumMotion.soft) { flattened.toggle() }
            }
            return true
        }
        keyMonitor.onEscape = {
            if showSearch {
                withAnimation(ColosseumMotion.overlay) {
                    dismissSearch()
                }
            }
        }
        // While searching, ignore arrows/enter but still route Esc (incl. from the text field).
        keyMonitor.shouldIgnoreNavigation = { !isBrowsingGrid }
        keyMonitor.install()
        DispatchQueue.main.async {
            homeFocused = true
            if gridFocusID == nil {
                gridFocusID = displayedEntries.first?.id
            }
        }
    }

    private func moveFocus(delta: Int) {
        guard isBrowsingGrid, !displayedEntries.isEmpty else { return }
        homeFocused = true
        if let idx = displayedEntries.firstIndex(where: { $0.id == gridFocusID }) {
            let next = idx + delta
            guard next >= 0, next < displayedEntries.count else { return }
            withAnimation(ColosseumMotion.soft) {
                gridFocusID = displayedEntries[next].id
            }
        } else {
            withAnimation(ColosseumMotion.soft) {
                gridFocusID = displayedEntries[0].id
            }
        }
    }

    private func openFocused() {
        guard isBrowsingGrid else { return }
        let entry = displayedEntries.first(where: { $0.id == gridFocusID }) ?? displayedEntries.first
        guard let entry else { return }
        gridFocusID = entry.id
        switch entry {
        case .board(let board): onOpen(board)
        case .connection(let source, let connection): onOpenFlattened(source, connection)
        }
    }
}

private struct HomeGridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct BoardCardView: View {
    let board: Board
    var searchQuery: String = ""

    private var caption: (text: String, highlight: String) {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return (board.title, "") }
        if board.title.localizedCaseInsensitiveContains(query) {
            return (BoardContentSearch.matchSnippet(in: board.title, query: query), query)
        }
        return (board.title, "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            ZStack {
                Rectangle()
                    .fill(ColosseumTheme.surface)
                VStack(spacing: Space.s1) {
                    Text(board.title)
                        .font(.system(size: TypeScale.t3))
                        .foregroundStyle(ColosseumTheme.primaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text("\(board.contentCount) blocks")
                        .font(.system(size: TypeScale.t0))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                    Text(ColosseumFormatters.relativeDate(board.updatedAt))
                        .font(.system(size: TypeScale.t0))
                        .foregroundStyle(ColosseumTheme.tertiaryText)
                    Text(ColosseumFormatters.byteCount(board.storageBytes))
                        .font(.system(size: TypeScale.t0))
                        .foregroundStyle(ColosseumTheme.tertiaryText)
                }
                .padding(Space.s3)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))

            NotesPreviewLine(text: caption.text, highlightQuery: caption.highlight)
                .frame(height: 16)
        }
    }
}
