import SwiftData
import SwiftUI

/// Nests an existing board inside this one.
///
/// Blocks are added inline from the grid's add cell; board-to-board
/// connections have no are.na equivalent, so they live here instead.
struct ConnectBoardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Board.title) private var allBoards: [Board]

    let board: Board

    @State private var query = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Connect a board…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            if filtered.isEmpty {
                Text(connectable.isEmpty ? "No other boards to connect" : "No matches")
                    .font(.caption)
                    .foregroundStyle(ColosseumTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.id) { candidate in
                            Button {
                                connect(candidate)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.title)
                                        .font(.system(size: 13))
                                    Text("\(candidate.contentCount) blocks")
                                        .font(.caption)
                                        .foregroundStyle(ColosseumTheme.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let errorMessage {
                Divider()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 420, height: 360)
        .background(ColosseumTheme.canvas)
        .onExitCommand { dismiss() }
    }

    private var connectable: [Board] {
        allBoards.filter { other in
            other.id != board.id
                && !board.connections.contains(where: { $0.nestedBoard?.id == other.id })
        }
    }

    private var filtered: [Board] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return connectable }
        return connectable.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private func connect(_ nested: Board) {
        ImportService.connect(nestedBoard: nested, to: board, context: context)
        do {
            try context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
