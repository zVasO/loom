import Foundation

/// The page width an agent's browser opens at: one per project, chosen in
/// Settings or from the panel, else the default for every project. The
/// agent's browser_resize and the panel's menu change a session's browser
/// only — a layout under test never moves the next session's default.
public struct AgentViewportDefaults: Equatable, Sendable {

    /// A laptop: "Fit" in a side panel next to an 80-column terminal is a
    /// phone or tablet layout (~640 CSS px), rarely what an agent tests.
    public static let factoryDefault: ViewportWidth = .css(1_280)

    public static let globalKey = "loom.agentBrowser.defaultWidth.global"
    public static let projectsKey = "loom.agentBrowser.defaultWidth.projects"
    /// Before: the last width a project's browser had, one key per project.
    public static let legacyPrefix = "loom.agentBrowser.viewport."

    public var global: ViewportWidth
    public private(set) var perProject: [UUID: ViewportWidth]

    public init(global: ViewportWidth = factoryDefault, perProject: [UUID: ViewportWidth] = [:]) {
        self.global = global
        self.perProject = perProject
    }

    /// The width a project's sessions open at; nil (no project) takes the default.
    public func width(for project: UUID?) -> ViewportWidth {
        project.flatMap { perProject[$0] } ?? global
    }

    /// The project's own width, or nil when it follows the default.
    public func override(for project: UUID) -> ViewportWidth? {
        perProject[project]
    }

    /// nil: the project follows the default again.
    public mutating func set(_ width: ViewportWidth?, for project: UUID) {
        perProject[project] = width
    }

    public mutating func forget(_ project: UUID) {
        perProject[project] = nil
    }

    // MARK: - Storage (0 is Fit)

    static func stored(_ width: ViewportWidth) -> Int {
        switch width {
        case .fit: return 0
        case .css(let pixels): return pixels
        }
    }

    static func width(stored value: Int) -> ViewportWidth? {
        if value == 0 { return .fit }
        return ViewportWidth.range.contains(value) ? .css(value) : nil
    }

    /// The saved defaults; a project's last width from before (the legacy
    /// key) becomes its own default once, and the legacy key goes.
    public static func load(from defaults: UserDefaults) -> AgentViewportDefaults {
        var result = AgentViewportDefaults()
        if defaults.object(forKey: globalKey) != nil, let global = width(stored: defaults.integer(forKey: globalKey)) {
            result.global = global
        }
        for (key, value) in (defaults.dictionary(forKey: projectsKey) as? [String: Int]) ?? [:] {
            if let id = UUID(uuidString: key), let width = width(stored: value) { result.perProject[id] = width }
        }
        var migrated = false
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyPrefix) {
            if let id = UUID(uuidString: String(key.dropFirst(legacyPrefix.count))),
               result.perProject[id] == nil,
               let data = defaults.data(forKey: key),
               let width = try? JSONDecoder().decode(ViewportWidth.self, from: data) {
                result.perProject[id] = width
            }
            defaults.removeObject(forKey: key)
            migrated = true
        }
        if migrated { result.save(to: defaults) }
        return result
    }

    public func save(to defaults: UserDefaults) {
        if global == Self.factoryDefault {
            defaults.removeObject(forKey: Self.globalKey)
        } else {
            defaults.set(Self.stored(global), forKey: Self.globalKey)
        }
        let map = Dictionary(uniqueKeysWithValues: perProject.map { ($0.key.uuidString, Self.stored($0.value)) })
        if map.isEmpty {
            defaults.removeObject(forKey: Self.projectsKey)
        } else {
            defaults.set(map, forKey: Self.projectsKey)
        }
    }
}
