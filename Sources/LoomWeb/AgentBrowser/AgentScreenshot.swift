import AppKit
import Foundation
import WebKit

/// Screenshots for the agent: the visible page (or one element), at its CSS
/// size capped to what a model looks at, written where the MCP server reads.
public enum AgentScreenshot {

    /// The size to encode at: the page's own CSS size, its longest edge at
    /// most `maxEdge` — never the Retina backing, twice as large for nothing.
    public static func targetSize(for size: CGSize, maxEdge: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, maxEdge / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    /// Keeps the newest `keep` files of a directory listing (names sort by sequence).
    public static func pruned(_ names: [String], keep: Int = 30) -> [String] {
        let sorted = names.sorted { a, b in
            (Int(a.prefix { $0.isNumber }) ?? 0) < (Int(b.prefix { $0.isNumber }) ?? 0)
        }
        return Array(sorted.dropLast(keep))
    }

    /// The highest sequence already in `directory` — a previous run's files —
    /// or 0: the numbering goes on after it.
    public static func lastSequence(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { Int($0.prefix { $0.isNumber }) }.max() ?? 0
    }

    /// A snapshot of `rect` (view coordinates; nil = the visible page).
    @MainActor
    static func capture(_ webView: WKWebView, rect: CGRect?) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        if let rect { configuration.rect = rect }
        let box = OneShot<NSImageBox>()
        webView.takeSnapshot(with: configuration) { image, error in
            if let image {
                box.resolve(.success(NSImageBox(image: image)))
            } else {
                box.resolve(.failure(AgentError.failed("the screenshot failed: \(error?.localizedDescription ?? "no image")")))
            }
        }
        return try await box.value().image
    }

    /// Drawn again at exactly `pixels`, then encoded.
    @MainActor
    static func encode(_ image: NSImage, pixels: CGSize, format: ImageFormat) -> Data? {
        render(pixels: pixels, format: format) {
            image.draw(in: CGRect(origin: .zero, size: pixels), from: .zero, operation: .copy, fraction: 1)
        }
    }

    /// One viewport's capture, and the band of it a full-page image takes.
    struct Slice {
        var image: NSImageBox
        /// The band, from the capture's top, in its points.
        var sourceTop: CGFloat
        var sourceHeight: CGFloat
        /// Where the band sits on the page, in CSS pixels.
        var pageTop: CGFloat
        var pageHeight: CGFloat
    }

    /// The bands, one under the other, at exactly `pixels` for a page of
    /// `pageSize` CSS pixels.
    @MainActor
    static func encode(slices: [Slice], pageSize: CGSize, pixels: CGSize, format: ImageFormat) -> Data? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scaleX = pixels.width / pageSize.width
        let scaleY = pixels.height / pageSize.height
        return render(pixels: pixels, format: format) {
            for slice in slices {
                let image = slice.image.image
                // Both rectangles are bottom-up, as AppKit draws.
                let source = CGRect(x: 0, y: image.size.height - slice.sourceTop - slice.sourceHeight,
                                    width: image.size.width, height: slice.sourceHeight)
                let destination = CGRect(x: 0, y: (pageSize.height - slice.pageTop - slice.pageHeight) * scaleY,
                                         width: pageSize.width * scaleX, height: slice.pageHeight * scaleY)
                image.draw(in: destination, from: source, operation: .copy, fraction: 1)
            }
        }
    }

    @MainActor
    private static func render(pixels: CGSize, format: ImageFormat, draw: () -> Void) -> Data? {
        let width = Int(pixels.width)
        let height = Int(pixels.height)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = pixels
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw()
        context.flushGraphics()
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
    }

    /// Written readable by the user only, in a directory only they can list.
    static func write(_ data: Data, in directory: URL, sequence: Int, format: ImageFormat) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var marked = directory
        try? marked.setResourceValues(excluded)
        let url = directory.appendingPathComponent(String(format: "%06d", sequence) + "." + format.fileExtension)
        guard manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AgentError.failed("the screenshot could not be written to \(url.path)")
        }
        let existing = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        // Never the file just written: the agent is about to read it.
        for name in pruned(existing) where name != url.lastPathComponent {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
        return url
    }
}

/// NSImage is not Sendable; the box only crosses from WebKit's callback (on
/// the main thread) to the awaiting main-actor code.
struct NSImageBox: @unchecked Sendable {
    let image: NSImage
}
