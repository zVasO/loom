import LoomAgents
import LoomCore
import LoomGit
import LoomPersistence
import LoomUI
import SwiftUI

/// The shared PR workspace: header, Overview (description, conversation,
/// guided tour, verdict) and Files (GitHub-style split diff). Used by the
/// project detail AND the global PRs tab — one implementation.
/// One comment/review of the conversation: collapsed to two lines when long,
/// chevron to expand — long threads stay scannable.
struct ConversationRow: View {
    let author: String
    let chip: String?
    let text: String
    @State private var expanded = false

    private var isLong: Bool { text.count > 220 || text.contains("\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AsyncImage(url: URL(string: "https://github.com/\(author).png?size=48")) { image in
                    image.resizable()
                } placeholder: {
                    Circle().fill(DefaultTheme.surfaceRaised)
                }
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                Text("@" + author)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.branch)
                if let chip, !chip.isEmpty {
                    Text(chip)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(chip.contains("changes") ? DefaultTheme.danger
                                                                  : DefaultTheme.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(DefaultTheme.surfaceRaised, in: Capsule())
                }
                Spacer()
                if isLong, !text.isEmpty {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
            }
            if !text.isEmpty {
                Text(PRWorkspaceView.markdown(text))
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.primaryText.opacity(0.9))
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { if isLong { expanded.toggle() } }
    }
}

struct PRWorkspaceView: View {
    let model: AppModel
    let project: ProjectRecord
    let pr: GitHubService.PullRequest
    var onBack: (() -> Void)?
    let onOpenSession: (SessionID) -> Void
    /// Phase 4 — receives the composed message for the PR's review session
    /// ("Explain these lines…", "Ask about…"). nil = quick actions still work
    /// through a session opened in the Sessions tab.
    var sendToSession: ((String) -> Void)?

    @State private var prDetail: GitHubService.PRDetail?
    /// Parsed + row-paired ONCE when the diff arrives (off the main thread) —
    /// parsing in `body` re-ran on every render and crawled on large PRs.
    @State private var diffFiles: [DiffFileRows] = []
    @State private var prTour: PRTour?
    @State private var tourLoading = false
    @State private var reviewBody = ""
    @State private var prActionOutput: String?
    @State private var prActionBusy = false

    var body: some View {
        ScrollView {
            prDetailView(pr, project: project)
                .frame(maxWidth: 900, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DefaultTheme.background)
        .task(id: pr.number) {
            prDetail = nil
            diffFiles = []
            await load(refresh: false)
        }
    }

    /// Detail + diff (cached in the model unless refresh), then the heavy
    /// parse/pair work off the main thread.
    private func load(refresh: Bool) async {
        prDetail = await model.prDetail(pr.number, in: project.id, refresh: refresh)
        let diff = await model.prDiff(pr.number, in: project.id, refresh: refresh)
        diffFiles = await Task.detached(priority: .userInitiated) {
            DiffFileRows.compute(DiffParser.parse(diff))
        }.value
    }

    /// Light markdown (bold, code, links) with line breaks preserved — a full
    /// block parser would flatten lists; this keeps PR descriptions readable.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func deliver(_ message: String) {
        if let sendToSession {
            sendToSession(message)
        } else {
            // Fallback (project tab): route through the review session and jump to it.
            Task {
                if let id = await model.sendToPRReviewSession(message, pr: pr, in: project.id) {
                    onOpenSession(id)
                }
            }
        }
    }

