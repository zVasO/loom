import Foundation

// The page's cursor in the panel (panel design §2, Cursor). The helper's
// `hitInfo` samples the computed `cursor` under the pointer, whether the
// element is editable and whether it is a link; the view shows the NSCursor
// of this kind (LoomWeb maps the kind to NSCursor).

/// The NSCursors the panel shows.
public enum CursorKind: String, CaseIterable, Equatable, Sendable {
    case arrow
    case pointingHand
    case iBeam
    case crosshair
    case operationNotAllowed
    case openHand
    case closedHand
    case resizeLeftRight
    case resizeUpDown
    case dragCopy
    case dragLink
    case contextualMenu
}

public enum CSSCursor {

    /// | CSS cursor               | NSCursor                                                   |
    /// |--------------------------|------------------------------------------------------------|
    /// | pointer                  | pointingHand                                               |
    /// | text                     | iBeam                                                      |
    /// | crosshair                | crosshair                                                  |
    /// | not-allowed, no-drop     | operationNotAllowed                                        |
    /// | grab / grabbing          | openHand / closedHand                                      |
    /// | ew-resize, col-resize    | resizeLeftRight                                            |
    /// | ns-resize, row-resize    | resizeUpDown                                               |
    /// | copy / alias             | dragCopy / dragLink                                        |
    /// | context-menu             | contextualMenu                                             |
    /// | auto                     | iBeam over an editable element, pointingHand over a[href], arrow otherwise |
    /// | url(…), none, the rest   | arrow                                                      |
    ///
    /// An image cursor is not drawn; its fallback keyword (`url(x.png), pointer`)
    /// is used instead.
    public static func kind(keyword: String, editable: Bool = false, link: Bool = false) -> CursorKind {
        switch normalized(keyword) {
        case "pointer": return .pointingHand
        case "text": return .iBeam
        case "crosshair": return .crosshair
        case "not-allowed", "no-drop": return .operationNotAllowed
        case "grab": return .openHand
        case "grabbing": return .closedHand
        case "ew-resize", "col-resize": return .resizeLeftRight
        case "ns-resize", "row-resize": return .resizeUpDown
        case "copy": return .dragCopy
        case "alias": return .dragLink
        case "context-menu": return .contextualMenu
        case "auto":
            if editable { return .iBeam }
            if link { return .pointingHand }
            return .arrow
        default: return .arrow
        }
    }

    /// Lowercased, trimmed, the vendor prefix dropped; for an image cursor,
    /// the keyword after the last image ("" when there is none).
    static func normalized(_ keyword: String) -> String {
        var value = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("url(") {
            if let close = value.range(of: ")", options: .backwards) {
                value = String(value[close.upperBound...])
            }
            if let comma = value.range(of: ",", options: .backwards) {
                value = String(value[comma.upperBound...])
            } else {
                value = ""
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("-webkit-") {
            value = String(value.dropFirst("-webkit-".count))
        }
        return value
    }
}
