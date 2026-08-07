import AppKit
import SwiftData
import SwiftUI

@main
struct ColosseumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer

    init() {
        do {
            try MediaLibrary.ensureDirectories()
            let schema = Schema([Board.self, Block.self, Connection.self])
            let config = ModelConfiguration(
                "Colosseum",
                schema: schema,
                url: MediaLibrary.storeURL
            )
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to open Colosseum store: \(error)")
        }
    }

    var body: some Scene {
        Window("Colosseum", id: "main") {
            RootView()
                .modelContainer(container)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 600)
                .background(WindowChromeStabilizer())
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Board") {
                    NotificationCenter.default.post(name: .colosseumNewBoard, object: nil)
                }

                Button("Add to Board…") {
                    NotificationCenter.default.post(name: .colosseumAdd, object: nil)
                }

                Button("New Board or Add") {
                    NotificationCenter.default.post(name: .colosseumCommandReturn, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("Connect Board…") {
                    NotificationCenter.default.post(name: .colosseumConnectBoard, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Rename Board…") {
                    NotificationCenter.default.post(name: .colosseumRename, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Paste into Board") {
                    NotificationCenter.default.post(name: .colosseumPaste, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("Open…") {
                    NotificationCenter.default.post(name: .colosseumOpenCommand, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Import Are.na Board") {
                    NotificationCenter.default.post(name: .colosseumArenaImport, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("Fewer Columns") {
                    NotificationCenter.default.post(name: .colosseumColumnsDecrease, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("More Columns") {
                    NotificationCenter.default.post(name: .colosseumColumnsIncrease, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                Button("Search…") {
                    NotificationCenter.default.post(name: .colosseumSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Import…") {
                    NotificationCenter.default.post(name: .colosseumImportArena, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("Boards") {
                    NotificationCenter.default.post(name: .colosseumGoHome, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarCaptureView()
                .modelContainer(container)
        } label: {
            if let image = Bundle.module.image(forResource: "AppIconMark") {
                Image(nsImage: menuBarTemplateImage(from: image))
            } else {
                Image(systemName: "plus.square.on.square")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

private func menuBarTemplateImage(from image: NSImage) -> NSImage {
    let copy = image.copy() as? NSImage ?? image
    copy.isTemplate = true
    // Draw larger glyph; avoid SwiftUI .frame so hit target stays native.
    copy.size = NSSize(width: 22, height: 22)
    return copy
}

extension Notification.Name {
    static let colosseumNewBoard = Notification.Name("colosseum.newBoard")
    static let colosseumAdd = Notification.Name("colosseum.add")
    static let colosseumCommandReturn = Notification.Name("colosseum.commandReturn")
    static let colosseumRename = Notification.Name("colosseum.rename")
    static let colosseumConnectBoard = Notification.Name("colosseum.connectBoard")
    static let colosseumPaste = Notification.Name("colosseum.paste")
    static let colosseumOpenFiles = Notification.Name("colosseum.openFiles")
    /// Context-sensitive ⌘O: open files on a local board, or open channel on Are.na when remote.
    static let colosseumOpenCommand = Notification.Name("colosseum.openCommand")
    /// Show/focus the main window (menu bar Open, Dock reopen).
    static let colosseumRevealMainWindow = Notification.Name("colosseum.revealMainWindow")
    static let colosseumArenaImport = Notification.Name("colosseum.arenaImport")
    static let colosseumImportArena = Notification.Name("colosseum.importArena")
    static let colosseumSearch = Notification.Name("colosseum.search")
    static let colosseumGoHome = Notification.Name("colosseum.goHome")
    static let colosseumColumnsIncrease = Notification.Name("colosseum.columnsIncrease")
    static let colosseumColumnsDecrease = Notification.Name("colosseum.columnsDecrease")
}
