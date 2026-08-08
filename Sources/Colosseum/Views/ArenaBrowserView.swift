import AppKit
import AVFoundation
import SwiftData
import SwiftUI

private struct ArenaGridEntry: Identifiable {
    let item: ArenaContentItem
    let source: ArenaBrowseTarget

    var id: String { "\(source.slug):\(item.id)" }
}

private struct ArenaReturnSelection {
    let item: ArenaContentItem
    let siblings: [ArenaContentItem]
}

struct ArenaBrowserView: View {
    let initialTarget: ArenaBrowseTarget
    @Binding var stack: [ArenaBrowseTarget]
    /// Local board to save individual items into (optional).
    var destinationBoard: Board?
    /// When false, host window toolbar shows the path (board-hosted). When true, draw matching chrome inline.
    var showsInlineChrome: Bool = true
    /// Shared with host toolbar when chrome is external; otherwise uses local state.
    var boardsOnly: Binding<Bool>? = nil
    /// Shared with host toolbar when chrome is external; otherwise uses local state.
    var flattened: Binding<Bool>? = nil
    /// Shared with host principal search when chrome is external.
    var searchActive: Binding<Bool>? = nil
    var searchQuery: Binding<String>? = nil
    var initialSelectedItem: ArenaContentItem? = nil
    var initialSelectedSiblings: [ArenaContentItem] = []
    var onClose: () -> Void
    var onImportedBoard: ((Board) -> Void)?

    @Environment(\.modelContext) private var context
    @ObservedObject private var overlays = OverlayPresentation.shared
    @State private var model = ArenaBrowserModel()
    @State private var selectedItem: ArenaContentItem?
    @State private var selectedItemSiblings: [ArenaContentItem] = []
    @State private var showConnect = false
    @State private var isImporting = false
    @State private var importProgress = ""
    @State private var statusMessage: String?
    @State private var hoverVideo: LoopingVideoPlayer?
    @State private var hoveringItemID: Int?
    @State private var gridFocusID: String?
    @State private var keyMonitor = KeyNavMonitor()
    @FocusState private var focused: Bool
    @AppStorage("boardColumnCount") private var columnCount = ChromeMetrics.boardColumnsDefault
    @AppStorage("showGridNotes") private var showGridNotes = true
    @State private var pinchBaseColumns: Int?
    @State private var lastPinchStep = 0
    @State private var isPinching = false
    @State private var pinchDidChange = false
    @State private var suppressGridClicksUntil: Date?
    @State private var localBoardsOnly = false
    @State private var localFlattened = false
    @State private var localSearchActive = false
    @State private var localSearchQuery = ""
    @State private var flattenedContents: [String: [ArenaContentItem]] = [:]
    @State private var isLoadingFlattenedContents = false
    @State private var returnSelections: [Int: ArenaReturnSelection] = [:]

    private var isBrowsingGrid: Bool { selectedItem == nil && !showBoardSearch }

    private var showBoardSearch: Bool {
        get { searchActiveBinding.wrappedValue }
        nonmutating set { searchActiveBinding.wrappedValue = newValue }
    }

    private var boardSearchQuery: String {
        get { searchQueryBinding.wrappedValue }
        nonmutating set { searchQueryBinding.wrappedValue = newValue }
    }

