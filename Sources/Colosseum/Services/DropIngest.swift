import AppKit
import Foundation
import UniformTypeIdentifiers

/// Normalises a drag-and-drop payload into things the importer understands.
struct DropPayload: Sendable {
    var fileURLs: [URL] = []
    var strings: [String] = []
    /// Raw image bytes (GIF/PNG preserved, TIFF flattened to PNG).
    var imageData: [Data] = []

    var isEmpty: Bool { fileURLs.isEmpty && strings.isEmpty && imageData.isEmpty }
}

enum DropIngest {
    /// Types a view should accept to cover files, URLs, text, and raw images.
    static let acceptedTypes: [UTType] = [.fileURL, .url, .plainText, .image, .gif, .png, .tiff]

    static func payload(from providers: [NSItemProvider]) async -> DropPayload {
        var payload = DropPayload()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await loadFileURL(from: provider) {
                    payload.fileURLs.append(url)
                    continue
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await loadURL(from: provider) {
                    if url.isFileURL {
                        payload.fileURLs.append(url)
                    } else {
                        payload.strings.append(url.absoluteString)
                    }
                    continue
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier),
               let data = await loadData(from: provider, type: .gif) {
                payload.imageData.append(data)
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier),
               let data = await loadData(from: provider, type: .png) {
                payload.imageData.append(data)
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadString(from: provider) {
                    payload.strings.append(text)
                    continue
                }
            }

            if provider.canLoadObject(ofClass: NSImage.self),
               let image = await loadImage(from: provider),
               let data = pngData(from: image) {
                payload.imageData.append(data)
            }
        }

        return payload
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Provider loading

    private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                cont.resume(returning: data)
            }
        }
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                cont.resume(returning: url(from: item))
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                cont.resume(returning: url(from: item))
            }
        }
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let string = item as? String {
                    cont.resume(returning: string)
                } else if let data = item as? Data {
                    cont.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func loadImage(from provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                cont.resume(returning: object as? NSImage)
            }
        }
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }
}
