import LoomAgents
import LoomCore
import LoomGit
import LoomPersistence
import LoomUI
import SwiftUI

/// The shared PR workspace: two regions that never compete for the same
/// scroll — Overview (identity, guided tour, description, conversation) and
/// Files (the diff, full-bleed) — over a docked verdict bar.
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
                if expanded {
                    // Full block rendering once opened; the collapsed teaser
                    // stays a 2-line inline Text (lineLimit can't span blocks).
                    MarkdownBlockView(text)
                        .textSelection(.enabled)
                } else {
                    Text(PRWorkspaceView.markdown(text))
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.primaryText.opacity(0.9))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { if isLong { expanded.toggle() } }
    }
}

/// Which region of the workspace is on screen. The diff is not a section of a
/// page any more: it is one of two regions, and it owns its own scroll.
enum PRPane: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"

    var id: String { rawValue }
}

struct PRWorkspaceView: View {
    let model: AppModel
    let project: ProjectRecord
    let pr: GitHubService.PullRequest
    let pane: PRPane
    /// How much of the right edge the session drawer covers. The diff scrolls
    /// under it; the controls step aside, or they would be unreachable.
    let controlsInset: CGFloat
    let onOpenSession: (SessionID) -> Void
    /// Phase 4 — receives the composed message for the PR's review session
    /// ("Explain these lines…", "Ask about…"). nil = quick actions still work
    /// through a session opened in the Sessions tab.
    var sendToSession: ((String) -> Void)?
    /// Review pane open: "Add to claude session" types the lines into the
    /// session's input (no submit — the user adds their question).
    var transcribeToSession: ((DiffSnippet) -> Void)?

    @State private var prDetail: GitHubService.PRDetail?
    /// Parsed + row-paired ONCE when the diff arrives (off the main thread) —
    /// parsing in `body` re-ran on every render and crawled on large PRs.
    @State private var diffFiles: [DiffFileRows] = []
    /// Review comments anchored to code — rendered inside the diff.
    @State private var lineComments: [GitHubService.ReviewComment] = []
    /// Why the diff is empty (API refusal, network…): shown instead of
    /// silently hiding the whole file explorer.
    @State private var diffError: String?
    @State private var diffLoading = false
    /// GitHub's "Viewed" boxes over the diff's files — the recap and the
    /// checkboxes read it; a toggle flips it before GitHub answers.
    @State private var progress = FileReviewProgress.empty
    /// Syntax colours, computed after the diff off the main thread: the
    /// diff paints plain first, then coloured.
    @State private var highlights = DiffHighlights.none
    @Environment(\.colorScheme) private var colorScheme
    @State private var prTour: PRTour?
    @State private var tourLoading = false
    @State private var reviewBody = ""
    @State private var prActionOutput: String?
    @State private var prActionBusy = false
    /// The comments drafted for this PR's review — mirrored from the model
    /// so the diff and the verdict bar read one value.
    @State private var draft: ReviewDraft?
    @State private var checksExpanded = false
    /// Diff layout, persisted: split (aligned old/new) or unified (one line
    /// per change, both gutters).
    @State private var unifiedDiff = UserDefaults.standard.bool(forKey: "loom.diff.unified")

    var body: some View {
        VStack(spacing: 0) {
            switch pane {
            case .overview: overviewPane
            case .files: filesPane
            }
            Divider().overlay(DefaultTheme.cardBorder)
            verdictBar
        }
        .background(DefaultTheme.background)
        .task(id: pr.number) {
            prDetail = nil
            diffFiles = []
            progress = .empty
            highlights = .none
            await load(refresh: false)
        }
    }

    // MARK: Overview — who, why, and what the conversation says

