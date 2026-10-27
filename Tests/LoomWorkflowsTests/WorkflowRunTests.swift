import Testing
import Foundation
import LoomAPI
import LoomCore
@testable import LoomWorkflows

@Suite("Runs — Jira keys, the run store, the report")
struct WorkflowRunTests {

    @Test("a Jira key is found in a title, a branch, a body — never in utf-8 or sha-256")
    func jiraKeys() {
        #expect(JiraKey.first(in: "HS-1234 Cache des contrats") == "HS-1234")
        #expect(JiraKey.first(in: "[ABC2-7] fix") == "ABC2-7")
        #expect(JiraKey.first(in: "feat/hs-1234-contract-cache") == "HS-1234", "branches spell it lowercase")
        #expect(JiraKey.first(in: "files are utf-8 and hashed with sha-256") == nil)
        #expect(JiraKey.first(in: "fix the cache for ab-12 users") == nil, "lowercase in prose is a word")
        #expect(JiraKey.detect(in: ["Fix the cache", "feat/cache", "Closes PAY-88."]) == "PAY-88")
        #expect(JiraKey.detect(in: ["Fix", "main", ""]) == nil)
    }

    @Test("runs survive the disk, newest first; one cut short by a quit reads as interrupted")
    func store() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowRunStore(directory: directory)
        let workflow = BuiltInWorkflows.prReview()
        let planner = WorkflowPlanner(workflow)
        var state = planner.initialState()
        planner.markRunning("start", in: &state)
        let older = WorkflowRun(workflow: workflow, experts: [], connectors: [], inputs: RunInputs(prNumber: 7),
                                state: state, status: .running, startedAt: Date(timeIntervalSinceNow: -60))
        let newer = WorkflowRun(workflow: workflow, experts: [], connectors: [],
                                inputs: RunInputs(prNumber: 8, jiraKey: "HS-1"), state: planner.initialState(),
                                status: .succeeded)
        try store.save(older)
        try store.save(newer)
        store.log("hello", run: newer.id)
        store.log("again", run: newer.id)
        let loaded = store.load()
        #expect(loaded.map(\.id) == [newer.id, older.id])
        #expect(loaded[1].status == .interrupted)
        #expect(loaded[1].state.status("start") == .failed)
        #expect(loaded[0].subject == "PR #8 · HS-1")
        let log = try String(contentsOf: store.folder(for: newer.id).appendingPathComponent("log.txt"), encoding: .utf8)
        #expect(log.contains("hello") && log.contains("again"))
        store.delete(older.id)
        #expect(store.load().count == 1)
    }

    @Test("the report embeds its data safely and carries the theme's colours")
    func artifact() {
        let palette = ArtifactPalette(brand: "#E22C22", link: "#0D6E74", radius: "16px; } body { x: y",
                                      logoSVG: #"<svg onload="alert(1)"><circle r="2"/></svg>"#)
        let html = ArtifactRenderer.html(template: "pr-review", title: "A <b>title</b>", palette: palette,
                                         data: .object(["title": .string("</script><script>alert(1)</script>")]))
        #expect(html.contains("--brand: #E22C22;"))
        #expect(html.contains("--link: #0D6E74;"))
        #expect(html.contains("--radius: 16px  body  x: y;"), "a token cannot leave its declaration")
        #expect(!html.contains("</script><script>alert(1)"), "data cannot close its script element")
        #expect(html.contains("<title>A &lt;b&gt;title&lt;/b&gt;</title>"))
        #expect(html.contains("<svg><circle r=\"2\"/></svg>"), "handlers are stripped from the logo")
        #expect(html.contains("fonts.googleapis.com"))
        let bad = ArtifactRenderer.html(template: "generic", title: "t",
                                        palette: ArtifactPalette(fontsURL: "https://evil.example/x.css"),
                                        data: .object([:]))
        #expect(!bad.contains("evil.example"), "only Google Fonts may be fetched")
        #expect(bad.contains("var TEMPLATE = \"generic\""))
        #expect(ArtifactRenderer.sanitizedSVG("<svg><script>x</script></svg>") == "")
        #expect(ArtifactRenderer.sanitizedSVG("<div></div>") == "")
    }

    @Test("the sample a theme is previewed on decodes, and finds its consolidated review")
    func sample() {
        #expect(ArtifactRenderer.sampleData["steps"]?["coherence"]?["verdict"] == .string("request_changes"))
        let html = ArtifactRenderer.html(template: "pr-review", title: "Aperçu", palette: ArtifactPalette(),
                                         data: ArtifactRenderer.sampleData)
        #expect(html.contains("Cache des contrats"))
    }
}
