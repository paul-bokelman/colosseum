import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The are.na-style add block: the first cell of the grid *is* the input.
///
/// Click (or ⌘↩) to focus, type text, paste or drop files, or paste a URL.
/// ⌘↩ commits; Esc blurs back to the grid.
struct InlineAddBlockView: View {
    @Environment(\.modelContext) private var context

    let board: Board
    /// Bumped by the board when ⌘↩ / "Add to Board…" fires.
    var activateRequest: Int
    var onError: (String) -> Void = { _ in }

    @State private var text = ""
    @State private var isFocused = false
    @State private var isBusy = false
    @State private var isTargeted = false
    @State private var focusRequest = 0
    @State private var pasteMonitor: Any?

    var body: some View {
        GeometryReader { proxy in
            let fontSize = max(11, min(20, proxy.size.width * 0.075))

            ZStack {
                Rectangle()
                    .fill(ColosseumTheme.surface)

                ArenaInputField(
                    text: $text,
                    fontSize: fontSize,
                    focusRequest: focusRequest,
                    onSubmit: { Task { await submit() } },
                    onPasteMedia: handlePasteMedia,
                    onFocusChange: { isFocused = $0 },
                    onEscape: blur
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .opacity(isBusy ? 0.25 : 1)
                .disabled(isBusy)

                if text.isEmpty && !isBusy {
                    placeholder(fontSize: fontSize)
                }

                if isBusy {
                    ProgressView().controlSize(.small)
                }

                hintOverlay
            }
            .contentShape(Rectangle())
            .onTapGesture { focusRequest += 1 }
        }
        .aspectRatio(1, contentMode: .fit)
        .blockTagBorder(tags: [], lineWidth: 1)
        .overlay {
            if isTargeted || isFocused {
                Rectangle()
                    .stroke(Color.white.opacity(isTargeted ? 0.6 : 0.3), lineWidth: isTargeted ? 2 : 1)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: DropIngest.acceptedTypes, isTargeted: $isTargeted) { providers in
            Task { await handleDrop(providers) }
            return true
        }
        .onChange(of: activateRequest) { _, _ in activate() }
        .onAppear(perform: installPasteMonitor)
        .onDisappear(perform: removePasteMonitor)
    }

    // MARK: - Chrome

    private func placeholder(fontSize: CGFloat) -> some View {
        Text(placeholderText)
            .font(.system(size: fontSize))
            .foregroundStyle(ColosseumTheme.secondaryText)
            .tint(ColosseumTheme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 14)
            .allowsHitTesting(true)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "colosseum" else { return .systemAction }
                openFiles()
                return .handled
            })
            .onTapGesture { focusRequest += 1 }
    }

    private var placeholderText: AttributedString {
        var result = AttributedString("Drop or ")

        var choose = AttributedString("choose")
        choose.link = URL(string: "colosseum://choose")
        choose.underlineStyle = Text.LineStyle(pattern: .solid)
        result += choose

        result += AttributedString(" files, paste a URL (image, video, or link) or type text here")
        return result
    }

    private var hintOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Text(hint)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ColosseumTheme.tertiaryText)
                    .padding(8)
                Spacer()
            }
        }
        .allowsHitTesting(false)
    }

    private var hint: String {
        if isBusy { return "Adding…" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "⌘↩" }
        return isURL(trimmed) ? "⌘↩ link" : "⌘↩ text"
    }

    // MARK: - Focus

    /// ⌘↩ focuses an idle cell, and commits one that already has content.
    private func activate() {
        if isFocused && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { await submit() }
        } else {
            focusRequest += 1
        }
    }

    private func blur() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        isFocused = false
    }

    // MARK: - Submit

    private func isURL(_ string: String) -> Bool {
        ImportService.looksLikeURL(string)
    }

    private func submit() async {
        guard !isBusy else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⌘↩ on an empty cell just keeps focus.
        guard !trimmed.isEmpty else {
            focusRequest += 1
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            // Plain text becomes a note; only URLs are fetched.
            let draft = try await ImportService.resolveInput(trimmed)
            try await ImportService.commit(draft, into: board, context: context)
            finish()
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func finish() {
        do {
            try context.save()
            text = ""
            focusRequest += 1
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Files, drops, pastes

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .image, .movie, .audio, .mpeg4Movie, .quickTimeMovie,
            .mp3, .mpeg4Audio, .wav, .aiff,
            .png, .jpeg, .gif, .webP, .heic
        ]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await ImportService.importFiles(urls, into: board, context: context)
                finish()
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        guard !isBusy else { return }
        let payload = await DropIngest.payload(from: providers)
        guard !payload.isEmpty else { return }

        isBusy = true
        defer { isBusy = false }
        do {
            try await ImportService.importPayload(payload, into: board, context: context)
            finish()
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// The app binds ⌘V to "Paste into Board"; while this cell is focused the
    /// paste belongs to the field instead.
    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isFocused, !isBusy else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }

            if handlePasteMedia() { return nil }
            if let string = NSPasteboard.general.string(forType: .string) {
                text += string
            }
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
            self.pasteMonitor = nil
        }
    }

    /// Swallows the paste when the clipboard holds media rather than text.
    private func handlePasteMedia() -> Bool {
        let pb = NSPasteboard.general
        let fileURLs = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter(\.isFileURL)

        if fileURLs.isEmpty,
           let string = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            // Text and URLs go into the field so they stay editable.
            return false
        }

        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await ImportService.importPasteboard(into: board, context: context)
                finish()
            } catch {
                onError(error.localizedDescription)
            }
        }
        return true
    }
}
