import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// In-memory capture ready to preview, then commit onto a board.
enum CaptureDraft {
    case arenaChannel(ArenaChannelPreview)
    case remote(RemoteMediaResult)
    case pastedImage(Data)
    case text(String)
    case localFile(URL)

    var displayTitle: String {
        switch self {
        case .arenaChannel(let preview):
            return preview.title.isEmpty ? preview.slug : preview.title
        case .remote(let remote):
            return remote.title.isEmpty ? remote.sourceURL.absoluteString : remote.title
        case .pastedImage:
            return "Pasted image"
        case .text(let body):
            let first = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return first.isEmpty ? "Text" : first
        case .localFile(let url):
            return url.deletingPathExtension().lastPathComponent
        }
    }

    var kind: BlockKind {
        switch self {
        case .arenaChannel: return .arenaChannel
        case .remote(let remote):
            switch remote.kind {
            case .image: return .image
            case .video: return .video
            case .audio: return .audio
            case .link: return .link
            }
        case .pastedImage: return .image
        case .text: return .text
        case .localFile(let url):
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            if let type, type.conforms(to: .image) { return .image }
            if let type, type.conforms(to: .audio) { return .audio }
            if let type, type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
                return .video
            }
            return .link
        }
    }

    var kindLabel: String {
        switch kind {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .link: return "Link"
        case .text: return "Text"
        case .arenaChannel: return "Are.na"
        }
    }

    @MainActor
    var previewImage: NSImage? {
        switch self {
        case .remote(let remote) where remote.kind == .image:
            guard let data = remote.data else { return nil }
            return NSImage(data: data)
        case .pastedImage(let data):
            return NSImage(data: data)
        case .localFile(let url):
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            if let type, type.conforms(to: .image) {
                return NSImage(contentsOf: url)
            }
            return nil
        default:
            return nil
        }
    }
}

