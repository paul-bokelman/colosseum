import SwiftData
import SwiftUI

struct ImportArenaSheet: View {
    @Environment(\.modelContext) private var context

    var onImported: (Board) -> Void
    var onBrowse: (ArenaBrowseTarget) -> Void
    var onDismiss: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case browse = "Browse"
        case importBoard = "Import"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .browse
    @State private var urlText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var progressLabel = ""
    @State private var progressValue: Double = 0
    @State private var progressTotal: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("Are.na")
                    .font(.system(size: TypeScale.t3, weight: .bold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: TypeScale.t2))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                        .frame(width: Space.s4, height: Space.s4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(isWorking)
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isWorking)

            Text(mode == .browse
                  ? "Preview a public channel in Colosseum — media streams from Are.na and connected blocks remain remote."
                  : "Download the whole channel into a new local board (images, video, and audio copied to disk).")
                .font(.system(size: TypeScale.t1))
                .foregroundStyle(ColosseumTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://www.are.na/user/channel-slug", text: $urlText)
                .colosseumField()
                .disabled(isWorking)

            if isWorking {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ProgressView(value: progressTotal > 0 ? progressValue : nil, total: progressTotal > 0 ? progressTotal : 1)
                    Text(progressLabel)
                        .font(.system(size: TypeScale.t0))
                        .foregroundStyle(ColosseumTheme.secondaryText)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: TypeScale.t0))
                    .foregroundStyle(ColosseumTheme.alert)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(ChromeButtonStyle())
                    .pointingHandCursor()
                    .disabled(isWorking)
                Button(primaryLabel) {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || !canSubmit)
                .buttonStyle(ChromeButtonStyle(emphasized: true))
                .pointingHandCursor()
            }
        }
        .padding(Space.s4)
        .frame(width: ColosseumTheme.panelWidth)
        .background(ColosseumTheme.canvas)
        .contentShape(Rectangle())
        .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
        .onExitCommand { onDismiss() }
    }

    private var primaryLabel: String {
        switch mode {
        case .browse: return "Browse channel"
        case .importBoard: return isWorking ? "Importing…" : "Import board"
        }
    }

    private var canSubmit: Bool {
        ArenaService.isArenaChannelURL(urlText)
    }

    private func submit() async {
        errorMessage = nil
        switch mode {
        case .browse:
            guard let parsed = ArenaService.parseChannelURL(urlText) else {
                errorMessage = "Enter a valid Are.na channel URL"
                return
            }
            let target = ArenaBrowseTarget(
                slug: parsed.channelSlug,
                urlString: urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onDismiss()
            onBrowse(target)
        case .importBoard:
            await importBoard()
        }
    }

    private func importBoard() async {
        isWorking = true
        progressLabel = "Starting…"
        progressValue = 0
        progressTotal = 0
        defer { isWorking = false }

        do {
            let board = try await ArenaImportService.importChannel(
                fromURLString: urlText,
                context: context
            ) { progress in
                progressLabel = progress.phase
                progressValue = Double(progress.completed)
                progressTotal = Double(max(progress.total, 0))
            }
            onImported(board)
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
