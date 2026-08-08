import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum FlattenedBoardEntry: Identifiable {
    case local(source: Board, connection: Connection)
    case remote(source: ArenaBrowseTarget, item: ArenaContentItem)

    var id: String {
        switch self {
        case .local(let source, let connection):
            return "local-\(source.id.uuidString)-\(connection.id.uuidString)"
        case .remote(let source, let item):
            return "remote-\(source.slug)-\(item.id)"
        }
    }
}

struct BoardOverviewView: View {
    @Bindable var board: Board
    @Binding var path: [UUID]
    @Binding var returnPreviewConnections: [UUID: UUID]
    var initialConnectionID: UUID? = nil
    var onInitialConnectionConsumed: () -> Void = {}

    @Environment(\.modelContext) private var context
    @ObservedObject private var overlays = OverlayPresentation.shared
    @Query(sort: \Board.updatedAt, order: .reverse) private var allBoards: [Board]

    @State private var selectedConnectionID: UUID?
    @State private var arenaBrowseTarget: ArenaBrowseTarget?
    @State private var arenaStack: [ArenaBrowseTarget] = []
    /// Scroll/identity anchor for the inline add cell.
    private static let addCellID = "colosseum.addCell"
    @State private var addActivateRequest = 0
    @State private var showConnectBoard = false
    @State private var showRename = false
    @State private var renameTitle = ""
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var isTargeted = false
    @State private var selectedTags: Set<String> = []
    @State private var tagSelectionOrder: [String] = []
    @State private var tagMatchMode: TagMatchMode = .intersection
    @State private var boardsOnly = false
    @State private var uncategorizedOnly = false
    @AppStorage("boardColumnCount") private var columnCount = ChromeMetrics.boardColumnsDefault
    @AppStorage("showGridNotes") private var showGridNotes = true
    @State private var pinchBaseColumns: Int?
    @State private var lastPinchStep = 0
    @State private var isPinching = false
    @State private var pinchDidChange = false
    @State private var suppressGridClicksUntil: Date?
    @State private var gridFocusID: UUID?
    @State private var boardKeyMonitor = KeyNavMonitor()
    @FocusState private var boardFocused: Bool
    /// Keyboard tag-assign: T focuses the block, popover for multi-select; Esc exits.
    @State private var isAssigningTag = false
    @State private var tagAssignFocusIndex = 0
    /// Soft-removed connections that can be restored with undo (max 3).
    @State private var removalUndoStack: [RemovalUndoEntry] = []
    @State private var showBoardSearch = false
    @State private var boardSearchQuery = ""
    @State private var flattened = false
    @State private var flattenedFocusID: String?
    @State private var flattenedRemoteContents: [String: [ArenaContentItem]] = [:]
    @State private var isLoadingFlattenedContents = false
    @State private var flattenedSelectedBoardID: UUID?
    @State private var flattenedSelectedConnectionID: UUID?
    @State private var arenaInitialSelectedItem: ArenaContentItem?
    @State private var arenaInitialSelectedSiblings: [ArenaContentItem] = []

    private struct RemovalUndoEntry {
        let boardID: UUID
        let position: Int
        let blockID: UUID?
        let nestedBoardID: UUID?
    }

    private var isBrowsingGrid: Bool {
        selectedConnectionID == nil
            && flattenedSelectedConnectionID == nil
            && arenaBrowseTarget == nil
            && !showBoardSearch
    }

    /// Board owns the key monitor whenever the local grid (or its search field) is up.
    private var ownsBoardKeyboard: Bool {
        selectedConnectionID == nil
            && flattenedSelectedConnectionID == nil
            && arenaBrowseTarget == nil
    }

    private var pathSegments: [BoardPathSegment] {
        let segments = path.compactMap { id -> BoardPathSegment? in
            guard let match = allBoards.first(where: { $0.id == id }) else { return nil }
            let title = match.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return BoardPathSegment(
                id: id.uuidString,
                title: title.isEmpty ? "Untitled" : title
            )
        }
        if segments.isEmpty {
            let title = board.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return [BoardPathSegment(
                id: board.id.uuidString,
                title: title.isEmpty ? "Untitled" : title
            )]
        }
        return segments
    }

    private var arenaPathSegments: [BoardPathSegment] {
        arenaStack.map {
            BoardPathSegment(id: $0.slug, title: $0.title?.isEmpty == false ? $0.title! : $0.slug)
        }
    }

    /// Local board trail + remote trail so the originating board stays visible.
    private var arenaBreadcrumbSegments: [BoardPathSegment] {
        pathSegments + arenaPathSegments
    }

    private var tagAssignConnection: Connection? {
        guard isAssigningTag, let gridFocusID else { return nil }
        return connections.first(where: { $0.id == gridFocusID })
    }

    private var tagAssignSelectedKeys: Set<String> {
        guard let connection = tagAssignConnection else { return [] }
        return TagParser.tags(for: connection)
    }

    private var focusedAssignTagKey: String? {
        guard isAssigningTag, availableTags.indices.contains(tagAssignFocusIndex) else { return nil }
        return TagParser.normalize(availableTags[tagAssignFocusIndex])
    }

    private var shouldSuppressGridClicks: Bool {
        if isAssigningTag { return true }
        if isPinching { return true }
        if let until = suppressGridClicksUntil, Date() < until { return true }
        return false
    }

    private var columns: [GridItem] {
        let count = min(max(columnCount, ChromeMetrics.boardColumnsMin), ChromeMetrics.boardColumnsMax)
        return Array(
            repeating: GridItem(.flexible(minimum: 72), spacing: ColosseumTheme.gridGap),
            count: count
        )
    }

    private var connections: [Connection] {
        board.sortedConnections
    }

    private var availableTags: [String] {
        TagParser.boardTags(from: connections)
    }

    private var filteredConnections: [Connection] {
        var result = connections
        if uncategorizedOnly {
            result = result.filter { connection in
                if connection.nestedBoard != nil { return false }
                guard let block = connection.block, block.kind != .arenaChannel else { return false }
                return TagParser.tags(for: connection).isEmpty
            }
        } else if boardsOnly {
            result = result.filter { connection in
                if connection.nestedBoard != nil { return true }
                if connection.block?.kind == .arenaChannel { return true }
                return false
            }
        }
        if !uncategorizedOnly, !selectedTags.isEmpty {
            result = result.filter {
                TagParser.matches(connection: $0, selected: selectedTags, mode: tagMatchMode)
            }
        }
        let query = boardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if showBoardSearch, !query.isEmpty {
            result = result.filter { connectionMatchesSearch($0, query: query) }
        }
        return result
    }