@MainActor
enum ImportService {
    enum ImportError: LocalizedError {
        case unsupported
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Unsupported file type"
            case .failed(let message): return message
            }
        }
    }

    /// Positions decrease so new connections sort to the top of the board.
    static func nextPosition(in board: Board) -> Int {
        (board.connections.map(\.position).min() ?? 0) - 1
    }

    static func connect(block: Block, to board: Board, context: ModelContext) {
        if board.connections.contains(where: { $0.block?.id == block.id }) { return }
        let connection = Connection(board: board, block: block, position: nextPosition(in: board))
        context.insert(connection)
        board.updatedAt = .now
    }

    static func connect(nestedBoard: Board, to board: Board, context: ModelContext) {
        guard nestedBoard.id != board.id else { return }
        if board.connections.contains(where: { $0.nestedBoard?.id == nestedBoard.id }) { return }
        let connection = Connection(board: board, nestedBoard: nestedBoard, position: nextPosition(in: board))
        context.insert(connection)
        board.updatedAt = .now
    }

    // MARK: - Resolve / commit

    /// True when input should be fetched as a URL rather than kept as a note.
    /// Multi-line input is always text.
    static func looksLikeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    /// Resolves typed input: a URL is fetched, anything else becomes a text block.
    static func resolveInput(_ string: String) async throws -> CaptureDraft {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.failed("Nothing to add") }
        guard looksLikeURL(trimmed) else { return .text(trimmed) }
        return try await resolveURLString(trimmed)
    }

    static func resolveURLString(_ string: String) async throws -> CaptureDraft {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.failed("Empty URL") }

        if ArenaService.isArenaChannelURL(trimmed) {
            let preview = try await ArenaService.fetchFromURLString(trimmed)
            return .arenaChannel(preview)
        }

        let remote = try await URLImportService.fetch(trimmed)
        return .remote(remote)
    }

    /// Resolves a single item from the pasteboard for preview. Multiple local files
    /// are not supported here — use `importPasteboard` / `importFiles` instead.
    static func resolvePasteboard() async throws -> CaptureDraft {
        let pb = NSPasteboard.general

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.filter { $0.isFileURL }
            if let first = fileURLs.first {
                return .localFile(first)
            }
            if let url = urls.first(where: { !$0.isFileURL }) {
                return try await resolveURLString(url.absoluteString)
            }
        }

        // Prefer raw image bytes so animated GIFs aren't flattened via TIFF→PNG.
        if let data = rawPasteboardImageData(from: pb) {
            return .pastedImage(data)
        }

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            return .pastedImage(data)
        }

        if let string = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            if string.hasPrefix("http://") || string.hasPrefix("https://") {
                return try await resolveURLString(string)
            }
            return .text(string)
        }

        throw ImportError.failed("Nothing to paste")
    }

    static func commit(
        _ draft: CaptureDraft,
        notes: String = "",
        into board: Board,
        context: ModelContext
    ) async throws {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        switch draft {
        case .arenaChannel(let preview):
            let block = Block(
                kind: .arenaChannel,
                title: preview.title,
                notes: trimmedNotes,
                sourceURL: preview.url.absoluteString,
                arenaSlug: preview.slug,
                arenaURL: preview.url.absoluteString,
                arenaOwnerName: preview.ownerName,
                arenaBlockCount: preview.blockCount,
                arenaUpdatedAt: preview.updatedAt
            )
            context.insert(block)
            connect(block: block, to: board, context: context)

        case .remote(let remote):
            try await commitRemote(remote, notes: trimmedNotes, into: board, context: context)

        case .pastedImage(let data):
            let blockID = UUID()
            let isGIF = AnimatedImage.isGIF(data: data)
            let filename = isGIF ? "pasteboard.gif" : "pasteboard.png"
            let mime = isGIF ? "image/gif" : "image/png"
            let dest = try MediaLibrary.writeData(data, into: blockID, filename: filename)
            let (w, h) = ThumbnailService.imageDimensions(at: dest)
            let thumb = try ThumbnailService.generateImageThumbnail(from: dest, blockID: blockID)
            let block = Block(
                id: blockID,
                kind: .image,
                title: "Pasted image",
                notes: trimmedNotes,
                localRelativePath: MediaLibrary.relativePath(from: dest),
                thumbRelativePath: thumb.map { MediaLibrary.relativePath(from: $0) },
                mimeType: mime,
                byteSize: Int64(data.count),
                width: w,
                height: h
            )
            context.insert(block)
            connect(block: block, to: board, context: context)

        case .text(let body):
            let block = Block(kind: .text, title: "", notes: trimmedNotes, textBody: body)
            context.insert(block)
            connect(block: block, to: board, context: context)

        case .localFile(let url):
            try await importFile(url, notes: trimmedNotes, into: board, context: context)
        }
    }

    private static func commitRemote(
        _ remote: RemoteMediaResult,
        notes: String,
        into board: Board,
        context: ModelContext
    ) async throws {
        let blockID = UUID()

        switch remote.kind {
        case .image:
            guard let data = remote.data else { throw ImportError.failed("Empty image data") }
            let dest = try MediaLibrary.writeData(data, into: blockID, filename: remote.filename)
            let (w, h) = ThumbnailService.imageDimensions(at: dest)
            let thumb = try ThumbnailService.generateImageThumbnail(from: dest, blockID: blockID)
            let block = Block(
                id: blockID,
                kind: .image,
                title: remote.title,
                notes: notes,
                sourceURL: remote.sourceURL.absoluteString,
                localRelativePath: MediaLibrary.relativePath(from: dest),
                thumbRelativePath: thumb.map { MediaLibrary.relativePath(from: $0) },
                mimeType: remote.mimeType,
                byteSize: Int64(data.count),
                width: w,
                height: h
            )
            context.insert(block)
            connect(block: block, to: board, context: context)

        case .video:
            guard let data = remote.data else { throw ImportError.failed("Empty video data") }
            let dest = try MediaLibrary.writeData(data, into: blockID, filename: remote.filename)
            let meta = await ThumbnailService.videoMetadata(at: dest)
            let thumb = try await ThumbnailService.generateVideoThumbnail(from: dest, blockID: blockID)
            let block = Block(
                id: blockID,
                kind: .video,
                title: remote.title,
                notes: notes,
                sourceURL: remote.sourceURL.absoluteString,
                localRelativePath: MediaLibrary.relativePath(from: dest),
                thumbRelativePath: thumb.map { MediaLibrary.relativePath(from: $0) },
                mimeType: remote.mimeType,
                byteSize: Int64(data.count),
                width: meta.width,
                height: meta.height,
                duration: meta.duration
            )
            context.insert(block)
            connect(block: block, to: board, context: context)

        case .audio:
            guard let data = remote.data else { throw ImportError.failed("Empty audio data") }
            let dest = try MediaLibrary.writeData(data, into: blockID, filename: remote.filename)
            let meta = await ThumbnailService.videoMetadata(at: dest)
            let block = Block(
                id: blockID,
                kind: .audio,
                title: remote.title,
                notes: notes,
                sourceURL: remote.sourceURL.absoluteString,
                localRelativePath: MediaLibrary.relativePath(from: dest),
                mimeType: remote.mimeType,
                byteSize: Int64(data.count),
                duration: meta.duration
            )
            context.insert(block)
            connect(block: block, to: board, context: context)

        case .link:
            let block = Block(
                kind: .link,
                title: remote.title,
                notes: notes,
                sourceURL: remote.sourceURL.absoluteString,
                mimeType: remote.mimeType
            )
            context.insert(block)
            connect(block: block, to: board, context: context)
        }
    }

    /// Raw GIF/PNG bytes from the pasteboard, preserving animation when present.
    /// TIFF is intentionally omitted — it's flattened via the NSImage path instead.
    static func rawPasteboardImageData(from pb: NSPasteboard = .general) -> Data? {
        let types: [NSPasteboard.PasteboardType] = [
            .init(UTType.gif.identifier),
            .init("com.compuserve.gif"),
            .png
        ]
        for type in types {
            if let data = pb.data(forType: type), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    // MARK: - Existing entry points

    static func importFiles(_ urls: [URL], into board: Board, context: ModelContext) async throws {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try await importFile(url, into: board, context: context)
        }
    }

    static func importFile(_ url: URL, into board: Board, context: ModelContext) async throws {
        try await importFile(url, notes: "", into: board, context: context)
    }

    private static func importFile(
        _ url: URL,
        notes: String,
        into board: Board,
        context: ModelContext
    ) async throws {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let blockID = UUID()

        if let type, type.conforms(to: .image) {
            let dest = try MediaLibrary.copyFile(url, into: blockID)
            let (w, h) = ThumbnailService.imageDimensions(at: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            let size = attrs[.size] as? Int64 ?? 0
            let thumb = try ThumbnailService.generateImageThumbnail(from: dest, blockID: blockID)
            let block = Block(
                id: blockID,
                kind: .image,
                title: url.deletingPathExtension().lastPathComponent,
                notes: notes,
                sourceURL: url.absoluteString,
                localRelativePath: MediaLibrary.relativePath(from: dest),
                thumbRelativePath: thumb.map { MediaLibrary.relativePath(from: $0) },
                mimeType: type.preferredMIMEType ?? "image/\(url.pathExtension.lowercased())",
                byteSize: size,
                width: w,
                height: h
            )
            context.insert(block)
            connect(block: block, to: board, context: context)
            return
        }

        if let type, !type.conforms(to: .audio),
           type.conforms(to: .movie) || type.conforms(to: .audiovisualContent),
           ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(url.pathExtension.lowercased())
            || (type.conforms(to: .movie)) {
            let dest = try MediaLibrary.copyFile(url, into: blockID)
            let meta = await ThumbnailService.videoMetadata(at: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            let size = attrs[.size] as? Int64 ?? 0
            let thumb = try await ThumbnailService.generateVideoThumbnail(from: dest, blockID: blockID)
            let block = Block(
                id: blockID,
                kind: .video,
                title: url.deletingPathExtension().lastPathComponent,
                notes: notes,
                sourceURL: url.absoluteString,
                localRelativePath: MediaLibrary.relativePath(from: dest),
                thumbRelativePath: thumb.map { MediaLibrary.relativePath(from: $0) },
                mimeType: type.preferredMIMEType ?? "video/\(url.pathExtension.lowercased())",
                byteSize: size,
                width: meta.width,
                height: meta.height,
                duration: meta.duration
            )
            context.insert(block)
            connect(block: block, to: board, context: context)
            return
        }

        if let type, type.conforms(to: .audio) {
            let dest = try MediaLibrary.copyFile(url, into: blockID)
            let meta = await ThumbnailService.videoMetadata(at: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            let size = attrs[.size] as? Int64 ?? 0
            let block = Block(
                id: blockID,
                kind: .audio,
                title: url.deletingPathExtension().lastPathComponent,
                notes: notes,
                sourceURL: url.absoluteString,
                localRelativePath: MediaLibrary.relativePath(from: dest),
                mimeType: type.preferredMIMEType ?? "audio/\(url.pathExtension.lowercased())",
                byteSize: size,
                duration: meta.duration
            )
            context.insert(block)
            connect(block: block, to: board, context: context)
            return
        }

        throw ImportError.unsupported
    }

    static func importURLString(_ string: String, into board: Board, context: ModelContext) async throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let draft = try await resolveURLString(trimmed)
        try await commit(draft, into: board, context: context)
    }

    /// Commits a drag-and-drop payload: files, URLs, text, and raw image bytes.
    static func importPayload(_ payload: DropPayload, into board: Board, context: ModelContext) async throws {
        if !payload.fileURLs.isEmpty {
            try await importFiles(payload.fileURLs, into: board, context: context)
        }

        for data in payload.imageData {
            try await commit(.pastedImage(data), into: board, context: context)
        }

        for string in payload.strings {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                try await importURLString(trimmed, into: board, context: context)
            } else {
                addTextBlock(trimmed, title: "", into: board, context: context)
            }
        }
    }

    static func importPasteboard(into board: Board, context: ModelContext) async throws {
        let pb = NSPasteboard.general

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.filter { $0.isFileURL }
            if !fileURLs.isEmpty {
                try await importFiles(fileURLs, into: board, context: context)
                return
            }
            for url in urls where !url.isFileURL {
                try await importURLString(url.absoluteString, into: board, context: context)
            }
            return
        }

        let draft = try await resolvePasteboard()
        try await commit(draft, into: board, context: context)
    }

    static func addTextBlock(_ body: String, title: String, into board: Board, context: ModelContext) {
        let block = Block(kind: .text, title: title, textBody: body)
        context.insert(block)
        connect(block: block, to: board, context: context)
    }

    static func removeConnection(_ connection: Connection, deleteOrphanedBlock: Bool, context: ModelContext) {
        let block = connection.block
        let board = connection.board
        context.delete(connection)
        board?.updatedAt = .now

        if deleteOrphanedBlock, let block, block.connections.isEmpty {
            deleteOrphanedBlockIfNeeded(block, context: context)
        }
    }

    /// Reconnect a block or nested board at an explicit position (for undo).
    static func reconnect(
        block: Block? = nil,
        nestedBoard: Board? = nil,
        to board: Board,
        position: Int,
        context: ModelContext
    ) {
        if let block {
            if board.connections.contains(where: { $0.block?.id == block.id }) { return }
            let connection = Connection(board: board, block: block, position: position)
            context.insert(connection)
            board.updatedAt = .now
            return
        }
        if let nestedBoard {
            guard nestedBoard.id != board.id else { return }
            if board.connections.contains(where: { $0.nestedBoard?.id == nestedBoard.id }) { return }
            let connection = Connection(board: board, nestedBoard: nestedBoard, position: position)
            context.insert(connection)
            board.updatedAt = .now
        }
    }

    static func deleteOrphanedBlockIfNeeded(_ block: Block, context: ModelContext) {
        guard block.connections.isEmpty else { return }
        if block.localRelativePath != nil {
            MediaLibrary.removeBlockFiles(block.id)
        }
        context.delete(block)
    }
}
