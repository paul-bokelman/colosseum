import AppKit
import SwiftData
import SwiftUI

/// Tracks how many blocking overlays are on screen so ancestor views can
/// disable their bare-character keyboard shortcuts (`b`, `n`, `f`, …).
///
/// The connect overlay lives inside the same window as its host, so unmodified
/// key equivalents would otherwise fire while the user types in its search field.
@MainActor
final class OverlayPresentation: ObservableObject {
    static let shared = OverlayPresentation()

    @Published private(set) var depth = 0

    var isPresented: Bool { depth > 0 }

    func push() { depth += 1 }

    func pop() { depth = max(0, depth - 1) }
}

/// Are.na-style connect panel: pick a board for a block, nested board, or remote item.
///
/// Presented as an in-window overlay (see `modalOverlay`) so it can be dismissed
/// by clicking the scrim. Escape is swallowed by the local key monitor so it never
/// reaches the content behind.
struct ConnectOverlay: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Board.updatedAt, order: .reverse) private var boards: [Board]

    let block: Block?
    let nestedBoard: Board?
    /// When set, selecting a board saves this remote Are.na item into it.
    var remoteItem: ArenaContentItem? = nil
    /// Inverse direction: rows are boards to nest *into* this one, rather than
    /// destinations for a subject. Used by "Connect board" on a board.
    var parentBoard: Board? = nil
    let excludeBoardID: UUID?
    var onDismiss: () -> Void

    @State private var search = ""
    @State private var selection: Option?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var keyMonitor = KeyNavMonitor()
    @FocusState private var searchFocused: Bool

    private enum Option: Hashable {
        case create(String)
        case board(UUID)
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !query.isEmpty }

    private var availableBoards: [Board] {
        boards.filter { board in
            if let excludeBoardID, board.id == excludeBoardID { return false }
            if let nestedBoard, board.id == nestedBoard.id { return false }
            if let parentBoard, board.id == parentBoard.id { return false }
            return true
        }
    }

    private var filtered: [Board] {
        guard isSearching else { return availableBoards }
        return availableBoards.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Exact title already exists — no point offering to create a duplicate.
    private var canCreate: Bool {
        isSearching && !availableBoards.contains { $0.title.caseInsensitiveCompare(query) == .orderedSame }
    }

    /// Keyboard-navigable rows, top to bottom.
    private var options: [Option] {
        var result: [Option] = []
        if canCreate { result.append(.create(query)) }
        result.append(contentsOf: filtered.map { Option.board($0.id) })
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            results
        }
        .frame(width: ColosseumTheme.panelWidth, height: 560)
        .background(ColosseumTheme.canvas)
        // Swallow clicks so taps on the panel never reach the dismiss scrim.
        .contentShape(Rectangle())
        .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
        .onAppear {
            selection = defaultSelection()
            installKeyMonitor()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onDisappear {
            keyMonitor.remove()
            if let block, block.connections.isEmpty {
                ImportService.deleteOrphanedBlockIfNeeded(block, context: context)
                try? context.save()
            }
        }
        .onChange(of: search) { _, _ in
            errorMessage = nil
            revalidateSelection()
        }
        .onChange(of: boards.map(\.id)) { _, _ in revalidateSelection() }
        .onExitCommand(perform: dismiss)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            ConnectTargetThumb(
                url: thumbURL,
                fallbackSymbol: fallbackSymbol,
                accent: remoteItem?.kind == .channel || nestedBoard != nil || parentBoard != nil
            )

            Text(targetTitle)
                .font(.system(size: TypeScale.t3))
                .foregroundStyle(ColosseumTheme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
            } else {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: TypeScale.t2))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close")
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s4)
        .padding(.bottom, Space.s3)
    }

    private var targetTitle: String {
        if let parentBoard { return parentBoard.title.isEmpty ? "Untitled" : parentBoard.title }
        if let remoteItem { return remoteItem.displayTitle }
        if let nestedBoard { return nestedBoard.title.isEmpty ? "Untitled" : nestedBoard.title }
        if let block { return block.displayTitle }
        return "Connect"
    }

    private var thumbURL: URL? {
        if parentBoard != nil { return nil }
        if let remoteItem {
            guard let string = remoteItem.gridImageURL else { return nil }
            return URL(string: string)
        }
        guard let block else { return nil }
        if let path = block.thumbRelativePath {
            return MediaLibrary.absoluteURL(relativePath: path)
        }
        if let path = block.localRelativePath {
            return MediaLibrary.absoluteURL(relativePath: path)
        }
        if let string = block.remoteThumbnailURL ?? block.remoteMediaURL {
            return URL(string: string)
        }
        return nil
    }

    private var fallbackSymbol: String {
        if nestedBoard != nil || parentBoard != nil { return "square.grid.2x2" }
        if let remoteItem {
            switch remoteItem.kind {
            case .channel: return "square.grid.2x2"
            case .text: return "text.alignleft"
            case .link: return "link"
            default: return remoteItem.isVideo ? "play.rectangle" : "photo"
            }
        }
        switch block?.kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .video: return "play.rectangle"
        case .audio: return "waveform"
        case .arenaChannel: return "square.grid.2x2"
        default: return "photo"
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: Space.s2) {
            TextField("Type to search…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.t3))
                .foregroundStyle(ColosseumTheme.primaryText)
                .focusEffectDisabled()
                .focused($searchFocused)
                .disabled(isSaving)
                .onSubmit { activateSelection() }

            if search.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: TypeScale.t2))
                    .foregroundStyle(ColosseumTheme.tertiaryText)
            } else {
                Button {
                    search = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TypeScale.t1))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                        .frame(width: Space.s4, height: Space.s4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, Space.s3)
        .frame(height: Space.s7)
        .background(ColosseumTheme.surface, in: ChromeMetrics.controlShape)
        .overlay(
            ChromeMetrics.controlShape.stroke(
                searchFocused ? ColosseumTheme.focus : ColosseumTheme.border,
                lineWidth: 1
            )
        )
        .padding(.horizontal, Space.s4)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: TypeScale.t1))
                    .foregroundStyle(ColosseumTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s4)
                    .padding(.top, Space.s3)
            }

            if !isSearching {
                VStack(spacing: 0) {
                    Text("Recent boards")
                        .font(.system(size: TypeScale.t2, weight: .bold))
                        .foregroundStyle(ColosseumTheme.primaryText)
                        .padding(.bottom, Space.s2)
                    Rectangle()
                        .fill(ColosseumTheme.border)
                        .frame(height: 1)
                }
                .padding(.horizontal, Space.s4)
                .padding(.top, Space.s4)
                .padding(.bottom, Space.s3)
            } else {
                Spacer().frame(height: 16)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.s2) {
                        if canCreate {
                            createRow
                                .id(Option.create(query))
                        }

                        ForEach(filtered, id: \.id) { board in
                            boardRow(board)
                                .id(Option.board(board.id))
                        }

                        if filtered.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s4)
                }
                .onChange(of: selection) { _, option in
                    guard let option else { return }
                    proxy.scrollTo(option, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var createRow: some View {
        Button {
            selection = .create(query)
            Task { await createAndConnect(title: query) }
        } label: {
            HStack(spacing: Space.s2) {
                Image(systemName: "plus")
                    .font(.system(size: TypeScale.t2, weight: .bold))
                Text("Create new board “\(query)”")
                    .font(.system(size: TypeScale.t2, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ColosseumTheme.primaryText)
            .padding(.horizontal, Space.s3)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ColosseumTheme.surface)
            .overlay(
                Rectangle().stroke(
                    selection == .create(query) ? ColosseumTheme.primaryText : Color.clear,
                    lineWidth: 1
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .pointingHandCursor()
    }

    private func boardRow(_ board: Board) -> some View {
        let connected = isConnected(to: board)
        let selected = selection == .board(board.id)
        return Button {
            selection = .board(board.id)
            Task { await toggle(board) }
        } label: {
            HStack(spacing: Space.s2) {
                Text(board.title.isEmpty ? "Untitled" : board.title)
                    .font(.system(size: TypeScale.t2))
                    .foregroundStyle(
                        connected ? ColosseumTheme.secondaryText : ColosseumTheme.primaryText
                    )
                    .lineLimit(1)

                Text("\(board.contentCount)")
                    .font(.system(size: TypeScale.t2))
                    .foregroundStyle(ColosseumTheme.tertiaryText)

                Spacer(minLength: Space.s2)

                if connected {
                    Image(systemName: "checkmark")
                        .font(.system(size: TypeScale.t1, weight: .bold))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                }
            }
            .padding(.horizontal, Space.s3)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ColosseumTheme.elevated : ColosseumTheme.surface)
            .overlay(
                Rectangle().stroke(
                    selected ? ColosseumTheme.primaryText : Color.clear,
                    lineWidth: 1
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .pointingHandCursor()
    }

    private var emptyState: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "info.circle")
                .font(.system(size: TypeScale.t2))
                .foregroundStyle(ColosseumTheme.secondaryText)
            Text(isSearching ? "No results for “\(query)”" : "No boards yet")
                .font(.system(size: TypeScale.t2))
                .foregroundStyle(ColosseumTheme.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.s3)
        .frame(height: 52)
        .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, canCreate ? 4 : 0)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        // The search field owns typing; this monitor only steals ↑ ↓ ↩ esc.
        keyMonitor.capturesNavigationWhileEditing = true
        keyMonitor.onUp = { moveSelection(-1) }
        keyMonitor.onDown = { moveSelection(1) }
        keyMonitor.onEnter = { activateSelection() }
        keyMonitor.onTab = {
            searchFocused = true
            return true
        }
        keyMonitor.onEscape = { dismiss() }
        keyMonitor.shouldIgnoreNavigation = { isSaving }
        keyMonitor.install()
    }

    private func moveSelection(_ delta: Int) {
        let list = options
        guard !list.isEmpty, !isSaving else { return }
        let current = list.firstIndex(where: { $0 == selection })
        let next: Int
        if let current {
            next = max(0, min(list.count - 1, current + delta))
        } else {
            next = delta > 0 ? 0 : list.count - 1
        }
        selection = list[next]
    }

    private func activateSelection() {
        guard !isSaving else { return }
        switch selection {
        case .create(let title):
            guard canCreate else { return }
            Task { await createAndConnect(title: title) }
        case .board(let id):
            guard let board = filtered.first(where: { $0.id == id }) else { return }
            Task { await toggle(board) }
        case .none:
            break
        }
    }

    /// Prefer a real board so ↩ connects instead of creating a near-duplicate.
    private func defaultSelection() -> Option? {
        if let first = filtered.first { return .board(first.id) }
        return canCreate ? .create(query) : nil
    }

    private func revalidateSelection() {
        if let selection, options.contains(selection) { return }
        selection = defaultSelection()
    }

    private func dismiss() {
        guard !isSaving else { return }
        onDismiss()
    }

    // MARK: - Persistence

    private func isConnected(to board: Board) -> Bool {
        matchingConnection(in: board) != nil
    }

    @MainActor
    private func createAndConnect(title: String) async {
        guard !isSaving else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let board = Board(title: trimmed.isEmpty ? "Untitled" : trimmed)
        context.insert(board)
        do {
            try await connectTarget(to: board)
            try context.save()
            isSaving = false
            search = ""
            selection = .board(board.id)
            searchFocused = true
        } catch {
            context.delete(board)
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    @MainActor
    private func toggle(_ board: Board) async {
        errorMessage = nil
        isSaving = true
        do {
            if let connection = matchingConnection(in: board) {
                ImportService.removeConnection(
                    connection,
                    deleteOrphanedBlock: block == nil,
                    context: context
                )
            } else {
                try await connectTarget(to: board)
            }
            try context.save()
            isSaving = false
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    @MainActor
    private func connectTarget(to board: Board) async throws {
        isSaving = true
        if let parentBoard {
            ImportService.connect(nestedBoard: board, to: parentBoard, context: context)
        } else if let remoteItem {
            try await ArenaImportService.saveItem(remoteItem, into: board, context: context)
        } else if let block {
            ImportService.connect(block: block, to: board, context: context)
        } else if let nestedBoard {
            ImportService.connect(nestedBoard: nestedBoard, to: board, context: context)
        }
    }

    private func matchingConnection(in board: Board) -> Connection? {
        if let parentBoard {
            return parentBoard.connections.first { $0.nestedBoard?.id == board.id }
        }
        if let block {
            return board.connections.first { $0.block?.id == block.id }
        }
        if let nestedBoard {
            return board.connections.first { $0.nestedBoard?.id == nestedBoard.id }
        }
        guard let remoteItem else { return nil }
        return board.connections.first { connection in
            guard let existing = connection.block else { return false }
            if remoteItem.kind == .channel {
                return existing.kind == .arenaChannel
                    && existing.arenaSlug == remoteItem.channelSlug
            }
            if existing.arenaBlockID == remoteItem.id { return true }
            let remoteURLs = [
                remoteItem.sourceURL,
                remoteItem.imageURL,
                remoteItem.attachmentURL
            ].compactMap { $0 }
            return existing.sourceURL.map(remoteURLs.contains) == true
        }
    }
}

// MARK: - Target thumbnail

private struct ConnectTargetThumb: View {
    let url: URL?
    let fallbackSymbol: String
    var accent = false

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(ColosseumTheme.surface)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: TypeScale.t4))
                    .foregroundStyle(
                        accent ? ColosseumTheme.remoteBoardTitle : ColosseumTheme.tertiaryText
                    )
            }
        }
        .frame(width: 56, height: 56)
        .clipped()
        .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await ImageThumbCache.image(for: url, maxPixelSize: 160)
        }
    }
}

// MARK: - Presentation

/// In-window modal overlay: dimmed scrim, click-outside to dismiss.
///
/// Replaces `.sheet` so the panel can be dismissed by clicking away and so the
/// overlay's key monitor sits above the host's in the same window.
private struct ModalOverlayModifier<Overlay: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder var overlay: () -> Overlay

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if isPresented {
                    ColosseumTheme.scrim
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { isPresented = false }
                        .transition(.opacity)

                    overlay()
                        .transition(ColosseumMotion.overlayTransition)
                        .onAppear { OverlayPresentation.shared.push() }
                        .onDisappear { OverlayPresentation.shared.pop() }
                }
            }
            .animation(ColosseumMotion.overlay, value: isPresented)
        }
    }
}

extension View {
    func modalOverlay<Overlay: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) -> some View {
        modifier(ModalOverlayModifier(isPresented: isPresented, overlay: overlay))
    }
}
