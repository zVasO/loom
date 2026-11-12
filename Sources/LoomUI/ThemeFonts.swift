import AppKit
import CoreText
import Observation
import SwiftUI

// MARK: - Google Fonts (pure)

/// Where the fonts a tweakcn theme names come from: tweakcn's editor loads
/// them from Google Fonts, so does Loom when they are not installed. Pure:
/// the address of a family's stylesheet, and the font files it lists.
public enum GoogleFonts {

    /// The weights the app writes in: regular, medium, semibold, bold.
    /// Google answers with the ones the family has.
    public static let weights = [400, 500, 600, 700]

    /// A family's stylesheet. nil for a name that cannot be a family's
    /// (anything but letters, digits, spaces and dashes).
    public static func stylesheetURL(family: String, weights: [Int] = GoogleFonts.weights) -> URL? {
        stylesheetURL(families: [family], weights: weights)
    }

    /// One stylesheet for several families — what a document links to.
    public static func stylesheetURL(families: [String], weights: [Int] = GoogleFonts.weights) -> URL? {
        let names = families.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !names.isEmpty, names.allSatisfy(isFamilyName) else { return nil }
        let axis = weights.map(String.init).joined(separator: ";")
        let query = names
            .map { "family=" + $0.replacingOccurrences(of: " ", with: "+") + ":wght@" + axis }
            .joined(separator: "&")
        return URL(string: "https://fonts.googleapis.com/css2?" + query + "&display=swap")
    }