    private func loadPRDetail(_ pr: GitHubService.PullRequest, project: ProjectRecord) {
        // After a submission the cached conversation is stale: force a refetch.
        Task { await load(refresh: true) }
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.secondaryText)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func prDetailView(_ pr: GitHubService.PullRequest,
                              project: ProjectRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if let onBack {
                    HoverIconButton(systemImage: "arrow.left", help: "Back to the list") {
                        onBack()
                    }
                }
                Text("#\(pr.number)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.accent)
                Text(pr.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                GhostButton("GitHub", systemImage: "arrow.up.forward.square") {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                }
            }

            // Who and where: author (GitHub avatar), head → base branches.
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: "https://github.com/\(pr.author).png?size=80")) { image in
                    image.resizable()
                } placeholder: {
                    Circle().fill(DefaultTheme.surfaceRaised)
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                .overlay(Circle().stroke(DefaultTheme.cardBorder, lineWidth: 1))
                Text("@" + pr.author)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DefaultTheme.branch)
                Text("wants to merge")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                MonoTag(pr.branch, systemImage: "arrow.triangle.branch")
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DefaultTheme.mutedText)
                MonoTag(pr.baseBranch.isEmpty ? "main" : pr.baseBranch,
                        systemImage: "arrow.triangle.branch",
                        color: DefaultTheme.secondaryText)
                if pr.isDraft {
                    Text("draft")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DefaultTheme.surfaceRaised, in: Capsule())
                }
                Spacer()
            }

            // The playful part: the guided tour.
            tourSection(pr, project: project)

            if let detail = prDetail {
                if !detail.body.isEmpty {
                    Text(Self.markdown(detail.body))
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                if !detail.reviews.isEmpty || !detail.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("CONVERSATION",
                                      count: detail.reviews.count + detail.comments.count,
                                      color: DefaultTheme.secondaryText)
                        ForEach(Array(detail.reviews.enumerated()), id: \.offset) { _, review in
                            conversationRow(author: review.author,
                                            chip: review.state.replacingOccurrences(of: "_", with: " ").lowercased(),
                                            body: review.body)
                        }
                        ForEach(Array(detail.comments.enumerated()), id: \.offset) { _, comment in
                            conversationRow(author: comment.author, chip: nil, body: comment.body)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }

            if !diffFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("DIFF", count: diffFiles.count,
                                  color: DefaultTheme.secondaryText)
                    // GitHub-style side-by-side: old on the left, new on the
                    // right, aligned and tinted, per-file collapsible sections.
                    SplitDiffView(files: diffFiles,
                                  onExplain: { snippet in
                                      deliver("""
                                      Explain these lines from \(snippet.file) \
                                      (L\(snippet.firstLine)–L\(snippet.lastLine)):
                                      ```diff
                                      \(snippet.code)
                                      ```
                                      """)
                                  },
                                  onAsk: { snippet, question in
                                      deliver("""
                                      About these lines from \(snippet.file) \
                                      (L\(snippet.firstLine)–L\(snippet.lastLine)): \(question)
                                      ```diff
                                      \(snippet.code)
                                      ```
                                      """)
                                  })
                }
            }

            // Verdict bar.
            VStack(alignment: .leading, spacing: 8) {
                TextField("Review comment…", text: $reviewBody, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(2...5)
                    .padding(10)
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(DefaultTheme.cardBorder, lineWidth: 1))
                HStack(spacing: 8) {
                    AccentButton("Approve") { submitReview(pr, .approve, project) }
                    GhostButton("Request changes", systemImage: "exclamationmark.bubble") {
                        submitReview(pr, .requestChanges, project)
                    }
                    GhostButton("Comment", systemImage: "bubble.left") {
                        submitReview(pr, .comment, project)
                    }
                    if prActionBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let prActionOutput {
                    Text(prActionOutput)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(prActionOutput.hasSuffix("✓") ? DefaultTheme.groupHeader
                                                                       : DefaultTheme.secondaryText)
                }
            }
        }
    }

    private func submitReview(_ pr: GitHubService.PullRequest,
                              _ verdict: GitHubService.Verdict,
                              _ project: ProjectRecord) {
        if verdict != .approve, reviewBody.trimmingCharacters(in: .whitespaces).isEmpty {
            prActionOutput = "Write the comment first."
            return
        }
        prActionBusy = true
        Task {
            let error = await model.submitPRReview(pr.number, verdict: verdict,
                                                   body: reviewBody, in: project.id)
            prActionOutput = error ?? "Review sent ✓"
            if error == nil {
                reviewBody = ""
                loadPRDetail(pr, project: project)
            }
            prActionBusy = false
        }
    }

    private func conversationRow(author: String, chip: String?, body: String) -> some View {
        ConversationRow(author: author, chip: chip, text: body)
    }

    @ViewBuilder
    private func tourSection(_ pr: GitHubService.PullRequest,
                             project: ProjectRecord) -> some View {
        if let tour = prTour {
            PRTourView(tour: tour) {
                Task {
                    if let id = await model.askGuide(about: pr.number, title: pr.title,
                                                     tour: tour, in: project.id) {
                        onOpenSession(id)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                GhostButton(tourLoading ? "The guide is reading the PR…" : "Explain this PR",
                            systemImage: "sparkles") {
                    guard !tourLoading else { return }
                    tourLoading = true
                    Task {
                        prTour = await model.generateTour(pr.number, in: project.id)
                        if prTour == nil { prActionOutput = "The guide could not read this PR." }
                        tourLoading = false
                    }
                }
                if tourLoading { ProgressView().controlSize(.small) }
            }
        }
    }

}