    private var searchActiveBinding: Binding<Bool> {
        Binding(
            get: { searchActive?.wrappedValue ?? localSearchActive },
            set: { newValue in
                if let searchActive {
                    searchActive.wrappedValue = newValue
                } else {
                    localSearchActive = newValue
                }
            }
        )
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { searchQuery?.wrappedValue ?? localSearchQuery },
            set: { newValue in
                if let searchQuery {
                    searchQuery.wrappedValue = newValue
                } else {
                    localSearchQuery = newValue
                }
            }
        )
    }

    private var boardsOnlyActive: Binding<Bool> {
        Binding(
            get: { boardsOnly?.wrappedValue ?? localBoardsOnly },
            set: { newValue in
                if let boardsOnly {
                    boardsOnly.wrappedValue = newValue
                } else {
                    localBoardsOnly = newValue
                }
            }
        )
    }

    private var flattenedActive: Binding<Bool> {
        Binding(
            get: { flattened?.wrappedValue ?? localFlattened },
            set: { newValue in
                if let flattened {
                    flattened.wrappedValue = newValue
                } else {
                    localFlattened = newValue
                }
            }
        )
    }

    private var gridEntries: [ArenaGridEntry] {
        model.items.flatMap { item -> [ArenaGridEntry] in
            guard flattenedActive.wrappedValue,
                  item.kind == .channel,
                  let slug = item.channelSlug,
                  let contents = flattenedContents[slug]
            else {
                return [ArenaGridEntry(item: item, source: currentTarget)]
            }
            let source = ArenaBrowseTarget(slug: slug, title: item.title, urlString: item.previewURL)
            return contents.map { ArenaGridEntry(item: $0, source: source) }
        }
    }

    private var displayedEntries: [ArenaGridEntry] {
        var result = gridEntries
        if boardsOnlyActive.wrappedValue {
            result = result.filter { $0.item.kind == .channel }
        }
        let query = boardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if showBoardSearch, !query.isEmpty {
            result = result.filter {
                BoardContentSearch.matches([$0.item.title, $0.item.notes], query: query)
            }
        }
        return result
    }

    /// Cheap token for focus invalidation (avoids `map(\.id)` allocations).
    private var displayedListIdentity: GridListIdentity<String> {
        var hasher = Hasher()
        hasher.combine(model.items.count)
        hasher.combine(boardsOnlyActive.wrappedValue)
        hasher.combine(showBoardSearch)
        hasher.combine(boardSearchQuery)
        hasher.combine(flattenedActive.wrappedValue)
        hasher.combine(flattenedContents.count)
        for slug in flattenedContents.keys.sorted() {
            hasher.combine(slug)
            hasher.combine(flattenedContents[slug]?.count ?? 0)
        }
        return GridListIdentity(
            count: displayedEntries.count,
            firstID: displayedEntries.first?.id,
            lastID: displayedEntries.last?.id,
            revision: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    private var columns: [GridItem] {
        let count = min(max(columnCount, ChromeMetrics.boardColumnsMin), ChromeMetrics.boardColumnsMax)
        return Array(
            repeating: GridItem(.flexible(minimum: 72), spacing: ColosseumTheme.gridGap),
            count: count
        )
    }

    private var currentTarget: ArenaBrowseTarget {
        stack.last ?? initialTarget
    }

    private var pathSegments: [BoardPathSegment] {
        let source = stack.isEmpty ? [initialTarget] : stack
        return source.map {
            BoardPathSegment(
                id: $0.slug,
                title: ($0.title?.isEmpty == false ? $0.title! : $0.slug)
            )
        }
    }

    private var shouldSuppressGridClicks: Bool {
        if isPinching { return true }
        if let until = suppressGridClicksUntil, Date() < until { return true }
        return false
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if showsInlineChrome {
                    inlineChrome
                    Rectangle()
                        .fill(ColosseumTheme.border)
                        .frame(height: 1)
                }
                content
            }
            .background(ColosseumTheme.canvas)

            if selectedItem != nil {
                ArenaRemoteItemView(
                    items: selectedItemSiblings,
                    selected: $selectedItem,
                    destinationBoard: destinationBoard,
                    onClose: {
                        withAnimation(ColosseumMotion.overlay) {
                            selectedItem = nil
                        }
                        activateFocus()
                    },
                    onBrowseBoard: { target in
                        if let selectedItem {
                            returnSelections[max(0, stack.count - 1)] = ArenaReturnSelection(
                                item: selectedItem,
                                siblings: selectedItemSiblings
                            )
                        }
                        withAnimation(ColosseumMotion.overlay) {
                            push(target)
                            selectedItem = nil
                        }
                    }
                )
                .transition(ColosseumMotion.overlayTransition)
                .zIndex(20)
            }
        }
        .animation(ColosseumMotion.overlay, value: selectedItem?.id)
        .animation(ColosseumMotion.overlay, value: showBoardSearch)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            if stack.isEmpty {
                stack = [initialTarget]
            }
            model.load(currentTarget)
            if let initialSelectedItem {
                selectedItemSiblings = initialSelectedSiblings.isEmpty
                    ? [initialSelectedItem]
                    : initialSelectedSiblings
                selectedItem = initialSelectedItem
            }
            activateFocus()
        }
        .onDisappear { keyMonitor.remove() }
        .onChange(of: selectedItem?.id) { _, id in
            // Keep the monitor installed during header search so Esc always dismisses.
            if id == nil {
                activateFocus()
            } else {
                keyMonitor.remove()
            }
        }
        .onChange(of: showConnect) { _, isPresented in
            if isPresented {
                keyMonitor.remove()
            } else if selectedItem == nil {
                activateFocus()
            } else {
                installKeyMonitor()
            }
        }
        .onChange(of: showBoardSearch) { _, searching in
            if !searching, selectedItem == nil {
                activateFocus()
            } else if searching, selectedItem == nil {
                installKeyMonitor()
            }
        }
        .onChange(of: stack) { oldStack, newStack in
            guard let last = newStack.last else { return }
            stopHover()
            let returnSelection = returnSelections.removeValue(forKey: newStack.count - 1)
            if newStack.count < oldStack.count {
                returnSelections = returnSelections.filter { $0.key < newStack.count }
            }
            selectedItem = returnSelection?.item
            selectedItemSiblings = returnSelection?.siblings ?? []
            model.load(last)
            flattenedContents = [:]
            gridFocusID = nil
            if returnSelection == nil {
                activateFocus()
            }
        }
        .onChange(of: displayedListIdentity) { _, _ in
            gridFocusID = GridListIdentity.revalidatedFocus(
                gridFocusID,
                in: displayedEntries.lazy.map(\.id)
            )
        }
        .onChange(of: boardsOnlyActive.wrappedValue) { _, _ in
            gridFocusID = GridListIdentity.revalidatedFocus(
                gridFocusID,
                in: displayedEntries.lazy.map(\.id)
            )
        }
        .onChange(of: flattenedActive.wrappedValue) { _, isFlattened in
            gridFocusID = GridListIdentity.revalidatedFocus(
                gridFocusID,
                in: displayedEntries.lazy.map(\.id)
            )
            if isFlattened {
                Task { await loadFlattenedContents() }
            }
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading, flattenedActive.wrappedValue {
                Task { await loadFlattenedContents() }
            }
        }
        .onExitCommand(perform: handleEscape)
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
        .background {
            Group {
                Button("") {
                    withAnimation(ColosseumMotion.soft) {
                        boardsOnlyActive.wrappedValue.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: [])
                Button("") {
                    withAnimation(ColosseumMotion.soft) {
                        showGridNotes.toggle()
                    }
                }
                .keyboardShortcut("n", modifiers: [])
                Button("") {
                    withAnimation(ColosseumMotion.soft) {
                        flattenedActive.wrappedValue.toggle()
                    }
                }
                .keyboardShortcut("f", modifiers: [])
                Button("", action: handleEscape)
                    .keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .allowsHitTesting(false)
            // A modal overlay owns the keyboard: bare `b` / `n` / `f` must reach its search field.
            .disabled(overlays.isPresented)
        }
        .modifier(ArenaBrowserNotifications(
            onOpenCommand: openOnArena,
            onArenaImport: { Task { await importEntireBoard() } },
            onSearch: toggleBoardSearch,
            onColumnsIncrease: { adjustColumns(by: 1) },
            onColumnsDecrease: { adjustColumns(by: -1) }
        ))
        .overlay(alignment: .bottom) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.secondaryText)
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s2)
                    .background(ColosseumTheme.elevated)
                    .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
                    .padding(.bottom, Space.s4)
            }
            if isLoadingFlattenedContents {
                Text("Flattening child boards…")
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.secondaryText)
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s2)
                    .background(ColosseumTheme.elevated)
                    .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
                    .padding(.bottom, statusMessage == nil ? 20 : 54)
            }
        }
        .highPriorityGesture(columnPinchGesture)
        .modalOverlay(isPresented: $showConnect) {
            if let channel = model.channel {
                ConnectOverlay(
                    block: nil,
                    nestedBoard: nil,
                    remoteItem: ArenaContentItem.channel(channel),
                    excludeBoardID: nil,
                    onDismiss: { showConnect = false }
                )
            }
        }
    }

    private var inlineChrome: some View {
        ZStack {
            HStack(alignment: .center, spacing: 0) {
                BoardPathBreadcrumb(
                    segments: pathSegments,
                    currentColor: ColosseumTheme.remoteBoardTitle,
                    onSegmentTap: jump(to:)
                )

                Spacer(minLength: Space.s2)

                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                    Text(importProgress)
                        .font(.system(size: TypeScale.t0))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                }

                if selectedItem == nil {
                    HStack(alignment: .center, spacing: Space.s2) {
                        BoardsOnlyFilterIcon(isActive: boardsOnlyActive)
                        FlattenToggleIcon(isActive: flattenedActive)
                        ColumnDensityControl(columnCount: $columnCount)
                    }
                }
            }

            ColosseumCenterHeaderSlot(
                isSearching: showBoardSearch,
                searchQuery: searchQueryBinding,
                placeholder: "Search…",
                visible: false,
                onDismissSearch: {
                    withAnimation(ColosseumMotion.overlay) {
                        dismissBoardSearch()
                    }
                }
            ) {
                Color.clear
                    .frame(
                        width: ChromeMetrics.headerCenterWidth,
                        height: ChromeMetrics.controlHeight
                    )
            }
        }
        .padding(.horizontal, ChromeMetrics.contentInset)
        .frame(height: ChromeMetrics.controlHeight + 16)
        .background(ColosseumTheme.canvas)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.items.isEmpty {
            ScrollView {
                LazyVGrid(columns: columns, spacing: ColosseumTheme.gridGap) {
                    ForEach(0..<(columnCount * 2), id: \.self) { _ in
                        if showGridNotes {
                            VStack(alignment: .leading, spacing: Space.s2) {
                                ShimmerBlockPlaceholder()
                                Color.clear.frame(height: 16)
                            }
                        } else {
                            ShimmerBlockPlaceholder()
                        }
                    }
                }
                .padding(Space.s5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.items.isEmpty {
            VStack(spacing: Space.s2) {
                Text("Couldn’t load channel")
                    .font(.system(size: TypeScale.t2, weight: .bold))
                    .foregroundStyle(ColosseumTheme.primaryText)
                Text(error)
                    .font(.system(size: TypeScale.t1))
                    .foregroundStyle(ColosseumTheme.secondaryText)
                    .multilineTextAlignment(.center)
                Button("Retry") { model.load(currentTarget) }
                    .buttonStyle(ChromeButtonStyle(emphasized: true))
                    .pointingHandCursor()
            }
            .padding(Space.s7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showBoardSearch,
                  !boardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  displayedEntries.isEmpty {
            Text("no results")
                .font(.system(size: TypeScale.t2))
                .foregroundStyle(ColosseumTheme.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: ColosseumTheme.gridGap) {
                        ForEach(displayedEntries) { entry in
                            let item = entry.item
                            Button {
                                guard !shouldSuppressGridClicks else { return }
                                gridFocusID = entry.id
                                open(entry)
                            } label: {
                                GridBlockChrome(
                                    notes: item.notes,
                                    title: item.title,
                                    searchQuery: showBoardSearch ? boardSearchQuery : "",
                                    isSelected: entry.id == gridFocusID && isBrowsingGrid,
                                    showsNotes: showGridNotes
                                ) {
                                    ArenaRemoteCell(
                                        item: item,
                                        isHovering: hoveringItemID == item.id,
                                        isSelected: entry.id == gridFocusID && isBrowsingGrid,
                                        hoverPlayer: hoveringItemID == item.id ? hoverVideo : nil
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .id(entry.id)
                            .pointingHandCursor()
                            .onHover { hovering in
                                handleHover(item: item, hovering: hovering)
                            }
                            .onAppear {
                                // With boards-only, keep paging off the full list so sparse channels still load.
                                if boardsOnlyActive.wrappedValue {
                                    model.loadMoreIfNeeded(currentItem: model.items.last)
                                } else {
                                    model.loadMoreIfNeeded(currentItem: item)
                                }
                            }
                            .contextMenu {
                                if let destinationBoard {
                                    Button("Save to “\(destinationBoard.title)”") {
                                        Task { await save(item, to: destinationBoard) }
                                    }
                                }
                                if item.kind == .channel {
                                    Button("Browse channel") { open(entry) }
                                }
                                if let urlString = item.previewURL ?? item.sourceURL,
                                   let url = URL(string: urlString) {
                                    Button("Open original") { NSWorkspace.shared.open(url) }
                                }
                            }
                        }
                    }
                    .padding(Space.s5)
                    .animation(ColosseumMotion.standard, value: columnCount)
                    .animation(ColosseumMotion.standard, value: boardsOnlyActive.wrappedValue)
                    .animation(ColosseumMotion.standard, value: showGridNotes)
                    .allowsHitTesting(!isPinching)

                    if model.isLoadingMore {
                        LazyVGrid(columns: columns, spacing: ColosseumTheme.gridGap) {
                            ForEach(0..<min(columnCount, 4), id: \.self) { _ in
                                ShimmerBlockPlaceholder()
                            }
                        }
                        .padding(.horizontal, Space.s5)
                        .padding(.bottom, Space.s5)
                    }
                }
                .onChange(of: gridFocusID) { _, id in
                    guard let id, isBrowsingGrid else { return }
                    withAnimation(ColosseumMotion.soft) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func activateFocus() {
        focused = true
        installKeyMonitor()
        DispatchQueue.main.async {
            focused = true
            if gridFocusID == nil {
                gridFocusID = displayedEntries.first?.id
            }
        }
    }

    private func installKeyMonitor() {
        keyMonitor.onLeft = { moveGridFocus(delta: -1) }
        keyMonitor.onRight = { moveGridFocus(delta: 1) }
        keyMonitor.onUp = { moveGridFocus(delta: -columnCount) }
        keyMonitor.onDown = { moveGridFocus(delta: columnCount) }
        keyMonitor.onEnter = { activateFocusedItem() }
        keyMonitor.onEscape = {
            if showBoardSearch {
                withAnimation(ColosseumMotion.overlay) {
                    dismissBoardSearch()
                }
                return
            }
            // Item detail (and its Connect sheet) owns Esc while open.
            if selectedItem != nil { return }
            handleEscape()
        }
        keyMonitor.onCopy = {
            guard isBrowsingGrid else { return false }
            return copyFocusedItem()
        }
        keyMonitor.onCharacter = { char in
            guard isBrowsingGrid else { return false }
            if char == "c", model.channel != nil {
                DispatchQueue.main.async { showConnect = true }
                return true
            }
            if char == "b" {
                DispatchQueue.main.async {
                    withAnimation(ColosseumMotion.soft) {
                        boardsOnlyActive.wrappedValue.toggle()
                    }
                }
                return true
            }
            if char == "n" {
                DispatchQueue.main.async {
                    withAnimation(ColosseumMotion.soft) {
                        showGridNotes.toggle()
                    }
                }
                return true
            }
            if char == "f" {
                DispatchQueue.main.async {
                    withAnimation(ColosseumMotion.soft) {
                        flattenedActive.wrappedValue.toggle()
                    }
                }
                return true
            }
            return false
        }
        // Ignore arrows/enter while searching or in item detail; Esc still routes here
        // (including when the header search field is first responder).
        keyMonitor.shouldIgnoreNavigation = { selectedItem != nil || showBoardSearch || showConnect }
        keyMonitor.install()
    }

    private func toggleBoardSearch() {
        guard selectedItem == nil else { return }
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
        activateFocus()
    }

    @discardableResult
    private func copyFocusedItem() -> Bool {
        guard let focusID = gridFocusID,
              let item = displayedEntries.first(where: { $0.id == focusID })?.item
        else { return false }
        return BlockClipboard.copy(item)
    }

    private func moveGridFocus(delta: Int) {
        guard isBrowsingGrid else { return }
        let items = displayedEntries
        guard !items.isEmpty else { return }
        focused = true
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

    private func activateFocusedItem() {
        guard isBrowsingGrid else { return }
        let items = displayedEntries
        let target = items.first(where: { $0.id == gridFocusID }) ?? items.first
        guard let entry = target else { return }
        gridFocusID = entry.id
        open(entry)
    }

    private func open(_ entry: ArenaGridEntry) {
        let item = entry.item
        if item.kind == .channel, let slug = item.channelSlug {
            withAnimation(ColosseumMotion.soft) {
                push(ArenaBrowseTarget(slug: slug, title: item.title, urlString: item.previewURL))
            }
            return
        }
        selectedItemSiblings = siblingItems(for: entry)
        withAnimation(ColosseumMotion.overlay) {
            selectedItem = item
        }
    }

    private func siblingItems(for entry: ArenaGridEntry) -> [ArenaContentItem] {
        let sourceItems = entry.source.slug == currentTarget.slug
            ? model.items
            : flattenedContents[entry.source.slug] ?? []
        return sourceItems.filter { $0.kind != .channel }
    }

    @MainActor
    private func loadFlattenedContents() async {
        guard flattenedActive.wrappedValue, !isLoadingFlattenedContents else { return }
        let targetSlug = currentTarget.slug
        isLoadingFlattenedContents = true
        defer { isLoadingFlattenedContents = false }

        await model.loadAllRemaining()
        guard currentTarget.slug == targetSlug, flattenedActive.wrappedValue else { return }

        let channels = model.items.compactMap { item -> (String, ArenaContentItem)? in
            guard item.kind == .channel, let slug = item.channelSlug else { return nil }
            return (slug, item)
        }
        for (slug, _) in channels where flattenedContents[slug] == nil {
            guard currentTarget.slug == targetSlug, flattenedActive.wrappedValue else { return }
            if let contents = try? await ArenaService.fetchAllContents(slug: slug) {
                flattenedContents[slug] = contents
            }
        }
    }

    private func push(_ target: ArenaBrowseTarget) {
        stopHover()
        boardsOnlyActive.wrappedValue = false
        stack.append(target)
    }

    private func jump(to index: Int) {
        guard index >= 0, index < stack.count else { return }
        withAnimation(ColosseumMotion.soft) {
            boardsOnlyActive.wrappedValue = false
            stack = Array(stack.prefix(index + 1))
        }
    }

    private func pop() {
        stopHover()
        guard stack.count > 1 else {
            onClose()
            return
        }
        withAnimation(ColosseumMotion.soft) {
            boardsOnlyActive.wrappedValue = false
            stack.removeLast()
        }
    }

    private func handleEscape() {
        // Esc belongs to the connect overlay while it is up — never fall through.
        if showConnect {
            showConnect = false
            return
        }
        if showBoardSearch {
            withAnimation(ColosseumMotion.overlay) {
                dismissBoardSearch()
            }
            return
        }
        if selectedItem != nil {
            withAnimation(ColosseumMotion.overlay) {
                selectedItem = nil
            }
            return
        }
        if stack.count > 1 {
            pop()
        } else {
            onClose()
        }
    }

    private func openOnArena() {
        guard let url = model.channel?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func handleHover(item: ArenaContentItem, hovering: Bool) {
        if item.isAnimatedImage {
            if hovering {
                stopHover()
                hoveringItemID = item.id
            } else if hoveringItemID == item.id {
                stopHover()
            }
            return
        }
        guard (item.isVideo || item.isAudio),
              let urlString = item.attachmentURL,
              let url = URL(string: urlString)
        else {
            if hoveringItemID == item.id { stopHover() }
            return
        }
        if hovering {
            stopHover()
            hoveringItemID = item.id
            let player = VideoPlayback.looping(url: url, muted: item.isVideo)
            hoverVideo = player
            player.play()
        } else if hoveringItemID == item.id {
            stopHover()
        }
    }

    private func stopHover() {
        hoverVideo?.stop()
        hoverVideo = nil
        hoveringItemID = nil
    }

    private func save(_ item: ArenaContentItem, to board: Board) async {
        do {
            try await ArenaImportService.saveItem(item, into: board, context: context)
            statusMessage = "Saved to \(board.title)"
            try? await Task.sleep(for: .seconds(2))
            if statusMessage == "Saved to \(board.title)" { statusMessage = nil }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func importEntireBoard() async {
        guard let channel = model.channel else { return }
        isImporting = true
        importProgress = "Importing…"
        defer { isImporting = false }
        do {
            let board = try await ArenaImportService.importChannel(
                fromURLString: channel.url.absoluteString,
                context: context
            ) { progress in
                importProgress = progress.phase
            }
            onImportedBoard?(board)
            statusMessage = "Imported “\(board.title)”"
            try? await Task.sleep(for: .seconds(1.5))
            onClose()
        } catch {
            statusMessage = error.localizedDescription
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
                guard isBrowsingGrid else { return }
                if pinchBaseColumns == nil {
                    isPinching = true
                    pinchDidChange = false
                    pinchBaseColumns = columnCount
                    lastPinchStep = 0
                }
                if abs(value - 1) > 0.04 {
                    pinchDidChange = true
                }
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
                    suppressGridClicksUntil = Date().addingTimeInterval(0.35)
                }
                isPinching = false
                pinchDidChange = false
                pinchBaseColumns = nil
                lastPinchStep = 0
            }
    }
}

/// Keeps ArenaBrowserView.body under the type-checker limit.
private struct ArenaBrowserNotifications: ViewModifier {
    let onOpenCommand: () -> Void
    let onArenaImport: () -> Void
    let onSearch: () -> Void
    let onColumnsIncrease: () -> Void
    let onColumnsDecrease: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .colosseumOpenCommand)) { _ in
                onOpenCommand()
            }
            .onReceive(NotificationCenter.default.publisher(for: .colosseumArenaImport)) { _ in
                onArenaImport()
            }
            .onReceive(NotificationCenter.default.publisher(for: .colosseumSearch)) { _ in
                onSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .colosseumColumnsIncrease)) { _ in
                onColumnsIncrease()
            }
            .onReceive(NotificationCenter.default.publisher(for: .colosseumColumnsDecrease)) { _ in
                onColumnsDecrease()
            }
    }
}

// MARK: - Grid cell

struct ArenaRemoteCell: View {
    let item: ArenaContentItem
    var isHovering: Bool
    var isSelected: Bool = false
    var hoverPlayer: LoopingVideoPlayer?

    private var wantsPlayback: Bool { isHovering || isSelected }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if item.isAnimatedImage,
                   wantsPlayback,
                   let urlString = item.imageURL ?? item.attachmentURL,
                   let url = URL(string: urlString) {
                    RemoteAnimatedImageView(
                        url: url,
                        placeholderURL: item.gridImageURL.flatMap(URL.init(string:)),
                        square: true
                    )
                        .allowsHitTesting(false)
                } else if item.isVideo, isHovering, let hoverPlayer {
                    PlayerView(player: hoverPlayer.player, showsControls: false)
                        .allowsHitTesting(false)
                } else if item.isAudio {
                    audioCard
                } else if item.kind == .text {
                    textCard
                } else if item.kind == .channel {
                    channelCard
                } else if let urlString = item.gridImageURL, let url = URL(string: urlString) {
                    ShimmerRemoteImage(url: url, showsBorder: false) {
                        placeholder(systemName: "photo")
                    }
                } else if item.kind == .link {
                    placeholder(systemName: "link")
                } else {
                    placeholder(systemName: "square.dashed")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .background(ColosseumTheme.surface)

            if item.isVideo, !isHovering {
                Image(systemName: "play.rectangle")
                    .font(.system(size: TypeScale.t1))
                    .foregroundStyle(ColosseumTheme.onMedia)
                    .padding(Space.s2)
            } else if item.isAudio {
                Image(systemName: isHovering ? "speaker.wave.2.fill" : "waveform")
                    .font(.system(size: isHovering ? TypeScale.t2 : TypeScale.t1))
                    .foregroundStyle(ColosseumTheme.onMedia)
                    .padding(Space.s2)
            }
        }
        .overlay(
            Rectangle().stroke(
                ColosseumTheme.border,
                lineWidth: 1
            )
        )
    }

    private var textCard: some View {
        Text(item.textBody.isEmpty ? item.displayTitle : item.textBody)
            .font(.system(size: TypeScale.t1))
            .foregroundStyle(ColosseumTheme.primaryText)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Space.s3)
            .background(ColosseumTheme.canvas)
    }

    private var channelCard: some View {
        VStack(spacing: Space.s1) {
            Text(item.displayTitle)
                .font(.system(size: TypeScale.t2))
                .foregroundStyle(ColosseumTheme.remoteBoardTitle)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if let owner = item.channelOwnerName {
                Text("by \(owner)")
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.secondaryText)
            }
            Text("\(item.channelBlockCount) blocks")
                .font(.system(size: TypeScale.t0))
                .foregroundStyle(ColosseumTheme.secondaryText)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColosseumTheme.canvas)
    }

    private var audioCard: some View {
        VStack(spacing: Space.s2) {
            Image(systemName: "waveform")
                .font(.system(size: TypeScale.t6))
                .foregroundStyle(ColosseumTheme.secondaryText)
            Text(item.displayTitle)
                .font(.system(size: TypeScale.t1))
                .foregroundStyle(ColosseumTheme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColosseumTheme.surface)
    }

    private func placeholder(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: TypeScale.t5))
            .foregroundStyle(ColosseumTheme.tertiaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ColosseumTheme.surface)
    }
}

// MARK: - Item detail

private struct ArenaRemoteItemView: View {
    let items: [ArenaContentItem]
    @Binding var selected: ArenaContentItem?
    var destinationBoard: Board?
    var onClose: () -> Void
    var onBrowseBoard: (ArenaBrowseTarget) -> Void

    @Environment(\.modelContext) private var context
    @State private var loopingPlayer: LoopingVideoPlayer?
    @State private var showConnect = false
    @State private var showMeta = false
    @State private var statusMessage: String?
    @State private var keyMonitor = KeyNavMonitor()
    @FocusState private var focused: Bool
    @State private var remoteConnections: [ArenaRemoteConnection] = []
    @State private var isLoadingConnections = false
    @State private var connectionsError: String?
    /// Index into `remoteConnections`; `nil` until ↑/↓ is used.
    @State private var connectionFocusIndex: Int?

    private var index: Int {
        guard let selected else { return 0 }
        return items.firstIndex(where: { $0.id == selected.id }) ?? 0
    }

    private var item: ArenaContentItem? { selected }

    var body: some View {
        HStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            Divider().overlay(ColosseumTheme.border)
            sidebar
                .frame(width: ColosseumTheme.sidebarWidth, alignment: .leading)
        }
        .background(ColosseumTheme.canvas)
        .overlay(alignment: .bottomLeading) {
            if let item {
                metaButton(for: item)
                    .padding(Space.s3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: Space.s2) {
                ShortcutHint(text: "←")
                ShortcutHint(text: "→")
                ShortcutHint(text: "↑↓")
                ShortcutHint(text: "↩")
                ShortcutHint(text: "⌘C")
                ShortcutHint(text: "c")
                ShortcutHint(text: "esc")
            }
            .allowsHitTesting(false)
            .padding(Space.s3)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            focused = true
            reloadPlayer()
            installKeyMonitor()
            Task { await loadConnections() }
        }
        .onDisappear { keyMonitor.remove() }
        .onChange(of: selected?.id) { _, _ in
            focused = true
            showMeta = false
            connectionFocusIndex = nil
            reloadPlayer()
            Task { await loadConnections() }
        }
        .onChange(of: showConnect) { _, isPresented in
            if isPresented {
                keyMonitor.remove()
            } else {
                focused = true
                installKeyMonitor()
            }
        }
        .onExitCommand(perform: handleEscape)
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !showConnect else { return .ignored }
            moveConnectionFocus(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !showConnect else { return .ignored }
            moveConnectionFocus(1)
            return .handled
        }
        .onKeyPress(.return) {
            guard !showConnect else { return .ignored }
            activateFocusedRemoteConnection()
            return .handled
        }
        .onMoveCommand { direction in
            guard !showConnect else { return }
            switch direction {
            case .up: moveConnectionFocus(-1)
            case .down: moveConnectionFocus(1)
            default: break
            }
        }
        .modalOverlay(isPresented: $showConnect) {
            if let item {
                ConnectOverlay(
                    block: nil,
                    nestedBoard: nil,
                    remoteItem: item,
                    excludeBoardID: nil,
                    onDismiss: { showConnect = false }
                )
            }
        }
    }

    private func installKeyMonitor() {
        keyMonitor.onLeft = { step(-1) }
        keyMonitor.onRight = { step(1) }
        keyMonitor.onUp = { moveConnectionFocus(-1) }
        keyMonitor.onDown = { moveConnectionFocus(1) }
        keyMonitor.onEnter = { activateFocusedRemoteConnection() }
        keyMonitor.onEscape = { handleEscape() }
        keyMonitor.onCopy = {
            guard let item else { return false }
            return BlockClipboard.copy(item)
        }
        keyMonitor.onCharacter = { char in
            guard char == "c", item != nil else { return false }
            DispatchQueue.main.async { showConnect = true }
            return true
        }
        keyMonitor.shouldIgnoreNavigation = { showConnect }
        keyMonitor.install()
    }

    private func moveConnectionFocus(_ delta: Int) {
        guard !remoteConnections.isEmpty else { return }
        if let current = connectionFocusIndex {
            connectionFocusIndex = max(0, min(remoteConnections.count - 1, current + delta))
        } else {
            connectionFocusIndex = delta > 0 ? 0 : remoteConnections.count - 1
        }
        focused = true
    }

    private func activateFocusedRemoteConnection() {
        guard let connectionFocusIndex,
              remoteConnections.indices.contains(connectionFocusIndex)
        else { return }
        let connection = remoteConnections[connectionFocusIndex]
        onBrowseBoard(ArenaBrowseTarget(
            slug: connection.slug,
            title: connection.title,
            urlString: connection.arenaURLString
        ))
    }

    private func browse(_ connection: ArenaRemoteConnection) {
        onBrowseBoard(ArenaBrowseTarget(
            slug: connection.slug,
            title: connection.title,
            urlString: connection.arenaURLString
        ))
    }

    private func handleEscape() {
        if showConnect {
            showConnect = false
            return
        }
        if showMeta {
            withAnimation(ColosseumMotion.soft) { showMeta = false }
            return
        }
        onClose()
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            ColosseumTheme.canvas
            if let item {
                Group {
                    switch item.kind {
                case .image, .link, .attachment, .other:
                    if item.isVideo {
                        ZStack {
                            if let loopingPlayer {
                                PlayerView(player: loopingPlayer.player)
                                    .padding(Space.s5)
                                    .transition(ColosseumMotion.mediaReveal)
                            } else {
                                ShimmerBlockPlaceholder(square: false)
                                    .padding(Space.s5)
                                    .transition(.opacity)
                            }
                        }
                        .animation(ColosseumMotion.standard, value: loopingPlayer != nil)
                    } else if item.isAudio {
                        VStack(spacing: Space.s4) {
                            Image(systemName: "waveform")
                                .font(.system(size: TypeScale.t8))
                                .foregroundStyle(ColosseumTheme.secondaryText)
                            Text(item.displayTitle)
                                .font(.system(size: TypeScale.t4))
                                .foregroundStyle(ColosseumTheme.primaryText)
                                .multilineTextAlignment(.center)
                            if let loopingPlayer {
                                PlayerView(player: loopingPlayer.player)
                                    .frame(maxWidth: 520)
                                    .frame(height: 64)
                            }
                        }
                        .padding(Space.s7)
                    } else if item.isAnimatedImage,
                              let urlString = item.imageURL ?? item.attachmentURL,
                              let url = URL(string: urlString) {
                        RemoteAnimatedImageView(
                            url: url,
                            placeholderURL: item.gridImageURL.flatMap(URL.init(string:)),
                            contentPadding: 24
                        )
                    } else if let urlString = item.imageURL ?? item.gridImageURL,
                              let url = URL(string: urlString) {
                        ShimmerRemoteImage(
                            url: url,
                            square: false,
                            contentPadding: 24,
                            fullResolution: true
                        ) {
                            remotePlaceholder("Couldn’t load image")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if item.kind == .link {
                        linkPlaceholder(item)
                    } else {
                        remotePlaceholder(item.displayTitle)
                    }
                case .text:
                    ScrollView {
                        Text(item.textBody.isEmpty ? item.displayTitle : item.textBody)
                            .font(.system(size: TypeScale.t4))
                            .foregroundStyle(ColosseumTheme.primaryText)
                            .frame(maxWidth: 640, alignment: .leading)
                            .padding(Space.s7)
                    }
                case .channel:
                    VStack(spacing: Space.s2) {
                        Text(item.displayTitle)
                            .font(.system(size: TypeScale.t5))
                            .foregroundStyle(ColosseumTheme.remoteBoardTitle)
                        if let owner = item.channelOwnerName {
                            Text("by \(owner)").foregroundStyle(ColosseumTheme.secondaryText)
                        }
                        if let slug = item.channelSlug {
                            Button("Browse channel") {
                                onBrowseBoard(ArenaBrowseTarget(
                                    slug: slug,
                                    title: item.title,
                                    urlString: item.previewURL
                                ))
                            }
                            .buttonStyle(ChromeButtonStyle(emphasized: true))
                            .pointingHandCursor()
                        }
                    }
                }
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s3) {
                        if !item.notes.isEmpty {
                            Text(item.notes)
                                .font(.system(size: TypeScale.t2))
                                .foregroundStyle(ColosseumTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("notes…")
                                .font(.system(size: TypeScale.t2))
                                .foregroundStyle(ColosseumTheme.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if item.kind == .text, !item.textBody.isEmpty {
                            Text(item.textBody)
                                .font(.system(size: TypeScale.t2))
                                .foregroundStyle(ColosseumTheme.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Space.s2)
                                .background(ColosseumTheme.surface)
                                .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
                        }

                        actionRow(for: item)

                        if let statusMessage {
                            Text(statusMessage)
                                .font(.system(size: TypeScale.t0))
                                .foregroundStyle(ColosseumTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Text("Remote preview — not stored locally")
                            .font(.system(size: TypeScale.t0))
                            .foregroundStyle(ColosseumTheme.tertiaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Space.s1)

                            remoteConnectionsSection
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s3)
                        .padding(.bottom, Space.s5)
                    }
                    .onChange(of: connectionFocusIndex) { _, index in
                        guard let index, remoteConnections.indices.contains(index) else { return }
                        withAnimation(ColosseumMotion.soft) {
                            proxy.scrollTo(remoteConnections[index].id, anchor: .center)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ColosseumTheme.canvas)
    }

    @ViewBuilder
    private var remoteConnectionsSection: some View {
        Text("Connections \(remoteConnections.count)")
            .font(.system(size: TypeScale.t1))
            .foregroundStyle(ColosseumTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.s2)

        if isLoadingConnections && remoteConnections.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.s1)
        } else if let connectionsError, remoteConnections.isEmpty {
            Text(connectionsError)
                .font(.system(size: TypeScale.t0))
                .foregroundStyle(ColosseumTheme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.s1)
        } else if remoteConnections.isEmpty {
            Text("Not connected to any boards.")
                .font(.system(size: TypeScale.t0))
                .foregroundStyle(ColosseumTheme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.s1)
        } else {
            VStack(alignment: .leading, spacing: Space.s1) {
                ForEach(Array(remoteConnections.enumerated()), id: \.element.id) { index, connection in
                    let isFocused = connectionFocusIndex == index
                    Button {
                        connectionFocusIndex = index
                        browse(connection)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Space.nudge) {
                                Text(connection.title)
                                    .foregroundStyle(
                                        isFocused
                                            ? ColosseumTheme.remoteBoardTitle
                                            : ColosseumTheme.remoteBoardTitle.opacity(0.75)
                                    )
                                    .fontWeight(isFocused ? .medium : .regular)
                                    .multilineTextAlignment(.leading)
                                Text(
                                    [
                                        "\(connection.blockCount)",
                                        connection.updatedAt.map(ColosseumFormatters.relativeDate)
                                    ]
                                    .compactMap { $0 }
                                    .joined(separator: " · ")
                                )
                                .font(.system(size: TypeScale.t0))
                                .foregroundStyle(ColosseumTheme.tertiaryText)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Space.s2)
                        .padding(.vertical, Space.s1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isFocused ? ColosseumTheme.surface : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .id(connection.id)
                    .animation(ColosseumMotion.soft, value: isFocused)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.s1)
        }
    }

    @ViewBuilder
    private func actionRow(for item: ArenaContentItem) -> some View {
        // The icon cluster grows with the item's capabilities. Rather than let a
        // full row squeeze the Connect label, drop the icons onto their own line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s2) {
                connectButton
                actionIcons(for: item)
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                connectButton
                HStack(spacing: Space.s2) { actionIcons(for: item) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectButton: some View {
        Button("Connect →") { showConnect = true }
            .buttonStyle(ChromeButtonStyle(emphasized: true))
            .pointingHandCursor()
    }

    @ViewBuilder
    private func actionIcons(for item: ArenaContentItem) -> some View {
            if let source = item.sourceURL ?? item.previewURL, let url = URL(string: source) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Open source URL")
                .pointingHandCursor()
            }

            if item.kind == .channel,
               let slug = item.channelSlug {
                let owner = item.channelOwnerSlug ?? "are.na"
                if let url = URL(string: "https://www.are.na/\(owner)/\(slug)") {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .buttonStyle(ChromeIconButtonStyle())
                    .help("Open on Are.na")
                    .pointingHandCursor()
                }
            }

    }

    @ViewBuilder
    private func metaButton(for item: ArenaContentItem) -> some View {
        Button {
            withAnimation(ColosseumMotion.soft) {
                showMeta.toggle()
            }
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(ChromeIconButtonStyle(active: showMeta))
        .help("Metadata")
        .pointingHandCursor()
        .overlay(alignment: .bottomLeading) {
            if showMeta {
                remoteMetaOverlay(for: item)
                    .fixedSize()
                    // Sits on top of the bar, left edge flush with the button.
                    .offset(y: -(ChromeMetrics.controlHeight + Space.s2))
                    .transition(ColosseumMotion.fade)
            }
        }
    }

    @ViewBuilder
    private func remoteMetaOverlay(for item: ArenaContentItem) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(item.displayTitle)
                .font(.system(size: TypeScale.t2))
                .foregroundStyle(
                    item.kind == .channel
                        ? ColosseumTheme.remoteBoardTitle
                        : ColosseumTheme.primaryText
                )

            VStack(spacing: 0) {
                metaRow(
                    "Content type",
                    item.isVideo ? "video" : item.isAudio ? "audio" : item.typeName.lowercased()
                )
                if item.imageWidth > 0, item.imageHeight > 0 {
                    metaRow("Dimensions", "\(item.imageWidth) × \(item.imageHeight)")
                }
                if item.imageBytes > 0 {
                    metaRow("File size", ColosseumFormatters.byteCount(item.imageBytes))
                } else if item.attachmentBytes > 0 {
                    metaRow("File size", ColosseumFormatters.byteCount(item.attachmentBytes))
                }
                if item.kind == .channel {
                    metaRow("Blocks", "\(item.channelBlockCount)")
                    if let owner = item.channelOwnerName {
                        metaRow("By", owner)
                    }
                }
                if let source = item.sourceURL, !source.isEmpty {
                    metaRow("Source", source)
                }
            }
        }
        .padding(Space.s3)
        .frame(width: 260, alignment: .leading)
        .background(ColosseumTheme.elevated)
        .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
        .floatingPanelShadow()
        .allowsHitTesting(true)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: TypeScale.t1))
                .foregroundStyle(ColosseumTheme.tertiaryText)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: TypeScale.t1))
                .foregroundStyle(ColosseumTheme.primaryText)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ColosseumTheme.border).frame(height: 0.5)
        }
    }

    private func linkPlaceholder(_ item: ArenaContentItem) -> some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "link")
                .font(.system(size: TypeScale.t7))
                .foregroundStyle(ColosseumTheme.secondaryText)
            Text(item.displayTitle)
                .font(.system(size: TypeScale.t4))
                .foregroundStyle(ColosseumTheme.primaryText)
            if let source = item.sourceURL, let url = URL(string: source) {
                Button("Open link") { NSWorkspace.shared.open(url) }
                    .buttonStyle(ChromeButtonStyle(emphasized: true))
                    .pointingHandCursor()
            }
        }
    }

    private func remotePlaceholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(ColosseumTheme.secondaryText)
    }

    private func step(_ delta: Int) {
        guard !showConnect, !items.isEmpty else { return }
        let next = index + delta
        guard next >= 0, next < items.count else { return }
        selected = items[next]
        focused = true
    }

    private func reloadPlayer() {
        loopingPlayer?.stop()
        loopingPlayer = nil
        guard let item,
              item.isVideo || item.isAudio,
              let urlString = item.attachmentURL,
              let url = URL(string: urlString)
        else {
            return
        }
        let next = VideoPlayback.looping(url: url, muted: false)
        loopingPlayer = next
        next.play()
    }

    @MainActor
    private func loadConnections() async {
        guard let item else {
            remoteConnections = []
            connectionsError = nil
            return
        }
        let itemID = item.id
        isLoadingConnections = true
        connectionsError = nil
        defer { isLoadingConnections = false }
        do {
            let connections = try await ArenaService.fetchConnections(for: item)
            guard selected?.id == itemID else { return }
            remoteConnections = connections
            if let connectionFocusIndex, !connections.indices.contains(connectionFocusIndex) {
                self.connectionFocusIndex = connections.isEmpty ? nil : connections.count - 1
            }
        } catch {
            guard selected?.id == itemID else { return }
            remoteConnections = []
            connectionFocusIndex = nil
            connectionsError = "Couldn’t load connections"
        }
    }
}
