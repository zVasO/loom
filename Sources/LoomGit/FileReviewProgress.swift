import Foundation

/// Where a review stands, file by file: which ones are checked off, which
/// changed since, and the "3 / 12 viewed" recap. Pure: the diff's files are
/// the universe (what the reviewer can see), GitHub's states decorate them.
public struct FileReviewProgress: Equatable, Sendable {
    /// Paths shown checked.
    public let viewed: Set<String>
    /// Viewed once, changed since (GitHub's DISMISSED): unchecked, flagged.
    public let changedSinceViewed: Set<String>
    public let total: Int

    public init(viewed: Set<String>, changedSinceViewed: Set<String>, total: Int) {
        self.viewed = viewed
        self.changedSinceViewed = changedSinceViewed
        self.total = total
    }

    public static let empty = FileReviewProgress(viewed: [], changedSinceViewed: [], total: 0)

    public var viewedCount: Int { viewed.count }
    public var fraction: Double { total == 0 ? 0 : Double(viewed.count) / Double(total) }
    public var label: String { "\(viewed.count) / \(total) viewed" }
    public var isComplete: Bool { total > 0 && viewed.count == total }

    /// A diff file GitHub does not list is unviewed; a GitHub file missing from
    /// the diff (renamed, binary…) does not inflate the total.
    public static func compute(paths: [String],
                               views: [GitHubService.FileView]) -> FileReviewProgress {
        let universe = Set(paths)
        var viewed: Set<String> = []
        var changed: Set<String> = []
        for view in views where universe.contains(view.path) {
            switch view.state {
            case .viewed: viewed.insert(view.path)
            case .dismissed: changed.insert(view.path)
            case .unviewed: break
            }
        }
        return FileReviewProgress(viewed: viewed, changedSinceViewed: changed, total: universe.count)
    }

    /// The optimistic flip: checked means viewed AND no longer "changed".
    public func toggling(_ path: String, viewed on: Bool) -> FileReviewProgress {
        var viewed = self.viewed
        var changed = changedSinceViewed
        if on {
            viewed.insert(path)
            changed.remove(path)
        } else {
            viewed.remove(path)
        }
        return FileReviewProgress(viewed: viewed, changedSinceViewed: changed, total: total)
    }
}