    /// Cheap token for animation / focus invalidation (avoids `map(\.id)` allocations).
    private var filteredListIdentity: GridListIdentity<UUID> {
        var hasher = Hasher()
        hasher.combine(board.updatedAt.timeIntervalSinceReferenceDate)
        hasher.combine(boardsOnly)
        hasher.combine(uncategorizedOnly)
        hasher.combine(tagMatchMode)
        hasher.combine(selectedTags)
        hasher.combine(showBoardSearch)
        hasher.combine(boardSearchQuery)
        return GridListIdentities.connections(
            filteredConnections,
            revision: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    private func connectionMatchesSearch(_ connection: Connection, query: String) -> Bool {
        if let nested = connection.nestedBoard {
            return BoardContentSearch.matches([nested.title, nested.notes], query: query)
        }
        if let block = connection.block {
            return BoardContentSearch.matches([block.title, block.notes], query: query)
        }
        return false
    }

    private var selectedConnection: Connection? {
        connections.first(where: { $0.id == selectedConnectionID })
    }

    private var flattenedSelectedBoard: Board? {
        guard let flattenedSelectedBoardID else { return nil }
        return allBoards.first { $0.id == flattenedSelectedBoardID }
    }

    private var flattenedEntries: [FlattenedBoardEntry] {
        connections.flatMap { connection -> [FlattenedBoardEntry] in
            if let nested = connection.nestedBoard {
                return nested.sortedConnections.map {
                    FlattenedBoardEntry.local(source: nested, connection: $0)
                }
            }
            if let block = connection.block,
               block.kind == .arenaChannel,
               let slug = block.arenaSlug,
               let contents = flattenedRemoteContents[slug] {
                let source = ArenaBrowseTarget(block: block)
                return contents.map { FlattenedBoardEntry.remote(source: source, item: $0) }
            }
            return [.local(source: board, connection: connection)]
        }
        .filter(matchesFlattenedFilters(_:))
    }

    private var flattenedListIdentity: GridListIdentity<String> {
        var hasher = Hasher()
        hasher.combine(board.updatedAt.timeIntervalSinceReferenceDate)
        hasher.combine(boardsOnly)
        hasher.combine(uncategorizedOnly)
        hasher.combine(tagMatchMode)
        hasher.combine(selectedTags)
        hasher.combine(showBoardSearch)
        hasher.combine(boardSearchQuery)
        hasher.combine(flattenedRemoteContents.count)
        for slug in flattenedRemoteContents.keys.sorted() {
            hasher.combine(slug)
            hasher.combine(flattenedRemoteContents[slug]?.count ?? 0)
        }
        return GridListIdentity(
            count: flattenedEntries.count,
            firstID: flattenedEntries.first?.id,
            lastID: flattenedEntries.last?.id,
            revision: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    private var importErrorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    var body: some View {
        applyBoardInteractions(to: applyBoardChrome(to: boardStack))
            .animation(ColosseumMotion.overlay, value: showBoardSearch)
            .onNotification(.colosseumSearch) {
                toggleBoardSearch()
            }
            .onChange(of: showBoardSearch) { _, searching in
                guard ownsBoardKeyboard else { return }
                if searching {
                    installBoardKeyMonitor()
                } else {
                    activateBoardFocus()
                }
            }
            .onAppear { openInitialConnectionIfNeeded() }
    }

    @ToolbarContentBuilder
    private var boardToolbar: some ToolbarContent {
        if arenaBrowseTarget != nil {
            ColosseumBoardHeaderToolbar(
                segments: arenaBreadcrumbSegments,
                currentColor: ColosseumTheme.remoteBoardTitle,
                onSegmentTap: handleArenaBreadcrumbTap(_:)
            )
        } else {
            ColosseumBoardHeaderToolbar(
                segments: pathSegments,
                onSegmentTap: navigateToPathIndex(_:)
            )
        }
        ColosseumTagHeaderToolbar(
            tags: availableTags,
            selected: $selectedTags,
            selectionOrder: $tagSelectionOrder,
            isSearching: showBoardSearch,
            searchQuery: $boardSearchQuery,
            visible: selectedConnectionID == nil
                && flattenedSelectedConnectionID == nil
                && !isAssigningTag
                && arenaBrowseTarget == nil,
            onDismissSearch: {
                withAnimation(ColosseumMotion.overlay) {
                    dismissBoardSearch()
                }
            }
        )
        ColosseumColumnSliderToolbar(
            columnCount: $columnCount,
            tagMatchMode: $tagMatchMode,
            boardsOnly: Binding(
                get: { boardsOnly },
                set: { newValue in
                    boardsOnly = newValue
                    if newValue { uncategorizedOnly = false }
                }
            ),
            uncategorizedOnly: Binding(
                get: { uncategorizedOnly },
                set: { newValue in
                    uncategorizedOnly = newValue
                    if newValue { boardsOnly = false }
                }
            ),
            flattened: $flattened,
            showTagMode: !availableTags.isEmpty && arenaBrowseTarget == nil && !showBoardSearch,
            showBoardsFilter: true,
            showUncategorizedFilter: arenaBrowseTarget == nil,
            isImporting: isImporting,
            visible: selectedConnectionID == nil
                && flattenedSelectedConnectionID == nil
                && !isAssigningTag
                && (isBrowsingGrid || showBoardSearch || arenaBrowseTarget != nil)
        )
    }

    private func applyBoardChrome<V: View>(to view: V) -> some View {
        view
            .animation(ColosseumMotion.overlay, value: selectedConnectionID)
            .animation(ColosseumMotion.overlay, value: flattenedSelectedConnectionID)
            .animation(ColosseumMotion.overlay, value: arenaBrowseTarget?.slug)
            .navigationTitle("")
            .toolbarBackground(ColosseumTheme.canvas, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbarColorScheme(.dark, for: .windowToolbar)
            .toolbar { boardToolbar }
    }

    private func applyBoardInteractions<V: View>(to view: V) -> some View {
        view
            .background {
                Group {
                    Button("") {
                        renameTitle = board.title
                        showRename = true
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    Button("") { toggleTagMatchMode() }
                        .keyboardShortcut("u", modifiers: [])
                    Button("") { toggleUncategorizedOnly() }
                        .keyboardShortcut(".", modifiers: [])
                    Button("") { toggleBoardsOnly() }
                        .keyboardShortcut("b", modifiers: [])
                    Button("") { toggleGridNotes() }
                        .keyboardShortcut("n", modifiers: [])
                    Button("") { toggleFlattened() }
                        .keyboardShortcut("f", modifiers: [])
                }
                .opacity(0)
                .allowsHitTesting(false)
                // A modal overlay owns the keyboard: bare `b` / `n` / `f` must reach its search field.
                .disabled(overlays.isPresented)
            }
            .focusable()
            .focused($boardFocused)
            .focusEffectDisabled()
            .onAppear { activateBoardFocus() }
            .onDisappear {
                boardKeyMonitor.remove()
                while let entry = removalUndoStack.popLast() {
                    finalizeOrphan(from: entry)
                }
            }
            .onChange(of: ownsBoardKeyboard) { _, owns in
                if owns {
                    activateBoardFocus()
                } else {
                    endTagAssign()
                    boardKeyMonitor.remove()
                }
            }
            .onChange(of: filteredListIdentity) { _, _ in
                if flattened {
                    Task { await loadFlattenedRemoteContents() }
                    return
                }
                gridFocusID = GridListIdentity.revalidatedFocus(
                    gridFocusID,
                    in: filteredConnections.lazy.map(\.id)
                )
            }
            .onChange(of: flattenedListIdentity) { _, _ in
                guard flattened else { return }
                flattenedFocusID = GridListIdentity.revalidatedFocus(
                    flattenedFocusID,
                    in: flattenedEntries.lazy.map(\.id)
                )
            }
            .onChange(of: flattened) { _, isFlattened in
                endTagAssign()
                if isFlattened {
                    flattenedFocusID = GridListIdentity.revalidatedFocus(
                        flattenedFocusID,
                        in: flattenedEntries.lazy.map(\.id)
                    )
                    Task { await loadFlattenedRemoteContents() }
                }
            }
            .onChange(of: availableTags) { _, tags in
                let keys = Set(tags.map { TagParser.normalize($0) })
                selectedTags = selectedTags.intersection(keys)
                tagSelectionOrder = tagSelectionOrder.filter { keys.contains($0) }
                if isAssigningTag {
                    if tags.isEmpty {
                        endTagAssign()
                    } else {
                        tagAssignFocusIndex = min(tagAssignFocusIndex, max(0, tags.count - 1))
                    }
                }
            }
            .onExitCommand(perform: handleEscape)
            .modalOverlay(isPresented: $showConnectBoard) {
                ConnectOverlay(
                    block: nil,
                    nestedBoard: nil,
                    parentBoard: board,
                    excludeBoardID: nil,
                    onDismiss: { showConnectBoard = false }
                )
            }
            .alert("Rename board", isPresented: $showRename) {
                TextField("Title", text: $renameTitle)
                Button("Save") {
                    board.title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? board.title : renameTitle
                    board.updatedAt = .now
                    try? context.save()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onDrop(of: DropIngest.acceptedTypes, isTargeted: $isTargeted) { providers in
                _ = handleDrop(providers)
                return true
            }
            .overlay {
                if isTargeted {
                    Rectangle()
                        .stroke(ColosseumTheme.primaryText, lineWidth: 1)
                        .padding(Space.s2)
                        .allowsHitTesting(false)
                }
            }
            .onNotification(.colosseumAdd) {
                addActivateRequest += 1
            }
            .onNotification(.colosseumConnectBoard) {
                showConnectBoard = true
            }
            .onNotification(.colosseumRename) {
                renameTitle = board.title
                showRename = true
            }
            .onNotification(.colosseumColumnsIncrease) {
                adjustColumns(by: 1)
            }
            .onNotification(.colosseumColumnsDecrease) {
                adjustColumns(by: -1)
            }
            .onNotification(.colosseumPaste) {
                Task { await paste() }
            }
            .onNotification(.colosseumOpenCommand) {
                guard arenaBrowseTarget == nil else { return }
                openFiles()
            }
            .onNotification(.colosseumOpenFiles) {
                guard arenaBrowseTarget == nil else { return }
                openFiles()
            }
            .alert("Import error", isPresented: importErrorPresented) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func toggleTagMatchMode() {
        guard isBrowsingGrid else { return }
        withAnimation(ColosseumMotion.soft) {
            tagMatchMode = tagMatchMode == .intersection ? .union : .intersection
        }
    }

    private func toggleUncategorizedOnly() {
        guard isBrowsingGrid else { return }
        withAnimation(ColosseumMotion.soft) {
            uncategorizedOnly.toggle()
            if uncategorizedOnly {
                boardsOnly = false
            }
        }
    }

    private func toggleBoardsOnly() {
        // Local grid or hosted remote browser.
        guard isBrowsingGrid || arenaBrowseTarget != nil else { return }
        withAnimation(ColosseumMotion.soft) {
            boardsOnly.toggle()
            if boardsOnly {
                uncategorizedOnly = false
            }
        }
    }

    private func toggleGridNotes() {
        guard isBrowsingGrid || arenaBrowseTarget != nil else { return }
        withAnimation(ColosseumMotion.soft) {
            showGridNotes.toggle()
        }
    }

    private func toggleFlattened() {
        guard isBrowsingGrid || arenaBrowseTarget != nil else { return }
        withAnimation(ColosseumMotion.soft) { flattened.toggle() }
    }

    private func selectOnlyTag(_ tag: String) {
        let key = TagParser.normalize(tag)
        selectedTags = [key]
        tagSelectionOrder = [key]
    }

    private func activateBoardFocus() {
        boardFocused = true
        installBoardKeyMonitor()
        // Defer one tick so SwiftUI finishes mounting after the home → board fade.
        DispatchQueue.main.async {
            boardFocused = true
            if flattened, flattenedFocusID == nil {
                flattenedFocusID = flattenedEntries.first?.id
            } else if !flattened, gridFocusID == nil {
                gridFocusID = filteredConnections.first?.id
            }
        }
    }

    private func installBoardKeyMonitor() {
        boardKeyMonitor.onLeft = {
            if isAssigningTag {
                moveTagAssignFocus(delta: -1)
            } else if flattened {
                moveFlattenedFocus(delta: -1)
            } else {
                moveGridFocus(delta: -1)
            }
        }
        boardKeyMonitor.onRight = {
            if isAssigningTag {
                moveTagAssignFocus(delta: 1)
            } else if flattened {
                moveFlattenedFocus(delta: 1)
            } else {
                moveGridFocus(delta: 1)
            }
        }
        boardKeyMonitor.onUp = {
            if isAssigningTag {
                moveTagAssignFocus(delta: -1)
            } else if flattened {
                moveFlattenedFocus(delta: -columnCount)
            } else {
                moveGridFocus(delta: -columnCount)
            }
        }
        boardKeyMonitor.onDown = {
            if isAssigningTag {
                moveTagAssignFocus(delta: 1)
            } else if flattened {
                moveFlattenedFocus(delta: columnCount)
            } else {
                moveGridFocus(delta: columnCount)
            }
        }
        boardKeyMonitor.onEnter = {
            if isAssigningTag {
                toggleFocusedAssignTag()
            } else if flattened {
                activateFocusedFlattenedEntry()
            } else {
                activateFocusedConnection()
            }
        }
        boardKeyMonitor.onTab = { false }
        boardKeyMonitor.onEscape = {
            if showBoardSearch {
                withAnimation(ColosseumMotion.overlay) {
                    dismissBoardSearch()
                }
            } else if isAssigningTag {
                endTagAssign()
            } else if arenaBrowseTarget != nil {
                // ArenaBrowserView owns Esc while remote is open.
                return
            } else if selectedConnectionID != nil {
                // BlockView owns Esc (including Connect sheet).
                return
            } else {
                handleEscape()
            }
        }
        boardKeyMonitor.onDelete = {
            guard isBrowsingGrid, !isAssigningTag else { return }
            if flattened {
                deleteFocusedFlattenedEntry()
            } else {
                deleteFocusedConnection()
            }
        }
        boardKeyMonitor.onUndo = {
            guard isBrowsingGrid, !isAssigningTag else { return false }
            return undoLastRemoval()
        }
        boardKeyMonitor.onCopy = {
            guard isBrowsingGrid, !isAssigningTag else { return false }
            return flattened ? copyFocusedFlattenedEntry() : copyFocusedBlock()
        }
        boardKeyMonitor.onCharacter = { char in
            if char == "." {
                guard isBrowsingGrid else { return false }
                DispatchQueue.main.async { toggleUncategorizedOnly() }
                return true
            }
            if char == "b" {
                guard isBrowsingGrid || arenaBrowseTarget != nil else { return false }
                DispatchQueue.main.async { toggleBoardsOnly() }
                return true
            }
            if char == "n" {
                guard isBrowsingGrid || arenaBrowseTarget != nil else { return false }
                DispatchQueue.main.async { toggleGridNotes() }
                return true
            }
            if char == "f" {
                guard isBrowsingGrid || arenaBrowseTarget != nil else { return false }
                DispatchQueue.main.async { toggleFlattened() }
                return true
            }
            guard isBrowsingGrid else { return false }
            if char == "u" {
                DispatchQueue.main.async { toggleTagMatchMode() }
                return true
            }
            if char == "t" {
                guard !flattened else { return false }
                DispatchQueue.main.async { toggleTagAssign() }
                return true
            }
            return false
        }
        // While searching, ignore arrows/enter but still route Esc (incl. from the text field).
        boardKeyMonitor.shouldIgnoreNavigation = { !isBrowsingGrid }
        boardKeyMonitor.install()
    }

    private func toggleBoardSearch() {
        // Grid only — never over block preview or hosted Arena (Arena owns its search).
        guard selectedConnectionID == nil,
              flattenedSelectedConnectionID == nil,
              arenaBrowseTarget == nil,
              !isAssigningTag
        else { return }
        withAnimation(ColosseumMotion.overlay) {
            if showBoardSearch {
                dismissBoardSearch()
            } else {
                boardSearchQuery = ""
                showBoardSearch = true
            }
        }
    }

    private func dismissBoardSearch() {
        showBoardSearch = false
        boardSearchQuery = ""
        activateBoardFocus()
    }

    @discardableResult
    private func copyFocusedBlock() -> Bool {
        guard let focusID = gridFocusID,
              let block = filteredConnections.first(where: { $0.id == focusID })?.block
        else { return false }
        return BlockClipboard.copy(block)
    }

    private func deleteFocusedConnection() {
        guard let focusID = gridFocusID,
              let index = filteredConnections.firstIndex(where: { $0.id == focusID })
        else { return }

        let connection = filteredConnections[index]
        let entry = RemovalUndoEntry(
            boardID: board.id,
            position: connection.position,
            blockID: connection.block?.id,
            nestedBoardID: connection.nestedBoard?.id
        )

        // Soft-remove so undo can reconnect without restoring media from disk.
        ImportService.removeConnection(connection, deleteOrphanedBlock: false, context: context)
        pushRemovalUndo(entry)
        try? context.save()

        let remaining = filteredConnections
        if remaining.isEmpty {
            gridFocusID = nil
        } else if index < remaining.count {
            gridFocusID = remaining[index].id
        } else {
            gridFocusID = remaining[remaining.count - 1].id
        }
    }

    private func pushRemovalUndo(_ entry: RemovalUndoEntry) {
        removalUndoStack.append(entry)
        while removalUndoStack.count > 3 {
            let dropped = removalUndoStack.removeFirst()
            finalizeOrphan(from: dropped)
        }
    }

    @discardableResult
    private func undoLastRemoval() -> Bool {
        guard let entry = removalUndoStack.popLast() else { return false }
        let targetBoard = entry.boardID == board.id
            ? board
            : allBoards.first(where: { $0.id == entry.boardID })
        guard let targetBoard else {
            finalizeOrphan(from: entry)
            return true
        }

        let block: Block? = {
            guard let id = entry.blockID else { return nil }
            return try? context.fetch(
                FetchDescriptor<Block>(predicate: #Predicate { $0.id == id })
            ).first
        }()
        let nested: Board? = entry.nestedBoardID.flatMap { id in
            allBoards.first(where: { $0.id == id })
        }

        guard block != nil || nested != nil else { return true }

        ImportService.reconnect(
            block: block,
            nestedBoard: nested,
            to: targetBoard,
            position: entry.position,
            context: context
        )
        try? context.save()

        if targetBoard.id == board.id {
            if let block {
                gridFocusID = board.connections.first(where: { $0.block?.id == block.id })?.id
            } else if let nested {
                gridFocusID = board.connections.first(where: { $0.nestedBoard?.id == nested.id })?.id
            }
        }
        return true
    }

    private func finalizeOrphan(from entry: RemovalUndoEntry) {
        guard let id = entry.blockID else { return }
        guard let block = try? context.fetch(
            FetchDescriptor<Block>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        ImportService.deleteOrphanedBlockIfNeeded(block, context: context)
        try? context.save()
    }

    private func toggleTagAssign() {
        if isAssigningTag {
            endTagAssign()
            return
        }
        beginTagAssign()
    }

    private func beginTagAssign() {
        guard isBrowsingGrid, !availableTags.isEmpty else { return }
        if gridFocusID == nil {
            gridFocusID = filteredConnections.first?.id
        }
        guard gridFocusID != nil else { return }
        boardFocused = true
        tagAssignFocusIndex = 0
        withAnimation(ColosseumMotion.overlay) {
            isAssigningTag = true
        }
    }

    private func endTagAssign() {
        withAnimation(ColosseumMotion.overlay) {
            isAssigningTag = false
        }
        tagAssignFocusIndex = 0
        boardFocused = true
    }

    private func moveTagAssignFocus(delta: Int) {
        guard isAssigningTag else { return }
        let tags = availableTags
        guard !tags.isEmpty else { return }
        let count = tags.count
        let next = ((tagAssignFocusIndex + delta) % count + count) % count
        withAnimation(ColosseumMotion.soft) {
            tagAssignFocusIndex = next
        }
    }

    private func toggleFocusedAssignTag() {
        guard availableTags.indices.contains(tagAssignFocusIndex) else { return }
        toggleAssignTag(availableTags[tagAssignFocusIndex])
    }

    private func moveGridFocus(delta: Int) {
        guard isBrowsingGrid else { return }
        let items = filteredConnections
        guard !items.isEmpty else { return }
        boardFocused = true
        if let idx = items.firstIndex(where: { $0.id == gridFocusID }) {
            let next = idx + delta
            guard next >= 0, next < items.count else { return }
            withAnimation(ColosseumMotion.soft) {
                gridFocusID = items[next].id
            }
        } else {
            withAnimation(ColosseumMotion.soft) {
                gridFocusID = items[0].id
            }
        }
    }

    private func activateFocusedConnection() {
        guard isBrowsingGrid else { return }
        let items = filteredConnections
        let target = items.first(where: { $0.id == gridFocusID }) ?? items.first
        guard let connection = target else { return }
        gridFocusID = connection.id
        openConnection(connection)
    }

    private func moveFlattenedFocus(delta: Int) {
        guard isBrowsingGrid, !flattenedEntries.isEmpty else { return }
        boardFocused = true
        if let index = flattenedEntries.firstIndex(where: { $0.id == flattenedFocusID }) {
            let next = index + delta
            guard flattenedEntries.indices.contains(next) else { return }
            withAnimation(ColosseumMotion.soft) {
                flattenedFocusID = flattenedEntries[next].id
            }
        } else {
            flattenedFocusID = flattenedEntries.first?.id
        }
    }

    private func activateFocusedFlattenedEntry() {
        guard isBrowsingGrid else { return }
        let entry = flattenedEntries.first(where: { $0.id == flattenedFocusID })
            ?? flattenedEntries.first
        guard let entry else { return }
        flattenedFocusID = entry.id
        openFlattenedEntry(entry)
    }

    @discardableResult
    private func copyFocusedFlattenedEntry() -> Bool {
        guard let entry = flattenedEntries.first(where: { $0.id == flattenedFocusID }) else {
            return false
        }
        switch entry {
        case .local(_, let connection):
            guard let block = connection.block else { return false }
            return BlockClipboard.copy(block)
        case .remote(_, let item):
            return BlockClipboard.copy(item)
        }
    }

    private func deleteFocusedFlattenedEntry() {
        guard let index = flattenedEntries.firstIndex(where: { $0.id == flattenedFocusID }) else { return }
        guard case .local(let source, let connection) = flattenedEntries[index] else { return }
        let entry = RemovalUndoEntry(
            boardID: source.id,
            position: connection.position,
            blockID: connection.block?.id,
            nestedBoardID: connection.nestedBoard?.id
        )
        ImportService.removeConnection(connection, deleteOrphanedBlock: false, context: context)
        pushRemovalUndo(entry)
        try? context.save()

        let remaining = flattenedEntries
        if remaining.isEmpty {
            flattenedFocusID = nil
        } else if index < remaining.count {
            flattenedFocusID = remaining[index].id
        } else {
            flattenedFocusID = remaining.last?.id
        }
    }

    private func openFlattenedEntry(_ entry: FlattenedBoardEntry) {
        switch entry {
        case .local(let source, let connection):
            if source.id == board.id {
                openConnection(connection)
            } else if let nested = connection.nestedBoard {
                withAnimation(ColosseumMotion.overlay) {
                    if path.last != source.id { path.append(source.id) }
                    path.append(nested.id)
                }
            } else if let block = connection.block, block.kind == .arenaChannel {
                openFlattenedRemoteBoard(ArenaBrowseTarget(block: block), selectedItem: nil, siblings: [])
            } else if connection.block != nil {
                withAnimation(ColosseumMotion.overlay) {
                    flattenedSelectedBoardID = source.id
                    flattenedSelectedConnectionID = connection.id
                }
            }
        case .remote(let source, let item):
            if item.kind == .channel, let slug = item.channelSlug {
                openFlattenedRemoteBoard(
                    ArenaBrowseTarget(slug: slug, title: item.title, urlString: item.previewURL),
                    selectedItem: nil,
                    siblings: []
                )
            } else {
                let siblings = (flattenedRemoteContents[source.slug] ?? [])
                    .filter { $0.kind != .channel }
                openFlattenedRemoteBoard(source, selectedItem: item, siblings: siblings)
            }
        }
    }

    private func closeFlattenedPreview() {
        withAnimation(ColosseumMotion.overlay) {
            flattenedSelectedBoardID = nil
            flattenedSelectedConnectionID = nil
        }
        activateBoardFocus()
    }

    private func openFlattenedRemoteBoard(
        _ target: ArenaBrowseTarget,
        selectedItem: ArenaContentItem?,
        siblings: [ArenaContentItem],
        preservesLocalPreview: Bool = false
    ) {
        withAnimation(ColosseumMotion.overlay) {
            if !preservesLocalPreview {
                flattenedSelectedBoardID = nil
                flattenedSelectedConnectionID = nil
            }
            showBoardSearch = false
            boardSearchQuery = ""
            arenaInitialSelectedItem = selectedItem
            arenaInitialSelectedSiblings = siblings
            arenaStack = [target]
            arenaBrowseTarget = target
        }
    }

    private func matchesFlattenedFilters(_ entry: FlattenedBoardEntry) -> Bool {
        let isBoard: Bool
        let itemNotes: String
        let itemTitle: String
        let tags: Set<String>
        switch entry {
        case .local(_, let connection):
            isBoard = connection.nestedBoard != nil || connection.block?.kind == .arenaChannel
            itemNotes = notes(for: connection)
            itemTitle = title(for: connection)
            tags = TagParser.tags(for: connection)
        case .remote(_, let item):
            isBoard = item.kind == .channel
            itemNotes = item.notes
            itemTitle = item.title
            tags = Set(TagParser.tags(in: item.notes).map(TagParser.normalize))
        }

        if uncategorizedOnly {
            if isBoard || !tags.isEmpty { return false }
        } else if boardsOnly, !isBoard {
            return false
        }
        if !uncategorizedOnly, !selectedTags.isEmpty {
            switch tagMatchMode {
            case .intersection:
                if !selectedTags.isSubset(of: tags) { return false }
            case .union:
                if selectedTags.isDisjoint(with: tags) { return false }
            }
        }
        let query = boardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if showBoardSearch, !query.isEmpty {
            return BoardContentSearch.matches([itemTitle, itemNotes], query: query)
        }
        return true
    }

    @MainActor
    private func loadFlattenedRemoteContents() async {
        guard flattened, !isLoadingFlattenedContents else { return }
        isLoadingFlattenedContents = true
        defer { isLoadingFlattenedContents = false }
        let channels = connections.compactMap { connection -> (String, Block)? in
            guard let block = connection.block,
                  block.kind == .arenaChannel,
                  let slug = block.arenaSlug
            else { return nil }
            return (slug, block)
        }
        for (slug, _) in channels where flattenedRemoteContents[slug] == nil {
            guard flattened else { return }
            if let contents = try? await ArenaService.fetchAllContents(slug: slug) {
                flattenedRemoteContents[slug] = contents
            }
        }
    }

    private func openConnection(_ connection: Connection) {
        if let nested = connection.nestedBoard {
            withAnimation(ColosseumMotion.overlay) {
                path.append(nested.id)
            }
        } else if let block = connection.block {
            if block.kind == .arenaChannel {
                openArenaBrowser(for: block)
            } else {
                withAnimation(ColosseumMotion.overlay) {
                    selectedConnectionID = connection.id
                }
            }
        }
    }

    private func openInitialConnectionIfNeeded() {
        let connectionID: UUID?
        if let initialConnectionID {
            connectionID = initialConnectionID
            onInitialConnectionConsumed()
        } else {
            connectionID = returnPreviewConnections.removeValue(forKey: board.id)
        }
        guard let connectionID,
              let connection = connections.first(where: { $0.id == connectionID })
        else { return }
        DispatchQueue.main.async {
            openConnection(connection)
        }
    }

    private func openConnectedBoard(_ target: Board) {
        guard target.id != board.id else { return }
        if let selectedConnectionID {
            returnPreviewConnections[board.id] = selectedConnectionID
        }
        withAnimation(ColosseumMotion.overlay) {
            selectedConnectionID = nil
            if let idx = path.firstIndex(of: target.id) {
                path = Array(path.prefix(idx + 1))
            } else {
                path.append(target.id)
            }
        }
        activateBoardFocus()
    }

    private var boardStack: some View {
        ZStack {
            boardGrid
                .background(ColosseumTheme.canvas)

            if let connection = selectedConnection, let block = connection.block, block.kind != .arenaChannel {
                BlockView(
                    board: board,
                    connections: connections.filter { $0.block != nil && $0.block?.kind != .arenaChannel },
                    selectedID: $selectedConnectionID,
                    onClose: {
                        withAnimation(ColosseumMotion.overlay) {
                            selectedConnectionID = nil
                        }
                        activateBoardFocus()
                    },
                    onTagTap: { tag in
                        withAnimation(ColosseumMotion.overlay) {
                            selectedConnectionID = nil
                            selectOnlyTag(tag)
                        }
                    },
                    onOpenBoard: openConnectedBoard(_:),
                    onOpenRemoteBoard: { target in
                        withAnimation(ColosseumMotion.overlay) {
                            boardsOnly = false
                            arenaStack = [target]
                            arenaBrowseTarget = target
                        }
                    }
                )
                .transition(ColosseumMotion.overlayTransition)
                .zIndex(10)
            }

            if let sourceBoard = flattenedSelectedBoard,
               let selectedID = flattenedSelectedConnectionID,
               sourceBoard.connections.contains(where: { $0.id == selectedID }) {
                BlockView(
                    board: sourceBoard,
                    connections: sourceBoard.sortedConnections.filter {
                        $0.block != nil && $0.block?.kind != .arenaChannel
                    },
                    selectedID: Binding(
                        get: { flattenedSelectedConnectionID },
                        set: { flattenedSelectedConnectionID = $0 }
                    ),
                    onClose: closeFlattenedPreview,
                    onOpenBoard: openConnectedBoard(_:),
                    onOpenRemoteBoard: { target in
                        openFlattenedRemoteBoard(
                            target,
                            selectedItem: nil,
                            siblings: [],
                            preservesLocalPreview: true
                        )
                    }
                )
                .transition(ColosseumMotion.overlayTransition)
                .zIndex(10)
            }

            if let arenaBrowseTarget {
                ArenaBrowserView(
                    initialTarget: arenaBrowseTarget,
                    stack: $arenaStack,
                    destinationBoard: board,
                    showsInlineChrome: false,
                    boardsOnly: $boardsOnly,
                    flattened: $flattened,
                    searchActive: $showBoardSearch,
                    searchQuery: $boardSearchQuery,
                    initialSelectedItem: arenaInitialSelectedItem,
                    initialSelectedSiblings: arenaInitialSelectedSiblings,
                    onClose: {
                        withAnimation(ColosseumMotion.overlay) {
                            showBoardSearch = false
                            boardSearchQuery = ""
                            self.arenaBrowseTarget = nil
                            arenaStack = []
                            arenaInitialSelectedItem = nil
                            arenaInitialSelectedSiblings = []
                        }
                    },
                    onImportedBoard: { imported in
                        withAnimation(ColosseumMotion.overlay) {
                            showBoardSearch = false
                            boardSearchQuery = ""
                            self.arenaBrowseTarget = nil
                            arenaStack = []
                            arenaInitialSelectedItem = nil
                            arenaInitialSelectedSiblings = []
                            path.append(imported.id)
                        }
                    }
                )
                .transition(ColosseumMotion.overlayTransition)
                .zIndex(20)
            }
        }
    }

    private var boardGrid: some View {
        Group {
            if flattened {
                flattenedBoardGrid
            } else {
                regularBoardGrid
            }
        }
    }

    private var regularBoardGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: ColosseumTheme.gridGap) {
                    GridBlockChrome(notes: "", showsNotes: showGridNotes) {
                        InlineAddBlockView(
                            board: board,
                            activateRequest: addActivateRequest,
                            onError: { errorMessage = $0 }
                        )
                    }
                    .id(Self.addCellID)

                    ForEach(filteredConnections, id: \.id) { connection in
                        let isFocus = connection.id == gridFocusID
                        connectionCell(
                            connection,
                            isSelected: isFocus && isBrowsingGrid && !isAssigningTag,
                            captureTagAssignAnchor: isAssigningTag && isFocus
                        )
                            .id(connection.id)
                            .pointingHandCursor()
                            .transition(ColosseumMotion.itemTransition)
                    }
                }
                .padding(Space.s5)
                .padding(.bottom, isAssigningTag ? 200 : 0)
                .animation(ColosseumMotion.standard, value: selectedTags)
                .animation(ColosseumMotion.standard, value: tagMatchMode)
                .animation(ColosseumMotion.standard, value: boardsOnly)
                .animation(ColosseumMotion.standard, value: uncategorizedOnly)
                .animation(ColosseumMotion.standard, value: showGridNotes)
                .animation(ColosseumMotion.soft, value: filteredListIdentity)
                .animation(ColosseumMotion.standard, value: columnCount)
                .allowsHitTesting(!isPinching && !isAssigningTag)
            }
            .blur(radius: isAssigningTag ? 5 : 0)
            .overlay {
                if isAssigningTag {
                    ColosseumTheme.scrim
                        .ignoresSafeArea()
                        .onTapGesture { endTagAssign() }
                        .transition(.opacity)
                }
            }
            .overlayPreferenceValue(TagAssignAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if isAssigningTag, let anchor, let connection = tagAssignConnection {
                        let rect = proxy[anchor]
                        tagAssignElevated(connection: connection, rect: rect)
                            .transition(ColosseumMotion.overlayTransition)
                    }
                }
                .allowsHitTesting(isAssigningTag)
            }
            .onChange(of: addActivateRequest) { _, _ in
                // Bring the add cell on screen so it exists to take focus.
                withAnimation(ColosseumMotion.soft) {
                    proxy.scrollTo(Self.addCellID, anchor: .top)
                }
            }
            .onChange(of: gridFocusID) { _, id in
                guard let id, isBrowsingGrid else { return }
                withAnimation(ColosseumMotion.soft) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: isAssigningTag) { _, assigning in
                guard assigning, let id = gridFocusID else { return }
                withAnimation(ColosseumMotion.soft) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .highPriorityGesture(columnPinchGesture)
        .animation(ColosseumMotion.overlay, value: isAssigningTag)
    }

    private var flattenedBoardGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: ColosseumTheme.gridGap) {
                    GridBlockChrome(notes: "", showsNotes: showGridNotes) {
                        InlineAddBlockView(
                            board: board,
                            activateRequest: addActivateRequest,
                            onError: { errorMessage = $0 }
                        )
                    }
                    .id(Self.addCellID)

                    ForEach(flattenedEntries) { entry in
                        flattenedEntryCell(entry)
                            .id(entry.id)
                            .pointingHandCursor()
                            .transition(ColosseumMotion.itemTransition)
                    }
                }
                .padding(Space.s5)
                .animation(ColosseumMotion.standard, value: selectedTags)
                .animation(ColosseumMotion.standard, value: tagMatchMode)
                .animation(ColosseumMotion.standard, value: boardsOnly)
                .animation(ColosseumMotion.standard, value: uncategorizedOnly)
                .animation(ColosseumMotion.standard, value: showGridNotes)
                .animation(ColosseumMotion.soft, value: flattenedListIdentity)
                .animation(ColosseumMotion.standard, value: columnCount)
                .allowsHitTesting(!isPinching)
            }
            .overlay(alignment: .bottom) {
                if isLoadingFlattenedContents {
                    Text("Flattening remote boards…")
                        .font(.system(size: TypeScale.t0))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, Space.s2)
                        .background(ColosseumTheme.elevated)
                        .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
                        .padding(.bottom, Space.s4)
                }
            }
            .onChange(of: addActivateRequest) { _, _ in
                withAnimation(ColosseumMotion.soft) {
                    proxy.scrollTo(Self.addCellID, anchor: .top)
                }
            }
            .onChange(of: flattenedFocusID) { _, id in
                guard let id, isBrowsingGrid else { return }
                withAnimation(ColosseumMotion.soft) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .highPriorityGesture(columnPinchGesture)
    }

    @ViewBuilder
    private func flattenedEntryCell(_ entry: FlattenedBoardEntry) -> some View {
        let isSelected = entry.id == flattenedFocusID && isBrowsingGrid
        Button {
            guard !shouldSuppressGridClicks else { return }
            flattenedFocusID = entry.id
            openFlattenedEntry(entry)
        } label: {
            switch entry {
            case .local(_, let connection):
                GridBlockChrome(
                    notes: notes(for: connection),
                    title: title(for: connection),
                    searchQuery: showBoardSearch ? boardSearchQuery : "",
                    isSelected: isSelected,
                    showsNotes: showGridNotes
                ) {
                    connectionCellContent(connection, isSelected: isSelected)
                }
            case .remote(_, let item):
                GridBlockChrome(
                    notes: item.notes,
                    title: item.title,
                    searchQuery: showBoardSearch ? boardSearchQuery : "",
                    isSelected: isSelected,
                    showsNotes: showGridNotes
                ) {
                    ArenaRemoteCell(
                        item: item,
                        isHovering: false,
                        isSelected: isSelected,
                        hoverPlayer: nil
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tagAssignElevated(connection: Connection, rect: CGRect) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            connectionCellContent(connection, isSelected: true)
                .frame(width: rect.width, height: rect.height)
                .clipped()
                .gridSelectionRing(isActive: true)
                .floatingPanelShadow()

            TagAssignPopover(
                tags: availableTags,
                selectedKeys: tagAssignSelectedKeys,
                focusedKey: focusedAssignTagKey,
                onToggle: { toggleAssignTag($0) }
            )
            .frame(width: 176, alignment: .leading)
        }
        .frame(width: rect.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func toggleAssignTag(_ tag: String) {
        guard isAssigningTag,
              let connection = tagAssignConnection
        else { return }
        let key = TagParser.normalize(tag)
        if let idx = availableTags.firstIndex(where: { TagParser.normalize($0) == key }) {
            tagAssignFocusIndex = idx
        }
        applyTagToggle(tag, on: connection, currentlyOn: TagParser.tags(for: connection).contains(key))
    }

    private func applyTagToggle(_ tag: String, on connection: Connection, currentlyOn: Bool) {
        if let block = connection.block {
            block.notes = currentlyOn
                ? TagParser.removingTag(tag, from: block.notes)
                : TagParser.appendingTag(tag, to: block.notes)
            board.updatedAt = .now
            try? context.save()
        } else if let nested = connection.nestedBoard {
            nested.notes = currentlyOn
                ? TagParser.removingTag(tag, from: nested.notes)
                : TagParser.appendingTag(tag, to: nested.notes)
            nested.updatedAt = .now
            board.updatedAt = .now
            try? context.save()
        }
    }

    @ViewBuilder
    private func connectionCell(
        _ connection: Connection,
        isSelected: Bool = false,
        captureTagAssignAnchor: Bool = false
    ) -> some View {
        Button {
            guard !shouldSuppressGridClicks else { return }
            gridFocusID = connection.id
            openConnection(connection)
        } label: {
            GridBlockChrome(
                notes: notes(for: connection),
                title: title(for: connection),
                searchQuery: showBoardSearch ? boardSearchQuery : "",
                isSelected: isSelected,
                showsNotes: showGridNotes,
                captureTagAssignAnchor: captureTagAssignAnchor
            ) {
                connectionCellContent(connection, isSelected: isSelected)
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .contextMenu { connectionMenu(connection) }
    }

    private func notes(for connection: Connection) -> String {
        if let block = connection.block { return block.notes }
        if let nested = connection.nestedBoard { return nested.notes }
        return ""
    }

    private func title(for connection: Connection) -> String {
        if let nested = connection.nestedBoard { return nested.title }
        if let block = connection.block { return block.title }
        return ""
    }

    @ViewBuilder
    private func connectionCellContent(_ connection: Connection, isSelected: Bool = false) -> some View {
        if let nested = connection.nestedBoard {
            NestedBoardCell(board: nested)
        } else if let block = connection.block {
            switch block.kind {
            case .image, .video, .audio:
                MediaBlockCell(block: block, isSelected: isSelected)
            case .text:
                TextBlockCell(block: block)
            case .link:
                LinkBlockCell(block: block)
            case .arenaChannel:
                ArenaBlockCell(block: block)
            }
        }
    }

    @ViewBuilder
    private func connectionMenu(_ connection: Connection) -> some View {
        if let block = connection.block, block.kind == .arenaChannel {
            Button("Browse in Colosseum") { openArenaBrowser(for: block) }
            if let urlString = block.arenaURL ?? block.sourceURL,
               let url = URL(string: urlString) {
                Button("Open on Are.na") { NSWorkspace.shared.open(url) }
            }
        }
        if let nested = connection.nestedBoard {
            Button("Open board") { path.append(nested.id) }
        }
        Divider()
        Button("Remove from board", role: .destructive) {
            ImportService.removeConnection(connection, deleteOrphanedBlock: true, context: context)
            try? context.save()
        }
    }

    private func adjustColumns(by delta: Int) {
        guard isBrowsingGrid else { return }
        let next = min(
            max(columnCount + delta, ChromeMetrics.boardColumnsMin),
            ChromeMetrics.boardColumnsMax
        )
        guard next != columnCount else { return }
        withAnimation(ColosseumMotion.standard) {
            columnCount = next
        }
    }

    private var columnPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // Only drive density while browsing the grid (not block/arena overlays).
                guard isBrowsingGrid, !isAssigningTag else { return }
                if pinchBaseColumns == nil {
                    isPinching = true
                    pinchDidChange = false
                    pinchBaseColumns = columnCount
                    lastPinchStep = 0
                }
                if abs(value - 1) > 0.04 {
                    pinchDidChange = true
                }
                // Pinch out (value > 1) → larger cells → fewer columns.
                let step = Int(((value - 1) / ChromeMetrics.pinchStepThreshold).rounded(.towardZero))
                guard step != lastPinchStep, let base = pinchBaseColumns else { return }
                lastPinchStep = step
                pinchDidChange = true
                let next = min(
                    max(base - step, ChromeMetrics.boardColumnsMin),
                    ChromeMetrics.boardColumnsMax
                )
                if next != columnCount {
                    withAnimation(ColosseumMotion.standard) {
                        columnCount = next
                    }
                }
            }
            .onEnded { _ in
                if pinchDidChange {
                    // Swallow the mouse-up / click that often follows a trackpad pinch.
                    suppressGridClicksUntil = Date().addingTimeInterval(0.45)
                }
                isPinching = false
                pinchDidChange = false
                pinchBaseColumns = nil
                lastPinchStep = 0
            }
    }

    private func navigateToPathIndex(_ index: Int) {
        if selectedConnectionID != nil {
            withAnimation(ColosseumMotion.overlay) {
                selectedConnectionID = nil
            }
        }
        if arenaBrowseTarget != nil {
            withAnimation(ColosseumMotion.overlay) {
                arenaBrowseTarget = nil
                arenaStack = []
            }
        }
        if flattenedSelectedConnectionID != nil {
            closeFlattenedPreview()
        }
        guard index >= 0, index < path.count else { return }
        withAnimation(ColosseumMotion.overlay) {
            path = Array(path.prefix(index + 1))
        }
    }

    private func jumpArenaStack(to index: Int) {
        guard index >= 0, index < arenaStack.count else { return }
        withAnimation(ColosseumMotion.soft) {
            boardsOnly = false
            arenaStack = Array(arenaStack.prefix(index + 1))
        }
    }

    private func handleArenaBreadcrumbTap(_ index: Int) {
        let localCount = pathSegments.count
        if index < localCount {
            // Jump back into the originating local board trail and leave remote browse.
            navigateToPathIndex(index)
            return
        }
        jumpArenaStack(to: index - localCount)
    }

    private func handleEscape() {
        if showBoardSearch {
            withAnimation(ColosseumMotion.overlay) {
                dismissBoardSearch()
            }
            return
        }
        // Block preview / Arena browser own Esc (including nested Connect sheets).
        if selectedConnectionID != nil
            || flattenedSelectedConnectionID != nil
            || arenaBrowseTarget != nil {
            return
        }
        withAnimation(ColosseumMotion.overlay) {
            if path.count > 1 {
                _ = path.popLast()
            } else {
                path = []
            }
        }
    }

    private func openArenaBrowser(for block: Block) {
        let slug = block.arenaSlug ?? ""
        guard !slug.isEmpty || block.arenaURL != nil || block.sourceURL != nil else { return }
        let target = ArenaBrowseTarget(block: block)
        withAnimation(ColosseumMotion.overlay) {
            showBoardSearch = false
            boardSearchQuery = ""
            boardsOnly = false
            arenaInitialSelectedItem = nil
            arenaInitialSelectedSiblings = []
            arenaStack = [target]
            arenaBrowseTarget = target
        }
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .image, .movie, .audio, .mpeg4Movie, .quickTimeMovie,
            .mp3, .mpeg4Audio, .wav, .aiff,
            .png, .jpeg, .gif, .webP, .heic
        ]
        guard panel.runModal() == .OK else { return }
        Task { await importURLs(panel.urls) }
    }

    private func paste() async {
        isImporting = true
        defer { isImporting = false }
        do {
            try await ImportService.importPasteboard(into: board, context: context)
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importURLs(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        do {
            try await ImportService.importFiles(urls, into: board, context: context)
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            isImporting = true
            defer { isImporting = false }
            do {
                let payload = await DropIngest.payload(from: providers)
                guard !payload.isEmpty else { return }
                try await ImportService.importPayload(payload, into: board, context: context)
                try context.save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return true
    }
}

extension View {
    /// Shorthand for NotificationCenter observation; keeps long view-modifier
    /// chains inside the type-checker's budget.
    func onNotification(_ name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}
