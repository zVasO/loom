import Testing
@testable import LoomGit

// The "n / m viewed" recap over the diff: the diff's files are the universe,
// GitHub's viewed states decorate them, and a toggle flips before GitHub answers.
@Suite("FileReviewProgress — files checked off, file by file")
struct FileReviewProgressTests {

    private func view(_ path: String, _ state: GitHubService.FileViewedState) -> GitHubService.FileView {
        GitHubService.FileView(path: path, state: state)
    }

    @Test("counts the viewed files of the diff and words the recap")
    func countsAndLabel() {
        let progress = FileReviewProgress.compute(
            paths: ["a", "b", "c", "d"],
            views: [view("a", .viewed), view("b", .viewed), view("c", .unviewed)])
        #expect(progress.total == 4)
        #expect(progress.viewedCount == 2)
        #expect(progress.label == "2 / 4 viewed")
        #expect(progress.fraction == 0.5)
        #expect(!progress.isComplete)
    }

    @Test("a file changed since it was viewed is unchecked and flagged")
    func dismissedIsChanged() {
        let progress = FileReviewProgress.compute(paths: ["a", "b"],
                                                  views: [view("a", .dismissed), view("b", .viewed)])
        #expect(progress.viewed == ["b"])
        #expect(progress.changedSinceViewed == ["a"])
        #expect(progress.label == "1 / 2 viewed")
    }

    @Test("a diff file GitHub does not list is unviewed; a GitHub file outside the diff is ignored")
    func universeIsTheDiff() {
        let progress = FileReviewProgress.compute(paths: ["a", "b"],
                                                  views: [view("b", .viewed), view("zzz", .viewed)])
        #expect(progress.total == 2)
        #expect(progress.viewed == ["b"])
    }

    @Test("an empty diff is 0 / 0, never a division by zero")
    func emptyDiff() {
        let progress = FileReviewProgress.compute(paths: [], views: [])
        #expect(progress.fraction == 0)
        #expect(progress.label == "0 / 0 viewed")
        #expect(!progress.isComplete)
    }

    @Test("toggling flips a file both ways and clears its changed flag")
    func toggling() {
        let start = FileReviewProgress.compute(paths: ["a", "b"],
                                               views: [view("a", .dismissed)])
        let checked = start.toggling("a", viewed: true)
        #expect(checked.viewed == ["a"])
        #expect(checked.changedSinceViewed.isEmpty)
        let unchecked = checked.toggling("a", viewed: false)
        #expect(unchecked.viewed.isEmpty)
        #expect(unchecked.total == 2)
        #expect(start.toggling("a", viewed: true).toggling("b", viewed: true).isComplete)
    }
}