    static func isFamilyName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64
            && name.allSatisfy { ($0.isLetter || $0.isNumber || $0 == " " || $0 == "-") && $0.isASCII }
    }

    /// A font file of a stylesheet: an upright face at one weight.
    public struct Face: Equatable, Sendable {
        public let weight: Int
        public let url: URL
    }

    /// The upright TrueType/OpenType files a stylesheet lists, one per
    /// weight, lightest first. Only `https://fonts.gstatic.com/…​.ttf|.otf`
    /// is accepted: anything else — another host, a web font format the
    /// system cannot register — is left out.
    public static func faces(inStylesheet css: String) -> [Face] {
        var faces: [Int: URL] = [:]
        var rest = css[...]
        while let start = rest.range(of: "@font-face") {
            guard let open = rest[start.upperBound...].firstIndex(of: "{"),
                  let close = rest[open...].firstIndex(of: "}") else { break }
            let block = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            let style = declaration("font-style", in: block) ?? "normal"
            guard style == "normal",
                  let weight = declaration("font-weight", in: block).flatMap({ Int($0) }),
                  faces[weight] == nil,
                  let url = sourceURL(in: block) else { continue }
            faces[weight] = url
        }
        return faces.keys.sorted().compactMap { weight in
            faces[weight].map { Face(weight: weight, url: $0) }
        }
    }

    /// `name: value;` inside a block → the value, trimmed and lowercased.
    private static func declaration(_ name: String, in block: Substring) -> String? {
        for statement in block.split(separator: ";") {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix(name + ":") else { continue }
            return trimmed.dropFirst(name.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return nil
    }

    /// The first `url(…)` of a block that is a font file on Google's host.
    private static func sourceURL(in block: Substring) -> URL? {
        var rest = block
        while let open = rest.range(of: "url(") {
            guard let close = rest[open.upperBound...].firstIndex(of: ")") else { return nil }
            let raw = rest[open.upperBound..<close]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            rest = rest[rest.index(after: close)...]
            if let url = URL(string: raw), isFontFile(url) { return url }
        }
        return nil
    }

    static func isFontFile(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "fonts.gstatic.com"
            && ["ttf", "otf"].contains(url.pathExtension.lowercased())
    }
}

// MARK: - The fonts of a theme, on this Mac

/// A CSS font stack turned into a SwiftUI font, the way a browser reads
/// it: the first family that is there — fetched from Google Fonts for the
/// theme, or installed on the Mac — else the system face its generic
/// keyword names. Fetched families live in the themes folder
/// (`themes/fonts/<family>/`) and are registered for this process only.
@Observable
@MainActor
public final class ThemeFonts {
    public static let shared = ThemeFonts()

    /// Bumped when a family arrives: every view that asked for a font redraws.
    public private(set) var revision = 0

    @ObservationIgnored private var directory: URL?
    /// Font requests have their own session: no cookie, no shared cache,
    /// and a wait counted in seconds — a network that swallows them must
    /// not hold an import for minutes.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    /// Fetched families, by lowercased name.
    @ObservationIgnored private var fetched: [String: FetchedFamily] = [:]
    /// Families Google does not have (it answered 400): never asked again,
    /// this launch or the next — kept in `unknown.json` beside the fonts.
    @ObservationIgnored private var unknown: Set<String> = []
    @ObservationIgnored private var inFlight: [String: Task<Bool, Never>] = [:]
    /// The Mac's own families, lowercased name → name; built on first use.
    @ObservationIgnored private var systemFamilies: [String: String]?
    @ObservationIgnored private var systemFaces: [SystemFace: String] = [:]
    @ObservationIgnored private var resolutions: [String: Resolution] = [:]

    private init() {}

    /// A family fetched for a theme: its name and, per CSS weight, the
    /// PostScript name of the face — Google's files do not always group
    /// their weights under one family name, so the weight is ours to keep.
    struct FetchedFamily: Codable, Equatable {
        var name: String
        var faces: [Int: String]

        /// The face for a weight, CSS's way: the nearest one, the lighter
        /// of two as near up to medium, the heavier above.
        func face(nearest weight: Int) -> String? {
            let best = faces.keys.min { a, b in
                let (da, db) = (abs(a - weight), abs(b - weight))
                if da != db { return da < db }
                return weight <= 500 ? a < b : a > b
            }
            return best.flatMap { faces[$0] }
        }
    }

    private struct SystemFace: Hashable {
        let family: String
        let weight: Int
    }

    enum Resolution: Equatable {
        case fetched(String)
        case system(String)
        case generic(FontStack.Generic)
        case none
    }

    // MARK: Fonts

    /// The font a stack resolves to at this size and weight; the system's,
    /// in the design asked for, when the stack names nothing this Mac has.
    public func font(stack: String, size: CGFloat, weight: Font.Weight?, design: Font.Design?) -> Font {
        _ = revision
        switch resolve(stack) {
        case .fetched(let key):
            if let face = fetched[key]?.face(nearest: Self.cssWeight(weight)) {
                return .custom(face, fixedSize: size)
            }
            return .system(size: size, weight: weight, design: design)
        case .system(let family):
            return .custom(systemFace(family, weight: weight), fixedSize: size)
        case .generic(let generic):
            return .system(size: size, weight: weight, design: generic.design)
        case .none:
            return .system(size: size, weight: weight, design: design)
        }
    }

    /// The family a stack resolves to on this Mac, for the settings to
    /// name; nil when it comes down to a system face.
    public func familyName(for stack: String) -> String? {
        _ = revision
        switch resolve(stack) {
        case .fetched(let key): return fetched[key]?.name
        case .system(let family): return family
        case .generic, .none: return nil
        }
    }

    /// Whether a family can be drawn right now.
    public func isAvailable(_ family: String) -> Bool {
        let key = family.lowercased()
        return fetched[key] != nil || systemFamily(key) != nil
    }

    func resolve(_ stack: String) -> Resolution {
        if let cached = resolutions[stack] { return cached }
        var resolution = Resolution.none
        for entry in FontStack.parse(stack) {
            if case .generic(let generic) = entry {
                resolution = .generic(generic)
                break
            }
            guard case .family(let name) = entry else { continue }
            let key = name.lowercased()
            if fetched[key] != nil {
                resolution = .fetched(key)
                break
            }
            if let family = systemFamily(key) {
                resolution = .system(family)
                break
            }
        }
        resolutions[stack] = resolution
        return resolution
    }

    private func systemFamily(_ key: String) -> String? {
        if systemFamilies == nil {
            var families: [String: String] = [:]
            for family in NSFontManager.shared.availableFontFamilies {
                families[family.lowercased()] = family
            }
            systemFamilies = families
        }
        return systemFamilies?[key]
    }

    /// The PostScript name of the upright face of an installed family
    /// nearest to a weight (AppKit's 0…15 scale: 5 regular, 9 bold).
    private func systemFace(_ family: String, weight: Font.Weight?) -> String {
        let target = Self.appKitWeight(weight)
        let key = SystemFace(family: family, weight: target)
        if let cached = systemFaces[key] { return cached }
        var best: (name: String, distance: Int)?
        for member in NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [] {
            guard member.count >= 4, let name = member[0] as? String,
                  let memberWeight = member[2] as? Int, let rawTraits = member[3] as? UInt else { continue }
            let traits = NSFontTraitMask(rawValue: rawTraits)
            var distance = abs(memberWeight - target) * 10
            if traits.contains(.italicFontMask) { distance += 1_000 }
            if traits.contains(.condensedFontMask) || traits.contains(.expandedFontMask)
                || traits.contains(.narrowFontMask) || traits.contains(.compressedFontMask) {
                distance += 500
            }
            if let current = best, current.distance <= distance { continue }
            best = (name, distance)
        }
        let name = best?.name ?? family
        systemFaces[key] = name
        return name
    }

    nonisolated static func cssWeight(_ weight: Font.Weight?) -> Int {
        switch weight ?? .regular {
        case .ultraLight: return 100
        case .thin: return 200
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }

    nonisolated static func appKitWeight(_ weight: Font.Weight?) -> Int {
        switch weight ?? .regular {
        case .ultraLight: return 1
        case .thin: return 2
        case .light: return 3
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 11
        case .black: return 12
        default: return 5
        }
    }

    private func invalidate() {
        resolutions = [:]
        systemFaces = [:]
        systemFamilies = nil
        revision += 1
    }

    // MARK: Fetched families

    /// Where fetched families are kept. Registers the ones already there:
    /// called once at launch, before the first frame asks for a font.
    public func configure(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("unknown.json")),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            unknown = Set(names)
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let family = try? JSONDecoder().decode(FetchedFamily.self, from: data) else { continue }
            var registered = FetchedFamily(name: family.name, faces: [:])
            for weight in family.faces.keys {
                if let face = Self.register(folder.appendingPathComponent("\(weight).ttf")) {
                    registered.faces[weight] = face
                }
            }
            if !registered.faces.isEmpty { fetched[family.name.lowercased()] = registered }
        }
        invalidate()
    }

    /// Makes the fonts of these stacks drawable: for each stack, the
    /// families ahead of its first generic keyword are tried in order —
    /// installed, already fetched, or fetched now from Google Fonts — until
    /// one is there. Returns the families that could not be had.
    @discardableResult
    public func ensure(stacks: [String]) async -> [String] {
        var missing: [String] = []
        for stack in Set(stacks).sorted() {
            var tried: [String] = []
            var found = false
            // A stack names a few families; a file that names hundreds
            // is not asking for a font.
            for family in FontStack.namedFamilies(stack).prefix(4) {
                if isAvailable(family) { found = true; break }
                if await fetch(family) { found = true; break }
                tried.append(family)
            }
            if !found { missing += tried }
        }
        return missing
    }

    /// The families fetched from Google Fonts among these stacks' first
    /// choices — what a document may load from the same place.
    public func fetchedFamilies(in stacks: [String]) -> [String] {
        var names: [String] = []
        for stack in stacks {
            guard case .fetched(let key) = resolve(stack), let name = fetched[key]?.name,
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// Fetches a family from Google Fonts and registers it. False when
    /// Google has no such family, or cannot be reached.
    public func fetch(_ family: String) async -> Bool {
        let key = family.lowercased()
        if fetched[key] != nil { return true }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.download(family) }
        inFlight[key] = task
        let done = await task.value
        inFlight[key] = nil
        return done
    }

    private func download(_ family: String) async -> Bool {
        let key = family.lowercased()
        guard let directory, !unknown.contains(key),
              let stylesheet = GoogleFonts.stylesheetURL(family: family) else { return false }
        do {
            let (body, response) = try await session.data(from: stylesheet)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard status == 200 else {
                // 400: no such family — asking again would say the same.
                // Anything else (a rate limit, a proxy) is worth another try.
                if status == 400 { rememberUnknown(key) }
                return false
            }
            // A page that is not Google's stylesheet (a captive portal) has
            // no face to give: not remembered either.
            let faces = GoogleFonts.faces(inStylesheet: String(decoding: body, as: UTF8.self))
            guard !faces.isEmpty else { return false }
            let folder = directory.appendingPathComponent(Self.slug(family))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var entry = FetchedFamily(name: family, faces: [:])
            for face in faces {
                let (data, fileResponse) = try await session.data(from: face.url)
                guard (fileResponse as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let file = folder.appendingPathComponent("\(face.weight).ttf")
                try data.write(to: file, options: .atomic)
                if let name = Self.register(file) { entry.faces[face.weight] = name }
            }
            guard !entry.faces.isEmpty else { return false }
            try JSONEncoder().encode(entry)
                .write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            fetched[key] = entry
            invalidate()
            return true
        } catch {
            return false
        }
    }

    /// A family Google does not have: written down, so that no launch asks
    /// for it again.
    private func rememberUnknown(_ key: String) {
        unknown.insert(key)
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(unknown.sorted())
            .write(to: directory.appendingPathComponent("unknown.json"), options: .atomic)
    }

    /// Registers a font file for this process and returns its PostScript
    /// name; nil when the file is not a font.
    private static func register(_ file: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        else { return nil }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
            // Already registered (the same file, asked twice) is no failure.
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            guard code == CTFontManagerError.alreadyRegistered.rawValue else { return nil }
        }
        return name
    }

    nonisolated static func slug(_ family: String) -> String {
        String(family.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}

extension FontStack.Generic {
    /// The system design a generic keyword stands for.
    var design: Font.Design {
        switch self {
        case .sans: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        case .rounded: return .rounded
        }
    }
}