    private var overviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                identity
                tourSection(pr, project: project)
                if let detail = prDetail {
                    if !detail.body.isEmpty {
                        // Block-level rendering: headings, lists, quotes and
                        // fences as structure — not literal ## and -.
                        MarkdownBlockView(detail.body)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DefaultTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !detail.reviews.isEmpty || !detail.comments.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionHeader("CONVERSATION",
                                          count: detail.reviews.count + detail.comments.count,
                                          color: DefaultTheme.secondaryText)
                            ForEach(Array(detail.reviews.enumerated()), id: \.offset) { _, review in
                                conversationRow(
                                    author: review.author,
                                    chip: review.state
                                        .replacingOccurrences(of: "_", with: " ").lowercased(),
                                    body: review.body)
                            }
                            ForEach(Array(detail.comments.enumerated()), id: \.offset) { _, comment in
                                conversationRow(author: comment.author, chip: nil,
                                                body: comment.body)
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Who and where: author (GitHub avatar), head → base branches — then who
    /// it waits on, who owns it, how it is tagged, how big it is.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            authorLine
            peopleLine
            checksLine
        }
    }

    /// Every CI signal on the head: the recap on one line, each check with
    /// its state and link once unfolded. Nothing for a row cached before
    /// checks were kept.
    @ViewBuilder
    private var checksLine: some View {
        if !pr.checks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.hover) { checksExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: checksExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DefaultTheme.secondaryText)
                        Circle().fill(PRChips.checksColor(pr)).frame(width: 7, height: 7)
                        Text(pr.checks.count == 1 ? "1 check" : "\(pr.checks.count) checks")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DefaultTheme.primaryText)
                        Text(PRChips.checksSummary(pr))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if checksExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pr.checks) { check in
                            checkRow(check)
                        }
                    }
                    .padding(8)
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func checkRow(_ check: GitHubService.Check) -> some View {
        let (symbol, color): (String, Color) = switch check.state {
        case .success: ("checkmark.circle.fill", DefaultTheme.groupHeader)
        case .failure: ("xmark.circle.fill", DefaultTheme.danger)
        case .pending: ("circle.dotted", DefaultTheme.badgeColor(for: .needsInput))
        case .skipped, .cancelled, .neutral: ("minus.circle", DefaultTheme.mutedText)
        }
        return HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
                .frame(width: 14)
            Text(check.name.isEmpty ? "(unnamed)" : check.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if !check.workflow.isEmpty {
                Text(check.workflow)
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
            }
            Text(check.state.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Spacer()
            if let url = URL(string: check.link), !check.link.isEmpty {
                HoverIconButton(systemImage: "arrow.up.forward.square", help: "Open the run") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Reviewers with their last verdict, assignees, labels, size, conflicts.
    @ViewBuilder
    private var peopleLine: some View {
        let verdicts = Dictionary(pr.latestReviews.map { ($0.author, $0.state) },
                                  uniquingKeysWith: { _, last in last })
        // Everyone involved in the review: still requested, or already spoke.
        let reviewers = pr.reviewers + pr.latestReviews.map(\.author)
            .filter { !pr.reviewers.contains($0) }
        if !reviewers.isEmpty || !pr.assignees.isEmpty || !pr.labels.isEmpty
            || pr.changedFiles > 0 || pr.isConflicting {
            HStack(spacing: 12) {
                if !reviewers.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2").font(.system(size: 10))
                            .foregroundStyle(DefaultTheme.secondaryText)
                        ForEach(reviewers, id: \.self) { reviewer in
                            reviewerChip(reviewer, verdict: verdicts[reviewer])
                        }
                    }
                }
                if !pr.assignees.isEmpty {
                    Label(pr.assignees.map { "@" + $0 }.joined(separator: ", "),
                          systemImage: "person.crop.circle")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .lineLimit(1)
                        .help("Assigned")
                }
                ForEach(pr.labels, id: \.name) { PRChips.label($0) }
                if pr.changedFiles > 0 {
                    HStack(spacing: 6) {
                        PRChips.size(pr)
                        Text(pr.changedFiles == 1 ? "1 file" : "\(pr.changedFiles) files")
                            .font(.system(size: 10))
                            .foregroundStyle(DefaultTheme.mutedText)
                    }
                }
                if pr.isConflicting {
                    Label("Conflicts with \(pr.baseBranch.isEmpty ? "base" : pr.baseBranch)",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DefaultTheme.danger)
                }
                Spacer()
            }
        }
    }

    /// ✓ approved, ✗ changes requested, ○ still to review — per person.
    private func reviewerChip(_ reviewer: String, verdict: String?) -> some View {
        let (symbol, color): (String, Color) = switch verdict ?? "" {
        case "APPROVED": ("checkmark.circle.fill", DefaultTheme.groupHeader)
        case "CHANGES_REQUESTED": ("xmark.circle.fill", DefaultTheme.danger)
        case "COMMENTED": ("text.bubble", DefaultTheme.secondaryText)
        default: ("circle.dotted", DefaultTheme.mutedText)
        }
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color)
            Text(reviewer.hasPrefix("team/") ? reviewer : "@" + reviewer)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DefaultTheme.primaryText)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(DefaultTheme.surfaceRaised, in: Capsule())
        .help(verdict.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }
              ?? "review requested")
    }

    private var authorLine: some View {
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
    }

    // MARK: Files — the diff, and nothing else

    private var filesPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                sectionHeader("FILES", count: diffFiles.count,
                              color: DefaultTheme.secondaryText)
                if diffLoading { ProgressView().controlSize(.mini) }
                if progress.total > 0 {
                    // The recap: how much of the PR has been checked off,
                    // GitHub's own boxes behind it.
                    HStack(spacing: 6) {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 90)
                            .tint(progress.isComplete ? DefaultTheme.groupHeader : DefaultTheme.accent)
                        Text(progress.label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(progress.isComplete ? DefaultTheme.groupHeader
                                                                 : DefaultTheme.secondaryText)
                    }
                    .help("Files marked as viewed — the same checkboxes as on github.com")
                }
                Spacer()
                // Split keeps old/new aligned; unified gives every line the
                // full width. Long lines wrap either way.
                HoverIconButton(systemImage: unifiedDiff
                                    ? "rectangle.split.2x1" : "list.bullet.rectangle",
                                help: unifiedDiff ? "Split view (old | new)"
                                                  : "Unified view (full-width lines)") {
                    unifiedDiff.toggle()
                    UserDefaults.standard.set(unifiedDiff, forKey: "loom.diff.unified")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .padding(.trailing, controlsInset)
            Divider().overlay(DefaultTheme.cardBorder)
            if diffFiles.isEmpty {
                diffPlaceholder
            } else {
                ScrollView {
                    // GitHub-style side-by-side: old on the left, new on the
                    // right, aligned and tinted, per-file collapsible sections.
                    SplitDiffView(files: diffFiles,
                                  onExplain: { snippet in
                                      deliver("""
                                      Explain these lines (\(snippet.label)):
                                      ```diff
                                      \(snippet.code)
                                      ```
                                      """)
                                  },
                                  onAsk: { snippet, question in
                                      deliver("""
                                      About these lines (\(snippet.label)): \(question)
                                      ```diff
                                      \(snippet.code)
                                      ```
                                      """)
                                  },
                                  onAddToSession: transcribeToSession,
                                  onComment: { snippet, text, isSuggestion in
                                      postLineComment(snippet, text: text,
                                                      isSuggestion: isSuggestion)
                                  },
                                  onFileComment: { path, text in
                                      prActionBusy = true
                                      Task {
                                          let error = await model.commentOnFile(
                                              pr.number, path: path, note: text,
                                              in: project.id)
                                          prActionOutput = error ?? "Comment posted ✓"
                                          if error == nil { await load(refresh: true) }
                                          prActionBusy = false
                                      }
                                  },
                                  comments: lineComments,
                                  onDraftComment: { snippet, text, isSuggestion in
                                      addDraft(snippet, text: text, isSuggestion: isSuggestion)
                                  },
                                  drafts: draft?.comments ?? [],
                                  onRemoveDraft: { id in
                                      model.removeDraftComment(id, for: pr.number, in: project.id)
                                      draft = model.reviewDraft(for: pr.number, in: project.id)
                                  },
                                  onReply: { commentID, text in
                                      prActionBusy = true
                                      Task {
                                          let error = await model.replyToReviewComment(
                                              pr.number, commentID: commentID,
                                              body: text, in: project.id)
                                          prActionOutput = error ?? "Reply posted ✓"
                                          if error == nil { await load(refresh: true) }
                                          prActionBusy = false
                                      }
                                  },
                                  unified: unifiedDiff,
                                  highlights: highlights,
                                  viewed: progress.viewed,
                                  changedSinceViewed: progress.changedSinceViewed,
                                  onToggleViewed: { path, on in
                                      // Optimistic: the box flips now, GitHub is
                                      // told after; a refusal puts it back.
                                      let previous = progress
                                      progress = progress.toggling(path, viewed: on)
                                      Task {
                                          if let error = await model.setFileViewed(
                                              pr.number, path: path, viewed: on, in: project.id) {
                                              progress = previous
                                              prActionOutput = error
                                          }
                                      }
                                  })
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        // Identity tied to the PR: SwiftUI would otherwise
                        // reuse the view and carry a selection (and collapsed
                        // files, and the bar's position) over to the next PR.
                        .id(pr.number)
                }
            }
        }
    }

    /// The explorer never vanishes silently: loading shows a spinner, failure
    /// shows the reason and a way to retry.
    private var diffPlaceholder: some View {
        HStack(spacing: 8) {
            if diffLoading {
                ProgressView().controlSize(.small)
                Text("Loading the diff…")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.danger)
                Text(diffError ?? "This PR has no diff.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .textSelection(.enabled)
                GhostButton("Retry", systemImage: "arrow.clockwise") {
                    Task { await load(refresh: true) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: The verdict — docked, so it is never a scroll away

    private var verdictBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let draft, !draft.isEmpty {
                pendingStrip(draft)
            }
            HStack(spacing: 8) {
                TextField(draft?.isEmpty == false ? "Review summary (optional)…" : "Review comment…",
                          text: $reviewBody, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...4)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(DefaultTheme.cardBorder, lineWidth: 1))
                AccentButton("Approve") { submitReview(pr, .approve, project) }
                GhostButton("Request changes", systemImage: "exclamationmark.bubble") {
                    submitReview(pr, .requestChanges, project)
                }
                GhostButton("Comment", systemImage: "bubble.left") {
                    submitReview(pr, .comment, project)
                }
                if prActionBusy { ProgressView().controlSize(.small) }
            }
            if let prActionOutput {
                Text(prActionOutput)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(prActionOutput.hasSuffix("✓") ? DefaultTheme.groupHeader
                                                                   : DefaultTheme.secondaryText)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .padding(.trailing, controlsInset)
        // Background after the inset: the strip still spans the window, only
        // its contents step out from under the drawer.
        .background(DefaultTheme.background)
    }

    /// What the verdict will carry: how many drafted comments, a way to drop
    /// them all, and a warning when the head moved under them.
    private func pendingStrip(_ draft: ReviewDraft) -> some View {
        let pending = DefaultTheme.badgeColor(for: .needsInput)
        let count = draft.comments.count
        return HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 10)).foregroundStyle(pending)
            Text(count == 1 ? "1 pending comment" : "\(count) pending comments")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            Text("— sent together with your verdict, as one review")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
            if !pr.headSHA.isEmpty, draft.headSHA != pr.headSHA {
                Label("written against an older head — line numbers may have moved",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(pending)
            }
            Spacer()
            GhostButton("Discard", systemImage: "trash", role: .destructive) {
                model.discardDraft(for: pr.number, in: project.id)
                self.draft = nil
            }
        }
    }

    /// Keeps a line comment (or suggestion) for the review.
    private func addDraft(_ snippet: DiffSnippet, text: String, isSuggestion: Bool) {
        let body = GitHubService.lineCommentBody(isSuggestion ? "" : text,
                                                 suggestion: isSuggestion ? text : nil)
        let comment = DraftComment(path: snippet.file, firstLine: snippet.firstLine,
                                   lastLine: snippet.lastLine,
                                   side: snippet.spans.first?.side ?? "RIGHT", body: body)
        model.addDraftComment(comment, headSHA: pr.headSHA, for: pr.number, in: project.id)
        draft = model.reviewDraft(for: pr.number, in: project.id)
        let count = draft?.comments.count ?? 1
        prActionOutput = "Added to your review — \(count) pending ✓"
    }

    // MARK: Loading and actions

    /// Detail + diff (cached in the model unless refresh), then the heavy
    /// parse/pair work off the main thread.
    private func load(refresh: Bool) async {
        diffLoading = true
        draft = model.reviewDraft(for: pr.number, in: project.id)
        prDetail = await model.prDetail(pr.number, in: project.id, refresh: refresh)
        lineComments = await model.reviewComments(pr.number, in: project.id, refresh: refresh)
        let result = await model.prDiff(pr.number, baseBranch: pr.baseBranch,
                                        in: project.id, refresh: refresh)
        diffError = result.error
        let diff = result.diff
        let parsed = await Task.detached(priority: .userInitiated) {
            DiffParser.parse(diff)
        }.value
        diffFiles = await Task.detached(priority: .userInitiated) {
            DiffFileRows.compute(parsed)
        }.value
        diffLoading = false
        // Colours come last, at lower priority: the diff is readable plain,
        // and highlight.js over a big PR takes a moment.
        let dark = colorScheme == .dark
        let number = pr.number
        let coloured = await Task.detached(priority: .utility) {
            DiffHighlighter.highlight(parsed, dark: dark)
        }.value
        if pr.number == number { highlights = coloured }
        // GitHub's viewed boxes, after the diff: the files on screen are the
        // universe the recap counts.
        let views = await model.fileViews(pr.number, in: project.id, refresh: refresh)
        progress = FileReviewProgress.compute(paths: diffFiles.map(\.file.path),
                                              views: views?.files ?? [])
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

    private func submitReview(_ pr: GitHubService.PullRequest,
                              _ verdict: GitHubService.Verdict,
                              _ project: ProjectRecord) {
        let hasDrafts = draft?.isEmpty == false
        // A verdict needs something to say — unless the drafts say it.
        if verdict != .approve, !hasDrafts,
           reviewBody.trimmingCharacters(in: .whitespaces).isEmpty {
            prActionOutput = "Write the comment first."
            return
        }
        prActionBusy = true
        Task {
            let error = await model.submitPRReview(pr.number, verdict: verdict,
                                                   body: reviewBody, in: project.id)
            prActionOutput = error ?? (hasDrafts ? "Review sent with its comments ✓" : "Review sent ✓")
            if error == nil {
                reviewBody = ""
                draft = nil
                // After a submission the cached conversation is stale.
                await load(refresh: true)
            }
            prActionBusy = false
        }
    }

    /// Posts the selection's comment on GitHub, anchored to its real lines.
    private func postLineComment(_ snippet: DiffSnippet, text: String, isSuggestion: Bool) {
        prActionBusy = true
        Task {
            let error = await model.commentOnLines(
                pr.number, path: snippet.file,
                firstLine: snippet.firstLine, lastLine: snippet.lastLine,
                note: isSuggestion ? "" : text,
                suggestion: isSuggestion ? text : nil,
                side: snippet.spans.first?.side ?? "RIGHT",
                in: project.id)
            prActionOutput = error ?? (isSuggestion ? "Suggestion posted ✓" : "Comment posted ✓")
            if error == nil { await load(refresh: true) }
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
