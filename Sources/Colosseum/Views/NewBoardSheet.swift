import SwiftUI

struct NewBoardSheet: View {
    var onCreate: (String) -> Void
    var onDismiss: () -> Void

    @State private var title = ""
    @State private var keyMonitor = KeyNavMonitor()
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New board")
                    .font(.system(size: TypeScale.t3, weight: .bold))
                    .foregroundStyle(ColosseumTheme.primaryText)
                Spacer()
            }
            .padding(.horizontal, Space.s3)
            .frame(height: Space.s7)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ColosseumTheme.border).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: Space.s3) {
                TextField("Board title", text: $title)
                    .colosseumField(focused: titleFocused)
                    .focused($titleFocused)
                    .onSubmit { create() }

                HStack {
                    Spacer()
                    Button("Cancel") { onDismiss() }
                        .buttonStyle(ChromeButtonStyle())
                        .pointingHandCursor()
                    Button("Create") { create() }
                        .buttonStyle(ChromeButtonStyle(emphasized: true))
                        .pointingHandCursor()
                }
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: ColosseumTheme.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(ColosseumTheme.canvas)
        .overlay(Rectangle().stroke(ColosseumTheme.border, lineWidth: 1))
        .transaction { transaction in transaction.animation = nil }
        .onAppear {
            installKeyMonitor()
            DispatchQueue.main.async { titleFocused = true }
        }
        .onDisappear { keyMonitor.remove() }
        .onExitCommand { onDismiss() }
    }

    private func installKeyMonitor() {
        keyMonitor.onTab = {
            titleFocused = true
            return true
        }
        keyMonitor.onEscape = { onDismiss() }
        keyMonitor.install()
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(trimmed.isEmpty ? "Untitled" : trimmed)
        onDismiss()
    }
}
