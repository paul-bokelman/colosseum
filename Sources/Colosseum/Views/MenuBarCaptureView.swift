import AppKit
import SwiftData
import SwiftUI

struct MenuBarCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Board.updatedAt, order: .reverse) private var boards: [Board]

    @State private var phase: Phase = .idle
    @State private var inputText = ""
    @State private var notes = ""
    @State private var draft: CaptureDraft?
    @State private var selectedBoardIndex = 0
    @State private var selectedBoardID: UUID?
    @State private var successBoardTitle = ""
    @State private var errorMessage: String?
    @State private var keyMonitor = KeyNavMonitor()
    @State private var pasteMonitor: Any?
    @State private var panelWindow: NSWindow?
    @State private var focusRequest = 0
    @State private var isTargeted = false

    @FocusState private var focus: FocusTarget?

    private enum FocusTarget: Hashable {
        case input
        case notes
    }

    private enum Phase: Equatable {
        case idle
        case resolving
        case selectBoard
        case notes
        case committing
        case success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsPreview {
                previewHeader
                    .padding(Space.s3)
                Divider()
            }

            switch phase {
            case .idle, .resolving:
                idleBody
            case .selectBoard:
                boardSelectBody
            case .notes, .committing:
                notesBody
            case .success:
                successBody
            }
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            if isTargeted {
                Rectangle()
                    .stroke(ColosseumTheme.primaryText, lineWidth: 1)
                    .padding(Space.s1)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: DropIngest.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task { await resolveFromDrop(providers) }
            return true
        }
        .onAppear {
            panelWindow = NSApp.keyWindow
            installKeys()
            installPasteMonitor()
            focusInput()
        }
        .onDisappear {
            keyMonitor.remove()
            removePasteMonitor()
            resetToIdle(clearError: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .colosseumRevealMainWindow)) { _ in
            openMainWindow()
        }
    }

    private var showsPreview: Bool {
        switch phase {
        case .selectBoard, .notes, .committing:
            return draft != nil
        default:
            return false
        }
    }

    // MARK: - Phase bodies

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            ZStack {
                ArenaInputField(
                    text: $inputText,
                    fontSize: TypeScale.t2,
                    focusRequest: focusRequest,
                    onSubmit: { Task { await resolveFromInput() } },
                    onPasteMedia: { false }
                )
                .frame(height: 66)
                .opacity(phase == .resolving ? 0.35 : 1)
                .disabled(phase == .resolving)

                if inputText.isEmpty && phase != .resolving {
                    Text(placeholder)
                        .font(.system(size: TypeScale.t2))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                        .tint(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Space.s2)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "colosseum" else { return .systemAction }
                            openFiles()
                            return .handled
                        })
                        .onTapGesture { focusRequest += 1 }
                }

                if phase == .resolving {
                    ProgressView().controlSize(.small)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.alert)
            } else {
                Text(phase == .resolving ? "Resolving…" : "⌘↩ to continue")
                    .font(.system(size: TypeScale.t0, design: .monospaced))
                    .foregroundStyle(ColosseumTheme.tertiaryText)
            }

            Divider()
                .padding(.top, Space.nudge)

            menuButton("Open") {
                dismissPanel()
                openMainWindow()
            }

            menuButton("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(Space.s2)
    }

    private var boardSelectBody: some View {
        Group {
            if boards.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("No boards yet")
                        .font(.system(size: TypeScale.t0))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                    menuButton("Open") {
                        dismissPanel()
                        openMainWindow()
                    }
                }
                .padding(Space.s3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(boards.enumerated()), id: \.element.id) { index, board in
                        boardRow(board, index: index)
                    }
                }
            }
        }
    }

    private var notesBody: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if let board = selectedBoard {
                Text(board.title)
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.secondaryText)
            }

            TextField("Notes (optional)", text: $notes)
                .colosseumField(focused: focus == .notes)
                .focused($focus, equals: .notes)
                .onSubmit { Task { await commitSelected() } }
                .disabled(phase == .committing)

            if phase == .committing {
                Text("Adding…")
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.secondaryText)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.alert)
            } else {
                Text("⌘↩ to add")
                    .font(.system(size: TypeScale.t0, design: .monospaced))
                    .foregroundStyle(ColosseumTheme.tertiaryText)
            }
        }
        .padding(Space.s3)
    }

    private var successBody: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "checkmark")
                .font(.system(size: TypeScale.t2))
            Text("Added to \(successBoardTitle)")
                .font(.system(size: TypeScale.t2))
                .foregroundStyle(ColosseumTheme.secondaryText)
                .lineLimit(2)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Subviews

    private var selectedBoard: Board? {
        if let selectedBoardID {
            return boards.first(where: { $0.id == selectedBoardID })
        }
        guard boards.indices.contains(selectedBoardIndex) else { return nil }
        return boards[selectedBoardIndex]
    }

    @ViewBuilder
    private var previewHeader: some View {
        if let draft {
            HStack(alignment: .top, spacing: Space.s2) {
                previewThumbnail(for: draft)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(draft.kindLabel.uppercased())
                        .font(.system(size: TypeScale.t0, design: .monospaced))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                    Text(draft.displayTitle)
                        .font(.system(size: TypeScale.t2))
                        .lineLimit(3)
                    if case .arenaChannel(let preview) = draft {
                        Text("\(preview.blockCount) blocks · \(preview.ownerName)")
                            .font(.system(size: TypeScale.t0))
                            .foregroundStyle(ColosseumTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func previewThumbnail(for draft: CaptureDraft) -> some View {
        if let image = draft.previewImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: symbolName(for: draft.kind))
                    .font(.system(size: TypeScale.t4))
                    .foregroundStyle(ColosseumTheme.secondaryText)
            }
        }
    }

    private func boardRow(_ board: Board, index: Int) -> some View {
        let selected = index == selectedBoardIndex
        return Button {
            selectedBoardIndex = index
            advanceToNotes()
        } label: {
            HStack(spacing: Space.s2) {
                VStack(alignment: .leading, spacing: Space.nudge) {
                    Text(board.title)
                        .font(.system(size: TypeScale.t2, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text("\(board.contentCount) blocks")
                        .font(.system(size: TypeScale.t0))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(selected ? ColosseumTheme.linkText : Color.clear)
            .foregroundStyle(selected ? ColosseumTheme.canvas : ColosseumTheme.primaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .pointingHandCursor()
        .padding(.vertical, Space.s1)
    }

    private func symbolName(for kind: BlockKind) -> String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .link: return "link"
        case .text: return "text.alignleft"
        case .arenaChannel: return "square.grid.2x2"
        }
    }

    // MARK: - Window

    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: {
                $0.canBecomeMain && $0.styleMask.contains(.closable)
            }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Keys & paste

    private var placeholder: AttributedString {
        var result = AttributedString("Drop or ")
        var choose = AttributedString("choose")
        choose.link = URL(string: "colosseum://choose")
        choose.underlineStyle = Text.LineStyle(pattern: .solid)
        result += choose
        result += AttributedString(" files, paste a URL or type text")
        return result
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .image, .movie, .audio, .mpeg4Movie, .quickTimeMovie,
            .mp3, .mpeg4Audio, .wav, .aiff,
            .png, .jpeg, .gif, .webP, .heic
        ]
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        present(draft: .localFile(url))
    }

    /// Drops reuse the resolve → pick board → notes flow.
    private func resolveFromDrop(_ providers: [NSItemProvider]) async {
        guard phase == .idle || phase == .resolving else { return }
        let payload = await DropIngest.payload(from: providers)

        if let url = payload.fileURLs.first {
            present(draft: .localFile(url))
            return
        }
        if let data = payload.imageData.first {
            present(draft: .pastedImage(data))
            return
        }
        guard let string = payload.strings.first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty
        else { return }

        guard ImportService.looksLikeURL(string) else {
            present(draft: .text(string))
            return
        }

        phase = .resolving
        errorMessage = nil
        do {
            present(draft: try await ImportService.resolveURLString(string))
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription
            focusInput()
        }
    }

    private func focusInput() {
        DispatchQueue.main.async {
            focus = .input
            focusRequest += 1
        }
    }

    private func focusNotes() {
        DispatchQueue.main.async {
            focus = .notes
        }
    }

    private func installKeys() {
        keyMonitor.onUp = {
            guard phase == .selectBoard, !boards.isEmpty else { return }
            selectedBoardIndex = max(0, selectedBoardIndex - 1)
        }
        keyMonitor.onDown = {
            guard phase == .selectBoard, !boards.isEmpty else { return }
            selectedBoardIndex = min(boards.count - 1, selectedBoardIndex + 1)
        }
        keyMonitor.onEnter = {
            switch phase {
            // .idle is owned by ArenaInputField: ↩ newlines, ⌘↩ submits.
            case .selectBoard:
                advanceToNotes()
            case .notes:
                Task { await commitSelected() }
            default:
                break
            }
        }
        keyMonitor.onTab = { false }
        keyMonitor.onEscape = {
            handleEscape()
        }
        keyMonitor.shouldIgnoreNavigation = {
            switch phase {
            case .idle, .selectBoard, .notes: return false
            default: return true
            }
        }
        keyMonitor.install()
    }

    private func handleEscape() {
        switch phase {
        case .selectBoard, .notes, .committing:
            resetToIdle(clearError: true)
            focusInput()
        default:
            dismissPanel()
        }
    }

    private func dismissPanel() {
        resetToIdle(clearError: true)
        let window = panelWindow ?? NSApp.keyWindow
        DispatchQueue.main.async {
            window?.orderOut(nil)
        }
    }

    /// Intercept ⌘-shortcuts while the panel is open so the app's menu items
    /// ("Paste into board", "New board or add") don't steal them. Menu key
    /// equivalents are processed before the responder chain, so without this
    /// the capture field never sees ⌘↩ at all.
    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == .command else { return event }

            if event.keyCode == 36 || event.keyCode == 76 { // return / keypad enter
                advanceFromCommandReturn()
                return nil
            }

            guard event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }

            switch phase {
            case .idle, .resolving:
                Task { await handleIdlePaste() }
                return nil
            case .notes:
                if let string = NSPasteboard.general.string(forType: .string) {
                    notes = string
                }
                return nil
            case .selectBoard, .committing, .success:
                return nil
            }
        }
    }

    /// ⌘↩ drives the capture flow forward one step.
    private func advanceFromCommandReturn() {
        DispatchQueue.main.async {
            switch phase {
            case .idle:
                Task { await resolveFromInput() }
            case .selectBoard:
                advanceToNotes()
            case .notes:
                Task { await commitSelected() }
            case .resolving, .committing, .success:
                break
            }
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
            self.pasteMonitor = nil
        }
    }

    /// Prefer URL/text into the field; auto-resolve true media pastes (images/files).
    private func pasteboardHasNonTextMedia() -> Bool {
        let pb = NSPasteboard.general

        if let string = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           string.hasPrefix("http://") || string.hasPrefix("https://") {
            return false
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           urls.contains(where: { !$0.isFileURL }) {
            return false
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           urls.contains(where: \.isFileURL) {
            return true
        }
        if pb.availableType(from: [.png, .tiff, .init("com.compuserve.gif")]) != nil {
            return true
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            return true
        }
        return false
    }

    private func handleIdlePaste() async {
        if pasteboardHasNonTextMedia() {
            await resolveFromPasteboard()
            return
        }

        let pb = NSPasteboard.general
        if let string = pb.string(forType: .string) {
            inputText = string
            focus = .input
            return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { !$0.isFileURL }) {
            inputText = url.absoluteString
            focus = .input
            return
        }

        await resolveFromPasteboard()
    }

    // MARK: - Capture

    private func resolveFromInput() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await resolveFromPasteboard()
            return
        }
        phase = .resolving
        errorMessage = nil
        do {
            // Plain text becomes a note; only URLs are fetched.
            let resolved = try await ImportService.resolveInput(trimmed)
            present(draft: resolved)
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription
            focusInput()
        }
    }

    private func resolveFromPasteboard() async {
        phase = .resolving
        errorMessage = nil
        do {
            let resolved = try await ImportService.resolvePasteboard()
            switch resolved {
            case .remote, .arenaChannel:
                break
            default:
                inputText = ""
            }
            present(draft: resolved)
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription
            focusInput()
        }
    }

    private func present(draft: CaptureDraft) {
        self.draft = draft
        notes = ""
        selectedBoardIndex = 0
        selectedBoardID = nil
        errorMessage = nil
        phase = .selectBoard
        focus = nil
        // Resign the text field so arrow/enter are handled by KeyNavMonitor.
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func advanceToNotes() {
        guard phase == .selectBoard,
              boards.indices.contains(selectedBoardIndex)
        else { return }
        selectedBoardID = boards[selectedBoardIndex].id
        notes = ""
        errorMessage = nil
        phase = .notes
        focusNotes()
    }

    private func commitSelected() async {
        guard phase == .notes,
              let draft,
              let board = selectedBoard
        else { return }

        phase = .committing
        errorMessage = nil
        do {
            try await ImportService.commit(draft, notes: notes, into: board, context: context)
            try context.save()
            successBoardTitle = board.title
            phase = .success
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismissPanel()
        } catch {
            phase = .notes
            errorMessage = error.localizedDescription
            focusNotes()
        }
    }

    private func resetToIdle(clearError: Bool) {
        phase = .idle
        draft = nil
        notes = ""
        inputText = ""
        selectedBoardIndex = 0
        selectedBoardID = nil
        successBoardTitle = ""
        if clearError { errorMessage = nil }
    }
}
