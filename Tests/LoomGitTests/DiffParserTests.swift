import Testing
import LoomGit

// v4 PR review — GitHub-like split diff. Parsing and row alignment are pure.

@Suite("DiffParser — unified diff to structured files")
struct DiffParserTests {

    let sample = """
    diff --git a/src/cache.ts b/src/cache.ts
    index 111..222 100644
    --- a/src/cache.ts
    +++ b/src/cache.ts
    @@ -10,4 +10,5 @@ export function get() {
     const ttl = 60
    -return stale
    +if (fresh) return value
    +return refresh()
     }
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1,2 +1,2 @@
    -old title
    +new title
     body
    """

    @Test("files, hunks, line kinds and running line numbers")
    func parseStructure() {
        let files = DiffParser.parse(sample)
        #expect(files.count == 2)
        #expect(files[0].path == "src/cache.ts")
        #expect(files[1].path == "README.md")
        let hunk = files[0].hunks[0]
        #expect(hunk.lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context])
        #expect(hunk.lines[0].oldNumber == 10)
        #expect(hunk.lines[0].newNumber == 10)
        #expect(hunk.lines[1].oldNumber == 11)      // deletion advances old only
        #expect(hunk.lines[1].newNumber == nil)
        #expect(hunk.lines[2].newNumber == 11)      // addition advances new only
        #expect(hunk.lines[3].newNumber == 12)
        #expect(hunk.lines[4].oldNumber == 12)
        #expect(hunk.lines[4].newNumber == 13)
        #expect(files[0].additions == 2)
        #expect(files[0].deletions == 1)
    }

    @Test("split alignment pairs deletion runs with addition runs")
    func splitRows() {
        let files = DiffParser.parse(sample)
        let rows = DiffParser.splitRows(files[0].hunks[0])
        // context | (del ↔ add) | (nil ↔ add) | context
        #expect(rows.count == 4)
        #expect(rows[0].left?.kind == .context && rows[0].right?.kind == .context)
        #expect(rows[1].left?.kind == .deletion && rows[1].right?.kind == .addition)
        #expect(rows[2].left == nil && rows[2].right?.kind == .addition)
        #expect(rows[3].left?.kind == .context)
    }
}
