import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Board.updatedAt, order: .reverse) private var boards: [Board]

    @State private var path: [UUID] = []
    @State private var showNewBoardSheet = false
    @State private var showImportArena = false
    @State private var arenaBrowseTarget: ArenaBrowseTarget?
    @State private var arenaStack: [ArenaBrowseTarget] = []
    @State private var pendingConnectionID: UUID?
    @State private var returnPreviewConnections: [UUID: UUID] = [:]
    @AppStorage("boardColumnCount") private var columnCount = ChromeMetrics.boardColumnsDefault

    var body: some View {
        ZStack {
            // NavigationStack hosts the window toolbar; path is owned separately for fade transitions.
            NavigationStack {
                ZStack {
                    BoardLibraryView(
                        boards: boards,
                        showsToolbar: path.isEmpty && arenaBrowseTarget == nil,
                        onOpen: { openBoard($0.id) },
                        onOpenFlattened: openFlattenedConnection(source:connection:),
                        onDelete: deleteBoard(_:),
                        onCreate: { showNewBoardSheet = true },
                        onImportArena: { showImportArena = true }
                    )
                    .opacity(path.isEmpty ? 1 : 0)
                    .allowsHitTesting(path.isEmpty && arenaBrowseTarget == nil)

                    if let boardID = path.last {
                        BoardRouteView(
                            boardID: boardID,
                            path: $path,
                            returnPreviewConnections: $returnPreviewConnections,
                            initialConnectionID: pendingConnectionID,
                            onInitialConnectionConsumed: { pendingConnectionID = nil }
                        )
                            .id(boardID)
                            .transition(ColosseumMotion.overlayTransition)
                            .zIndex(1)
                    }
                }
                .animation(ColosseumMotion.overlay, value: path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .colosseumCanvas()
                .toolbarBackground(ColosseumTheme.canvas, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .toolbarColorScheme(.dark, for: .windowToolbar)
                // Stable leading slot — same item on home and board so the mark never shifts.
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        AppHomeButton {
                            guard !path.isEmpty else { return }
                            goHome()
                        }
                        .frame(height: ChromeMetrics.controlHeight)
                    }
                    .colosseumPlainToolbarItem()
                }
            }
            .modifier(WindowContainerBackground())

            if let arenaBrowseTarget {
                ArenaBrowserView(
                    initialTarget: arenaBrowseTarget,
                    stack: $arenaStack,
                    destinationBoard: nil,
                    showsInlineChrome: true,
                    onClose: {
                        withAnimation(ColosseumMotion.overlay) {
                            self.arenaBrowseTarget = nil
                            arenaStack = []
                        }
                    },
                    onImportedBoard: { board in
                        withAnimation(ColosseumMotion.overlay) {
                            self.arenaBrowseTarget = nil
                            arenaStack = []
                        }
                        openBoard(board.id)
                    }
                )
                .transition(ColosseumMotion.overlayTransition)
                .zIndex(30)
            }
        }
        .animation(ColosseumMotion.overlay, value: arenaBrowseTarget?.slug)
        .modalOverlay(isPresented: $showNewBoardSheet) {
            NewBoardSheet(
                onCreate: { title in createBoard(title: title) },
                onDismiss: { showNewBoardSheet = false }
            )
        }
        .modalOverlay(isPresented: $showImportArena) {
            ImportArenaSheet(
                onImported: { board in
                    openBoard(board.id)
                },
                onBrowse: { target in
                    withAnimation(ColosseumMotion.overlay) {
                        arenaStack = [target]
                        arenaBrowseTarget = target
                    }
                },
                onDismiss: { showImportArena = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .colosseumNewBoard)) { _ in
            showNewBoardSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .colosseumCommandReturn)) { _ in
            if path.isEmpty {
                showNewBoardSheet = true
            } else {
                NotificationCenter.default.post(name: .colosseumAdd, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .colosseumImportArena)) { _ in
            showImportArena = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .colosseumGoHome)) { _ in
            goHome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .colosseumColumnsIncrease)) { _ in
            // Home library only — board/remote grids own density via their own handlers.
            guard path.isEmpty, arenaBrowseTarget == nil else { return }
            columnCount = min(columnCount + 1, ChromeMetrics.boardColumnsMax)
        }
        .onReceive(NotificationCenter.default.publisher(for: .colosseumColumnsDecrease)) { _ in
            guard path.isEmpty, arenaBrowseTarget == nil else { return }
            columnCount = max(columnCount - 1, ChromeMetrics.boardColumnsMin)
        }
    }

    private func openBoard(_ id: UUID) {
        pendingConnectionID = nil
        returnPreviewConnections = [:]
        withAnimation(ColosseumMotion.overlay) {
            path = [id]
        }
    }

    private func goHome() {
        pendingConnectionID = nil
        returnPreviewConnections = [:]
        withAnimation(ColosseumMotion.overlay) { path = [] }
    }

    private func openFlattenedConnection(source: Board, connection: Connection) {
        if let nested = connection.nestedBoard {
            pendingConnectionID = nil
            withAnimation(ColosseumMotion.overlay) {
                path = [source.id, nested.id]
            }
            return
        }
        pendingConnectionID = connection.id
        withAnimation(ColosseumMotion.overlay) {
            path = [source.id]
        }
    }

    private func deleteBoard(_ board: Board) {
        returnPreviewConnections.removeValue(forKey: board.id)
        let outgoing = Array(board.connections)
        let incoming = Array(board.nestedIn)
        let orphanedBlocks = Dictionary(
            uniqueKeysWithValues: outgoing.compactMap { connection -> (UUID, Block)? in
                guard let block = connection.block,
                      block.connections.allSatisfy({ $0.board?.id == board.id })
                else { return nil }
                return (block.id, block)
            }
        ).values

        for connection in incoming {
            connection.board?.updatedAt = .now
            context.delete(connection)
        }
        for connection in outgoing {
            context.delete(connection)
        }
        context.delete(board)

        for block in orphanedBlocks {
            if block.localRelativePath != nil {
                MediaLibrary.removeBlockFiles(block.id)
            }
            context.delete(block)
        }
        try? context.save()
    }

    private func createBoard(title: String) {
        let board = Board(title: title)
        context.insert(board)
        try? context.save()
        openBoard(board.id)
    }
}
