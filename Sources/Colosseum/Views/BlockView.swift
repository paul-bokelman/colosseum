import AppKit
import AVFoundation
import SwiftData
import SwiftUI

struct BlockView: View {
    let board: Board
    let connections: [Connection]
    @Binding var selectedID: UUID?
    var onClose: () -> Void
    var onTagTap: (String) -> Void = { _ in }
    var onOpenBoard: (Board) -> Void = { _ in }
    var onOpenRemoteBoard: (ArenaBrowseTarget) -> Void = { _ in }

    @Environment(\.modelContext) private var context

    @State private var showConnect = false
    @State private var showMeta = false
    @State private var loopingPlayer: LoopingVideoPlayer?
    @State private var keyMonitor = KeyNavMonitor()
    @State private var notesFocusNonce = 0
    /// Index into `boardConnections`; `nil` until ↑/↓ is used.
    @State private var connectionFocusIndex: Int?
    @State private var remoteConnections: [ArenaRemoteConnection] = []
    @State private var isLoadingRemoteConnections = false
    @State private var remoteConnectionsError: String?
    @FocusState private var focused: Bool

    private var index: Int {
        guard let selectedID else { return 0 }
        return connections.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    private var connection: Connection? {
        guard !connections.isEmpty, index >= 0, index < connections.count else { return nil }
        return connections[index]
    }

    private var block: Block? { connection?.block }

    private var boardConnections: [(connection: Connection, board: Board)] {
        guard let block else { return [] }
        return block.connections
            .sorted(by: { $0.createdAt > $1.createdAt })
            .compactMap { conn in
                guard let parent = conn.board else { return nil }
                return (conn, parent)
            }
    }

    private var connectionCount: Int {
        boardConnections.count + remoteConnections.count
    }

    private var focusedConnectionScrollID: String? {
        guard let connectionFocusIndex else { return nil }
        let local = boardConnections
        if local.indices.contains(connectionFocusIndex) {
            return "local-\(local[connectionFocusIndex].connection.id.uuidString)"
        }
        let remoteIndex = connectionFocusIndex - local.count
        guard remoteConnections.indices.contains(remoteIndex) else { return nil }
        return "remote-\(remoteConnections[remoteIndex].id)"
    }

    var body: some View {
        HStack(spacing: 0) {
            mediaPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }

            Divider().overlay(ColosseumTheme.border)

            sidebar
                .frame(width: ColosseumTheme.sidebarWidth)
        }
        .background(ColosseumTheme.canvas)
        .overlay(alignment: .bottomLeading) {
            if let block {
                metaButton(for: block)
                    .padding(Space.s3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            shortcutHints
                .padding(Space.s3)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            focused = true
            reloadPlayer()
            installKeyMonitor()
            Task { await loadRemoteConnections() }
        }
        .onDisappear {
            keyMonitor.remove()
            loopingPlayer?.stop()
            loopingPlayer = nil
        }
        .onChange(of: selectedID) { _, _ in
            focused = true
            showMeta = false
            connectionFocusIndex = nil
            reloadPlayer()
            Task { await loadRemoteConnections() }
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
        .onKeyPress(.leftArrow) {
            guard !showConnect, !KeyNavMonitor.isEditingText else { return .ignored }
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !showConnect, !KeyNavMonitor.isEditingText else { return .ignored }
            step(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !showConnect, !KeyNavMonitor.isEditingText else { return .ignored }
            moveConnectionFocus(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !showConnect, !KeyNavMonitor.isEditingText else { return .ignored }
            moveConnectionFocus(1)
            return .handled
        }
        .onKeyPress(.return) {
            guard !showConnect, !KeyNavMonitor.isEditingText else { return .ignored }
            activateFocusedBoardConnection()
            return .handled
        }
        .onKeyPress(.tab) {
            guard !showConnect, !KeyNavMonitor.isEditingText else { return .ignored }
            notesFocusNonce += 1
            focused = false
            return .handled
        }
        .onMoveCommand { direction in
            guard !showConnect, !KeyNavMonitor.isEditingText else { return }
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            case .up: moveConnectionFocus(-1)
            case .down: moveConnectionFocus(1)
            default: break
            }
        }
        .background {
            // Escape only — arrow shortcuts must not steal caret movement from notes.
            Button("", action: handleEscape)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .modalOverlay(isPresented: $showConnect) {
            if let block {
                ConnectOverlay(
                    block: block,
                    nestedBoard: nil,
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
        keyMonitor.onEnter = { activateFocusedBoardConnection() }
        keyMonitor.onTab = {
            guard !KeyNavMonitor.isEditingText else { return false }
            notesFocusNonce += 1
            focused = false
            return true
        }
        keyMonitor.onEscape = { handleEscape() }
        keyMonitor.onCopy = {
            guard let block else { return false }
            return BlockClipboard.copy(block)
        }
        keyMonitor.onCharacter = { char in
            guard char == "c", block != nil else { return false }
            DispatchQueue.main.async { showConnect = true }
            return true
        }
        keyMonitor.shouldIgnoreNavigation = { showConnect }
        keyMonitor.install()
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
        // Notes focused: first Esc blurs the field; second closes preview.
        if KeyNavMonitor.isEditingText {
            NSApp.keyWindow?.makeFirstResponder(nil)
            focused = true
            return
        }
        onClose()
    }

    @ViewBuilder
    private var mediaPane: some View {
        ZStack {
            ColosseumTheme.canvas
            if let block {
                mediaContent(for: block)
                    .id(block.id)
                    .transition(ColosseumMotion.fade)
            }
        }
        .animation(ColosseumMotion.standard, value: selectedID)
    }

    @ViewBuilder
    private func mediaContent(for block: Block) -> some View {
        switch block.kind {
        case .image:
            if let path = block.localRelativePath {
                let url = MediaLibrary.absoluteURL(relativePath: path)
                if block.isAnimatedImage || AnimatedImage.isAnimated(at: url) {
                    AnimatedImageView(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(Space.s5)
                } else if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(Space.s5)
                }
            } else if let urlString = block.remoteMediaURL ?? block.remoteThumbnailURL,
                      let url = URL(string: urlString) {
                if block.isAnimatedImage {
                    RemoteAnimatedImageView(
                        url: url,
                        placeholderURL: block.remoteThumbnailURL.flatMap(URL.init(string:)),
                        contentPadding: 24
                    )
                } else {
                    ShimmerRemoteImage(url: url, square: false, contentPadding: 24, fullResolution: true) {
                        remoteMediaPlaceholder("Couldn’t load image")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .video:
            if let loopingPlayer {
                PlayerView(player: loopingPlayer.player)
                    .padding(Space.s5)
            }
        case .audio:
            VStack(spacing: Space.s4) {
                Image(systemName: "waveform")
                    .font(.system(size: TypeScale.t8))
                    .foregroundStyle(ColosseumTheme.secondaryText)
                Text(block.displayTitle)
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
        case .text:
            ScrollView {
                Text(block.textBody)
                    .font(.system(size: TypeScale.t4))
                    .foregroundStyle(ColosseumTheme.primaryText)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(Space.s7)
            }
        case .link:
            VStack(spacing: Space.s3) {
                Image(systemName: "link")
                    .font(.system(size: TypeScale.t7))
                    .foregroundStyle(ColosseumTheme.secondaryText)
                Text(block.displayTitle)
                    .font(.system(size: TypeScale.t4))
                    .foregroundStyle(ColosseumTheme.primaryText)
                    .multilineTextAlignment(.center)
                if let source = block.sourceURL, let url = URL(string: source) {
                    Button("Open link") { NSWorkspace.shared.open(url) }
                        .buttonStyle(ChromeButtonStyle(emphasized: true))
                        .pointingHandCursor()
                }
            }
            .padding(Space.s7)
        case .arenaChannel:
            VStack(spacing: Space.s2) {
                Text(block.title)
                    .font(.system(size: TypeScale.t5))
                    .foregroundStyle(ColosseumTheme.remoteBoardTitle)
                if let owner = block.arenaOwnerName {
                    Text("by \(owner)")
                        .foregroundStyle(ColosseumTheme.secondaryText)
                }
                Text("\(block.arenaBlockCount) blocks")
                    .foregroundStyle(ColosseumTheme.secondaryText)
                if let urlString = block.arenaURL ?? block.sourceURL,
                   let url = URL(string: urlString) {
                    Button("Open on Are.na") { NSWorkspace.shared.open(url) }
                        .buttonStyle(ChromeButtonStyle(emphasized: true))
                        .pointingHandCursor()
                        .padding(.top, Space.s2)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let block {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s3) {
                        notesSection(for: block)

                        if block.kind == .text {
                            TextEditor(text: Binding(
                                get: { block.textBody },
                                set: { block.textBody = $0 }
                            ))
                            .font(.system(size: TypeScale.t2))
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .padding(Space.s2)
                            .background(ColosseumTheme.surface)
                            .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
                        }

                        actionRow(for: block)

                            Text("Connections \(connectionCount)")
                            .font(.system(size: TypeScale.t1))
                            .foregroundStyle(ColosseumTheme.secondaryText)
                            .padding(.top, Space.s2)

                            connectionsList()
                        }
                        .padding(Space.s3)
                        .padding(.bottom, Space.s5)
                    }
                    .onChange(of: focusedConnectionScrollID) { _, id in
                        guard let id else { return }
                        withAnimation(ColosseumMotion.soft) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .background(ColosseumTheme.canvas)
    }

    @ViewBuilder
    private func actionRow(for block: Block) -> some View {
        // The icon cluster grows with the block's capabilities. Rather than let a
        // full row squeeze the Connect label, drop the icons onto their own line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s2) {
                connectButton
                actionIcons(for: block)
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                connectButton
                HStack(spacing: Space.s2) { actionIcons(for: block) }
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
    private func actionIcons(for block: Block) -> some View {
            if let path = block.localRelativePath {
                let url = MediaLibrary.absoluteURL(relativePath: path)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Reveal in Finder")
                .pointingHandCursor()

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Open File")
                .pointingHandCursor()
            }

            if let source = block.sourceURL, let url = URL(string: source) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Open source URL")
                .pointingHandCursor()
            }

            if block.kind == .arenaChannel,
               let urlString = block.arenaURL ?? block.sourceURL,
               let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Open on Are.na")
                .pointingHandCursor()
            }

            if block.kind != .arenaChannel,
               let urlString = block.arenaURL,
               let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(ChromeIconButtonStyle())
                .help("Open on Are.na")
                .pointingHandCursor()
            }

            Button {
                if let connection {
                    ImportService.removeConnection(
                        connection,
                        deleteOrphanedBlock: true,
                        context: context
                    )
                    try? context.save()
                    onClose()
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(ChromeIconButtonStyle())
            .help("Remove from board")
            .pointingHandCursor()
    }

    @ViewBuilder
    private func notesSection(for block: Block) -> some View {
        let suggestions = TagParser.boardTagSuggestions(from: board.sortedConnections)
        NotesEditor(
            text: Binding(
                get: { block.notes },
                set: { block.notes = $0 }
            ),
            placeholder: "notes…",
            suggestionTags: suggestions.tags,
            suggestionCounts: suggestions.counts,
            onTagTap: onTagTap,
            focusNonce: notesFocusNonce,
            onCommit: { board.updatedAt = .now }
        )
        .frame(minHeight: 72, maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shortcutHints: some View {
        HStack(spacing: Space.s2) {
            ShortcutHint(text: "←")
            ShortcutHint(text: "→")
            ShortcutHint(text: "↑↓")
            ShortcutHint(text: "↩")
            ShortcutHint(text: "⌘C")
            ShortcutHint(text: "c")
            ShortcutHint(text: "tab")
            ShortcutHint(text: "esc")
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func metaButton(for block: Block) -> some View {
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
                metaOverlay(for: block)
                    .fixedSize()
                    // Sits on top of the bar, left edge flush with the button.
                    .offset(y: -(ChromeMetrics.controlHeight + Space.s2))
                    .transition(ColosseumMotion.fade)
            }
        }
    }

    @ViewBuilder
    private func metaOverlay(for block: Block) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            TextField("Title", text: Binding(
                get: { block.title },
                set: {
                    block.title = $0
                    board.updatedAt = .now
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: TypeScale.t2))
            .foregroundStyle(ColosseumTheme.primaryText)

            metaTable(for: block)
        }
        .padding(Space.s3)
        .frame(width: 260, alignment: .leading)
        .background(ColosseumTheme.elevated)
        .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
        .floatingPanelShadow()
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func metaTable(for block: Block) -> some View {
        VStack(spacing: 0) {
            metaRow("Added", ColosseumFormatters.relativeDate(block.createdAt))
            metaRow("Content type", block.contentTypeLabel)
            if block.byteSize > 0 {
                metaRow("File size", ColosseumFormatters.byteCount(block.byteSize))
            }
            if block.width > 0, block.height > 0 {
                metaRow("Dimensions", "\(block.width) × \(block.height)")
            }
            if (block.kind == .video || block.kind == .audio), block.duration > 0 {
                metaRow("Duration", ColosseumFormatters.duration(block.duration))
            }
            if block.kind == .arenaChannel {
                metaRow("Blocks", "\(block.arenaBlockCount)")
                if let owner = block.arenaOwnerName {
                    metaRow("By", owner)
                }
            }
            if let typeName = block.arenaTypeName {
                metaRow("Are.na Type", typeName)
            }
            if let source = block.sourceURL, !source.isEmpty {
                metaRow("Source", source)
            }
        }
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
            Rectangle()
                .fill(ColosseumTheme.border)
                .frame(height: 0.5)
        }
    }

    private func connectionsList() -> some View {
        let localItems = boardConnections
        return VStack(alignment: .leading, spacing: Space.s1) {
            ForEach(Array(localItems.enumerated()), id: \.element.connection.id) { index, item in
                let isFocused = connectionFocusIndex == index
                Button {
                    connectionFocusIndex = index
                    onOpenBoard(item.board)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.nudge) {
                            Text(item.board.title.isEmpty ? "Untitled" : item.board.title)
                                .foregroundStyle(
                                    isFocused ? ColosseumTheme.primaryText : ColosseumTheme.secondaryText
                                )
                                .fontWeight(isFocused ? .medium : .regular)
                            Text("\(item.board.contentCount) · \(ColosseumFormatters.relativeDate(item.connection.createdAt))")
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
                .id("local-\(item.connection.id.uuidString)")
                .animation(ColosseumMotion.soft, value: isFocused)
            }

            ForEach(Array(remoteConnections.enumerated()), id: \.element.id) { index, connection in
                let focusIndex = localItems.count + index
                let isFocused = connectionFocusIndex == focusIndex
                Button {
                    connectionFocusIndex = focusIndex
                    browseRemoteConnection(connection)
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
                .id("remote-\(connection.id)")
                .animation(ColosseumMotion.soft, value: isFocused)
            }

            if isLoadingRemoteConnections && remoteConnections.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, Space.s2)
            } else if let remoteConnectionsError, localItems.isEmpty && remoteConnections.isEmpty {
                Text(remoteConnectionsError)
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.tertiaryText)
                    .padding(.top, Space.s2)
            } else if localItems.isEmpty && remoteConnections.isEmpty {
                Text("Not connected to any boards.")
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.tertiaryText)
                    .padding(.top, Space.s2)
            }
        }
        .padding(.top, Space.s1)
    }

    private func moveConnectionFocus(_ delta: Int) {
        guard connectionCount > 0 else { return }
        if let current = connectionFocusIndex {
            connectionFocusIndex = max(0, min(connectionCount - 1, current + delta))
        } else {
            connectionFocusIndex = delta > 0 ? 0 : connectionCount - 1
        }
        focused = true
    }

    private func activateFocusedBoardConnection() {
        guard let connectionFocusIndex else { return }
        let localItems = boardConnections
        if localItems.indices.contains(connectionFocusIndex) {
            onOpenBoard(localItems[connectionFocusIndex].board)
            return
        }
        let remoteIndex = connectionFocusIndex - localItems.count
        guard remoteConnections.indices.contains(remoteIndex) else { return }
        browseRemoteConnection(remoteConnections[remoteIndex])
    }

    private func step(_ delta: Int) {
        guard !connections.isEmpty else { return }
        let next = index + delta
        guard next >= 0, next < connections.count else { return }
        withAnimation(ColosseumMotion.standard) {
            selectedID = connections[next].id
        }
        focused = true
    }

    private func reloadPlayer() {
        loopingPlayer?.stop()
        loopingPlayer = nil
        guard let block, block.kind == .video || block.kind == .audio else { return }
        let url: URL?
        if let path = block.localRelativePath {
            url = MediaLibrary.absoluteURL(relativePath: path)
        } else if let urlString = block.remoteMediaURL {
            url = URL(string: urlString)
        } else {
            url = nil
        }
        guard let url else { return }
        let next = VideoPlayback.looping(url: url, muted: false)
        loopingPlayer = next
        next.play()
    }

    private func browseRemoteConnection(_ connection: ArenaRemoteConnection) {
        onOpenRemoteBoard(ArenaBrowseTarget(
            slug: connection.slug,
            title: connection.title,
            urlString: connection.arenaURLString
        ))
    }

    private func remoteMediaPlaceholder(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(ColosseumTheme.secondaryText)
    }

    @MainActor
    private func loadRemoteConnections() async {
        guard let block, block.arenaBlockID != nil || block.kind == .arenaChannel else {
            remoteConnections = []
            remoteConnectionsError = nil
            return
        }
        let blockID = block.id
        isLoadingRemoteConnections = true
        remoteConnectionsError = nil
        defer { isLoadingRemoteConnections = false }
        do {
            let connections = try await ArenaService.fetchConnections(for: block)
            guard self.block?.id == blockID else { return }
            remoteConnections = connections
        } catch {
            guard self.block?.id == blockID else { return }
            remoteConnections = []
            remoteConnectionsError = error.localizedDescription
        }
    }
}
