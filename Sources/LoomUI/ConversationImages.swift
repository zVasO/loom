import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Images in the chat: pasted or dropped on the composer, they wait there
// as thumbnails; sent, claude gets them as files (it attaches an image whose
// path is pasted into its input) and keeps them in its transcript, where
// the list reads them back to show in the message.

/// An image waiting in the composer: a copy in Loom's temporary folder,
/// whose path is what claude is given, and its thumbnail.
public struct ComposerImage: Identifiable, Equatable {
    public let id: UUID
    /// The copy claude reads.
    public let url: URL
    public let thumbnail: NSImage

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// Where the copies go. Temporary: claude reads them when the message
    /// is sent, and keeps the image in its own transcript.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-images", isDirectory: true)
    }

    /// A pasted or dropped picture, written as PNG.
    public static func make(from image: NSImage) -> ComposerImage? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let id = UUID()
        let url = folder.appendingPathComponent("\(id.uuidString).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            return nil
        }
        return ComposerImage(id: id, url: url, thumbnail: image)
    }

    /// An image file: copied under a plain name, so its path needs no
    /// quoting when it is pasted into claude's input.
    public static func make(copying file: URL) -> ComposerImage? {
        guard isImage(file), let image = NSImage(contentsOf: file) else { return nil }
        let id = UUID()
        let suffix = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
        let url = folder.appendingPathComponent("\(id.uuidString).\(suffix)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: url)
        } catch {
            return nil
        }
        return ComposerImage(id: id, url: url, thumbnail: image)
    }

    static func isImage(_ file: URL) -> Bool {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// What a paste brings: image files copied in Finder, else a picture
    /// alone (a screenshot to the clipboard). Text on the pasteboard is the
    /// field's: then nothing is taken.
    @MainActor
    public static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [ComposerImage] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = files.filter(isImage)
        if !images.isEmpty { return images.compactMap { make(copying: $0) } }
        guard files.isEmpty, pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard) else { return [] }
        return make(from: image).map { [$0] } ?? []
    }

    /// The types a drop on the chat takes.
    public static let dropTypes: [UTType] = [.fileURL, .image]

    /// What a drop brings: image files, or pictures dragged from an app.
    public static func load(from providers: [NSItemProvider]) async -> [ComposerImage] {
        var found: [ComposerImage] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await fileURL(from: provider) {
                if let image = make(copying: url) { found.append(image) }
            } else if provider.canLoadObject(ofClass: NSImage.self),
                      let image = await picture(from: provider),
                      let made = make(from: image) {
                found.append(made)
            }
        }
        return found
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func picture(from provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                continuation.resume(returning: image as? NSImage)
            }
        }
    }
}

/// ⌘V in the composer with a picture on the pasteboard: the field editor
/// would drop it (a text field takes text), so the key is caught first,
/// while a composer has the keyboard.
final class ComposerPasteWatch {
    private var monitor: Any?

    func start(isFocused: @escaping @MainActor () -> Bool, onImages: @escaping @MainActor ([ComposerImage]) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
                  MainActor.assumeIsolated({ isFocused() }) else { return event }
            let images = MainActor.assumeIsolated { ComposerImage.fromPasteboard() }
            guard !images.isEmpty else { return event }
            MainActor.assumeIsolated { onImages(images) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The waiting images, above the field: a thumbnail each, a cross to take
/// one back.
struct ComposerImageStrip: View {
    @Binding var images: [ComposerImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DefaultTheme.space(8)) {
                ForEach(images) { image in
                    Image(nsImage: image.thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: DefaultTheme.radius(8)))
                        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(8))
                            .strokeBorder(DefaultTheme.line2, lineWidth: 1))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                images.removeAll { $0.id == image.id }
                            } label: {
                                AppIcon("xmark", size: 9)
                                    .foregroundStyle(Color.white)
                                    .frame(width: 18, height: 18)
                                    .background(Color.black.opacity(0.75), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                            .help("Remove the image")
                        }
                }
            }
        }
        .frame(height: 64)
    }
}

/// The images of a sent message, above its text: a click opens one in
/// the default viewer.
struct MessageImages: View {
    /// What the images are cached under: the message's id.
    let key: String
    let images: [Data]

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        HStack(spacing: DefaultTheme.space(6)) {
            ForEach(Array(images.indices), id: \.self) { index in
                if let image = Self.image(key: key, index: index, data: images[index]) {
                    Button {
                        Self.open(images[index], key: key, index: index)
                    } label: {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: images.count == 1 ? 320 : 160,
                                   maxHeight: images.count == 1 ? 220 : 120)
                            .clipShape(RoundedRectangle(cornerRadius: DefaultTheme.radius(8)))
                            .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(8))
                                .strokeBorder(DefaultTheme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Open the image")
                }
            }
        }
    }

    /// Decoded once per message, not at every pass of the list.
    static func image(key: String, index: Int, data: Data) -> NSImage? {
        let name = "\(key)#\(index)" as NSString
        if let cached = cache.object(forKey: name) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: name)
        return image
    }

    static func open(_ data: Data, key: String, index: Int) {
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let url = ComposerImage.folder.appendingPathComponent("view-\(String(safe))-\(index).png")
        try? FileManager.default.createDirectory(at: ComposerImage.folder, withIntermediateDirectories: true)
        guard (try? data.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}
