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
        VStack(alignment: .leading, spacing: DefaultTheme.space(4)) {
            HStack(spacing: DefaultTheme.space(6)) {
                AsyncImage(url: URL(string: "https://github.com/\(author).png?size=48")) { image in
                    image.resizable()
                } placeholder: {
                    Circle().fill(DefaultTheme.surfaceRaised)
                }
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                Text("@" + author)
                    .themeFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(DefaultTheme.branch)
                if let chip, !chip.isEmpty {
                    Text(chip)
                        .themeFont(size: 9, weight: .semibold)
                        .foregroundStyle(chip.contains("changes") ? DefaultTheme.danger
                                                                  : DefaultTheme.secondaryText)
                        .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(1))
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
                        .themeFont(size: 12)
                        .foregroundStyle(DefaultTheme.primaryText.opacity(0.9))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .padding(DefaultTheme.space(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
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

struct PRWorkspaceView: View, Equatable {
    let model: AppModel
    let project: ProjectRecord
    let pr: GitHubService.PullRequest
    let pane: PRPane
    /// The session drawer's width, kept by the PRs tab. Handed on to the two
    /// bars whose controls must stay clear of the drawer, and read by them
    /// alone: the diff scrolls under the drawer, and a drawer dragged or
    /// slid re-runs two bars, not this view.
    let drawerLayout: PRDrawerLayout
    /// The drawer shows a session that runs: "Add to claude session" has an
    /// input to type into.
    let transcribes: Bool
    let onOpenSession: (SessionID) -> Void
    /// Phase 4 — receives the composed message for the PR's review session
    /// ("Explain these lines…", "Ask about…"). nil = quick actions still work
    /// through a session opened in the Sessions tab.
    var sendToSession: ((String) -> Void)?
    /// "Add to claude session" types the lines into the session's input (no
    /// submit — the user adds their question). Offered while `transcribes`.
    var transcribeToSession: ((DiffSnippet) -> Void)?

    /// What the workspace SHOWS decides whether it re-runs; its closures
    /// act on the same PR either way. Its parent runs again at every write
    /// to the tabs (a summary saved, a drawer toggled, a row refreshed) and
    /// whenever a session appears or goes: the diff used to run again with
    /// it each time (audit 2026-11-15).
    static func == (lhs: PRWorkspaceView, rhs: PRWorkspaceView) -> Bool {
        lhs.project.id == rhs.project.id && lhs.pr == rhs.pr && lhs.pane == rhs.pane
            && lhs.transcribes == rhs.transcribes
    }

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
    /// Syntax colours per scheme (dark: true), computed after the diff off
    /// the main thread: the diff paints plain first, then coloured. Both
    /// palettes are kept, so an appearance flip never paints light colours
    /// on a dark background while the other scheme computes.
    @State private var highlights: [Bool: DiffHighlights] = [:]
    @Environment(\.colorScheme) private var colorScheme
    /// The PR the state below was reset for: the load task is also keyed on
    /// the scheme, and a scheme flip must not blank the detail.
    @State private var loadedNumber: Int?
    @State private var prTour: PRTour?
    @State private var tourLoading = false
    @State private var prActionOutput: String?
    @State private var prActionBusy = false
    /// The comments drafted for this PR's review — mirrored from the model
    /// so the diff and the verdict bar read one value.
    @State private var draft: ReviewDraft?
    @State private var checksExpanded = false
    /// Diff layout, persisted: split (aligned old/new) or unified (one line
    /// per change, both gutters).
    @State private var unifiedDiff = UserDefaults.standard.bool(forKey: "loom.diff.unified")

    /// Seeded from what the model already holds for the PR: a revisit
    /// paints its rows, coloured, with their threads under their lines, the
    /// viewed files folded and the description in place — in the first
    /// frame. The loads below then only confirm. Every read here is of
    /// state the model does not observe: an init runs inside the parent's
    /// body, and would subscribe it.
    init(model: AppModel, project: ProjectRecord, pr: GitHubService.PullRequest, pane: PRPane,
         drawerLayout: PRDrawerLayout, transcribes: Bool = false,
         onOpenSession: @escaping (SessionID) -> Void,
         sendToSession: ((String) -> Void)? = nil,
         transcribeToSession: ((DiffSnippet) -> Void)? = nil) {
        self.model = model
        self.project = project
        self.pr = pr
        self.pane = pane
        self.drawerLayout = drawerLayout
        self.transcribes = transcribes
        self.onOpenSession = onOpenSession
        self.sendToSession = sendToSession
        self.transcribeToSession = transcribeToSession
        let cached = model.cachedDiff(pr: pr.number, in: project.id)
        let files: [DiffFileRows] = cached?.files ?? []
        _diffFiles = State(initialValue: files)
        _highlights = State(initialValue: cached?.highlights ?? [:])
        _prTour = State(initialValue: model.cachedTour(pr: pr.number, in: project.id))
        _prDetail = State(initialValue: model.cachedDetail(pr: pr.number, in: project.id))
        _lineComments = State(initialValue: model.cachedReviewComments(pr: pr.number,
                                                                       in: project.id) ?? [])
        _draft = State(initialValue: model.reviewDraft(for: pr.number, in: project.id))
        // The recap counts the files on screen: without rows there is no
        // universe to count the viewed ones in.
        if !files.isEmpty, let views = model.cachedFileViews(pr: pr.number, in: project.id) {
            _progress = State(initialValue: FileReviewProgress.compute(
                paths: files.map(\.file.path), views: views.files))
        }
        // The seeds are this PR's: the first load must not blank them.
        _loadedNumber = State<Int?>(initialValue: pr.number)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch pane {
            case .overview: overviewPane
            case .files: filesPane
            }
            Divider().overlay(DefaultTheme.cardBorder)
            PRVerdictBar(model: model, projectID: project.id, pr: pr, draft: draft,
                         busy: prActionBusy, output: prActionOutput,
                         drawerLayout: drawerLayout,
                         onDiscardDraft: {
                             model.discardDraft(for: pr.number, in: project.id)
                             draft = nil
                         },
                         onSubmit: { verdict, summary in
                             submitReview(verdict, summary: summary)
                         })
        }
        .background(DefaultTheme.background)
        // The head, the update stamp and the refresh button's generation
        // are in the id: a PR that moved on GitHub, or a manual refresh (the
        // model dropped its caches either way), reloads on the spot.
        .task(id: "\(pr.number)#\(pr.headSHA)#\(pr.updatedAt)#\(model.prReloadGeneration(pr.number, in: project.id))#\(colorScheme == .dark)") {
            if loadedNumber != pr.number {
                loadedNumber = pr.number
                prDetail = nil
                progress = .empty
                if model.cachedDiff(pr: pr.number, in: project.id) == nil {
                    diffFiles = []
                    highlights = [:]
                }
            }
            // A scheme flip lands here too: the detail, comments, diff and
            // rows are cache hits, only the missing palette computes.
            await load(refresh: false)
        }
    }

    // MARK: Overview — who, why, and what the conversation says

    private var overviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DefaultTheme.space(16)) {
                identity
                tourSection(pr, project: project)
                if let detail = prDetail {
                    if !detail.body.isEmpty {
                        // Block-level rendering: headings, lists, quotes and
                        // fences as structure — not literal ## and -.
                        MarkdownBlockView(detail.body)
                            .textSelection(.enabled)
                            .padding(DefaultTheme.space(12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DefaultTheme.surface,
                                        in: RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
                            .themeShadow(.sm, radius: 10)
                    }
                    if !detail.reviews.isEmpty || !detail.comments.isEmpty {
                        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
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
            .padding(DefaultTheme.space(20))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Who and where: author (GitHub avatar), head → base branches — then who
    /// it waits on, who owns it, how it is tagged, how big it is.
    private var identity: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(8)) {
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
            VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
                Button {
                    withAnimation(.hover) { checksExpanded.toggle() }
                } label: {
                    HStack(spacing: DefaultTheme.space(6)) {
                        Image(systemName: checksExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DefaultTheme.secondaryText)
                        Circle().fill(PRChips.checksColor(pr)).frame(width: 7, height: 7)
                        Text(pr.checks.count == 1 ? "1 check" : "\(pr.checks.count) checks")
                            .themeFont(size: 11, weight: .semibold)
                            .foregroundStyle(DefaultTheme.primaryText)
                        Text(PRChips.checksSummary(pr))
                            .themeFont(size: 10, design: .monospaced)
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if checksExpanded {
                    VStack(alignment: .leading, spacing: DefaultTheme.space(2)) {
                        ForEach(pr.checks) { check in
                            checkRow(check)
                        }
                    }
                    .padding(DefaultTheme.space(8))
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
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
        return HStack(spacing: DefaultTheme.space(8)) {
            AppIcon(symbol, size: 13).foregroundStyle(color)
                .frame(width: 14)
            Text(check.name.isEmpty ? "(unnamed)" : check.name)
                .themeFont(size: 11, weight: .medium)
                .foregroundStyle(DefaultTheme.primaryText)
                .lineLimit(1)
            if !check.workflow.isEmpty {
                Text(check.workflow)
                    .themeFont(size: 10)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .lineLimit(1)
            }
            Text(check.state.rawValue)
                .themeFont(size: 9, weight: .semibold)
                .foregroundStyle(color)
            Spacer()
            if let url = URL(string: check.link), !check.link.isEmpty {
                HoverIconButton(systemImage: "arrow.up.forward.square", help: "Open the run") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.vertical, DefaultTheme.space(2))
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
            HStack(spacing: DefaultTheme.space(12)) {
                if !reviewers.isEmpty {
                    HStack(spacing: DefaultTheme.space(6)) {
                        AppIcon("person.2", size: 12)
                            .foregroundStyle(DefaultTheme.secondaryText)
                        ForEach(reviewers, id: \.self) { reviewer in
                            reviewerChip(reviewer, verdict: verdicts[reviewer])
                        }
                    }
                }
                if !pr.assignees.isEmpty {
                    Label(pr.assignees.map { "@" + $0 }.joined(separator: ", "),
                          systemImage: "person.crop.circle")
                        .themeFont(size: 10, design: .monospaced)
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .lineLimit(1)
                        .help("Assigned")
                }
                ForEach(pr.labels, id: \.name) { PRChips.label($0) }
                if pr.changedFiles > 0 {
                    HStack(spacing: DefaultTheme.space(6)) {
                        PRChips.size(pr)
                        Text(pr.changedFiles == 1 ? "1 file" : "\(pr.changedFiles) files")
                            .themeFont(size: 10)
                            .foregroundStyle(DefaultTheme.mutedText)
                    }
                }
                if pr.isConflicting {
                    Label("Conflicts with \(pr.baseBranch.isEmpty ? "base" : pr.baseBranch)",
                          systemImage: "exclamationmark.triangle")
                        .themeFont(size: 10, weight: .semibold)
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
        return HStack(spacing: DefaultTheme.space(4)) {
            AppIcon(symbol, size: 12).foregroundStyle(color)
            Text(reviewer.hasPrefix("team/") ? reviewer : "@" + reviewer)
                .themeFont(size: 10, design: .monospaced)
                .foregroundStyle(DefaultTheme.primaryText)
        }
        .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(2))
        .background(DefaultTheme.surfaceRaised, in: Capsule())
        .help(verdict.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }
              ?? "review requested")
    }

    private var authorLine: some View {
        HStack(spacing: DefaultTheme.space(10)) {
            AsyncImage(url: URL(string: "https://github.com/\(pr.author).png?size=80")) { image in
                image.resizable()
            } placeholder: {
                Circle().fill(DefaultTheme.surfaceRaised)
            }
            .frame(width: DefaultTheme.size(26), height: DefaultTheme.size(26))
            .clipShape(Circle())
            .overlay(Circle().stroke(DefaultTheme.cardBorder, lineWidth: 1))
            Text("@" + pr.author)
                .themeFont(size: 12, weight: .semibold, design: .monospaced)
                .foregroundStyle(DefaultTheme.branch)
            Text("wants to merge")
                .themeFont(size: 11)
                .foregroundStyle(DefaultTheme.secondaryText)
            MonoTag(pr.branch, systemImage: "arrow.triangle.branch")
            AppIcon("arrow.right", size: 11)
                .foregroundStyle(DefaultTheme.mutedText)
            MonoTag(pr.baseBranch.isEmpty ? "main" : pr.baseBranch,
                    systemImage: "arrow.triangle.branch",
                    color: DefaultTheme.secondaryText)
            if pr.isDraft {
                Text("draft")
                    .themeFont(size: 9, weight: .semibold)
                    .foregroundStyle(DefaultTheme.mutedText)
                    .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(2))
                    .background(DefaultTheme.surfaceRaised, in: Capsule())
            }
            Spacer()
        }
    }

    // MARK: Files — the diff, and nothing else

    private var filesPane: some View {
        VStack(spacing: 0) {
            // The header's controls step out from under the drawer; the
            // wrapper reads the drawer's width so that this view does not.
            PRDrawerClearance(model: model, projectID: project.id, number: pr.number,
                              layout: drawerLayout) {
                HStack(spacing: DefaultTheme.space(10)) {
                    sectionHeader("FILES", count: diffFiles.count,
                                  color: DefaultTheme.secondaryText)
                    if diffLoading { ProgressView().controlSize(.mini) }
                    if progress.total > 0 {
                        // The recap: how much of the PR has been checked off,
                        // GitHub's own boxes behind it.
                        HStack(spacing: DefaultTheme.space(6)) {
                            ProgressView(value: progress.fraction)
                                .progressViewStyle(.linear)
                                .frame(width: 90)
                                .tint(progress.isComplete ? DefaultTheme.groupHeader : DefaultTheme.accent)
                            Text(progress.label)
                                .themeFont(size: 10, weight: .medium, design: .monospaced)
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
                .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(6))
            }
            Divider().overlay(DefaultTheme.cardBorder)
            if diffFiles.isEmpty {
                diffPlaceholder
            } else {
                ScrollView {
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
                                  onAddToSession: transcribes ? transcribeToSession : nil,
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
                                  onDraftComment: { snippet, text, isSuggestion in
                                      addDraft(snippet, text: text, isSuggestion: isSuggestion)
                                  },
                                  drafts: draft?.comments ?? [],
                                  onRemoveDraft: { id in
                                      model.removeDraftComment(id, for: pr.number, in: project.id)
                                      draft = model.reviewDraft(for: pr.number, in: project.id)
                                  },
                                  unified: unifiedDiff,
                                  highlights: highlights[colorScheme == .dark] ?? DiffHighlights.none,
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
                        .padding(.horizontal, DefaultTheme.space(12))
                        .padding(.vertical, DefaultTheme.space(10))
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
        HStack(spacing: DefaultTheme.space(8)) {
            if diffLoading {
                ProgressView().controlSize(.small)
                Text("Loading the diff…")
                    .themeFont(size: 11)
                    .foregroundStyle(DefaultTheme.secondaryText)
            } else {
                AppIcon("exclamationmark.triangle", size: 13)
                    .foregroundStyle(DefaultTheme.danger)
                Text(diffError ?? "This PR has no diff.")
                    .themeFont(size: 11)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .textSelection(.enabled)
                GhostButton("Retry", systemImage: "arrow.clockwise") {
                    Task { await load(refresh: true) }
                }
            }
        }
        .padding(DefaultTheme.space(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    /// One piece of the PR, as it lands (see `load`).
    private enum Landed: Sendable {
        case detail(GitHubService.PRDetail?)
        case comments([GitHubService.ReviewComment])
        /// The diff's text, and why there is none when it is empty.
        case diff(String, String?)
        case rows(DiffPipeline.Rows)
        case colours(DiffHighlights)
        case fileViews(GitHubService.FileViews?)
    }

    /// Detail, comments, diff and viewed files (cached in the model unless
    /// refresh), asked for TOGETHER and shown each as it lands: the first
    /// diff is the slowest of four `gh` calls away, where it used to be
    /// their sum. The heavy parse/pair work stays off the main thread.
    /// A run its task dropped (the PR moved, the scheme flipped) writes
    /// nothing more: the run that replaced it does, and joins the calls
    /// this one left running.
    private func load(refresh: Bool) async {
        // What the calls below need, as values: they run off this view.
        let model = self.model
        let number = pr.number
        let projectID = project.id
        let baseBranch = pr.baseBranch
        let dark = colorScheme == .dark
        diffLoading = true
        let drafted = model.reviewDraft(for: number, in: projectID)
        if draft != drafted { draft = drafted }
        await withTaskGroup(of: Landed.self) { group in
            group.addTask {
                let detail = await model.prDetail(number, in: projectID, refresh: refresh)
                return Landed.detail(detail)
            }
            group.addTask {
                let comments = await model.reviewComments(number, in: projectID, refresh: refresh)
                return Landed.comments(comments)
            }
            group.addTask {
                let result = await model.prDiff(number, baseBranch: baseBranch,
                                                in: projectID, refresh: refresh)
                return Landed.diff(result.diff, result.error)
            }
            group.addTask {
                let fetched = await model.fileViews(number, in: projectID, refresh: refresh)
                return Landed.fileViews(fetched)
            }
            // GitHub's viewed boxes are counted over the files on screen:
            // the recap waits for both the rows and the boxes.
            var paths: [String]?
            var views: GitHubService.FileViews?
            var viewsLanded = false
            while let landed = await group.next() {
                guard !Task.isCancelled else { break }
                switch landed {
                case .detail(let detail):
                    if prDetail != detail { prDetail = detail }
                case .comments(let comments):
                    if lineComments != comments { lineComments = comments }
                case .diff(let diff, let error):
                    if diffError != error { diffError = error }
                    // Parsed, paired and coloured once per diff, in the
                    // model's pipeline: a revisit is a cache hit, not a
                    // "Loading the diff…".
                    group.addTask {
                        let parsed = await model.diffRows(pr: number, in: projectID, diff: diff)
                        return Landed.rows(parsed)
                    }
                case .rows(let rows):
                    if diffFiles != rows.files { diffFiles = rows.files }
                    diffLoading = false
                    paths = rows.files.map(\.file.path)
                    // Colours come last: the diff is readable plain, and
                    // highlight.js over a big PR takes a moment.
                    group.addTask {
                        let coloured = await model.diffHighlights(pr: number, in: projectID,
                                                                  rows: rows, dark: dark)
                        return Landed.colours(coloured)
                    }
                case .colours(let coloured):
                    if highlights[dark] != coloured { highlights[dark] = coloured }
                case .fileViews(let landedViews):
                    views = landedViews
                    viewsLanded = true
                }
                if viewsLanded, let paths {
                    let counted = FileReviewProgress.compute(paths: paths,
                                                             views: views?.files ?? [])
                    if progress != counted { progress = counted }
                }
            }
        }
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
        HStack(spacing: DefaultTheme.space(8)) {
            Text(title)
                .themeFont(size: 10.5, weight: .medium, design: .monospaced, kerning: 0.53)
                .foregroundStyle(DefaultTheme.secondaryText)
            Text("\(count)")
                .themeFont(size: 10, weight: .semibold, design: .monospaced)
                .foregroundStyle(color)
                .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(1))
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: DefaultTheme.radius(4)))
        }
    }

    /// `summary`: the verdict bar's text as typed — the bar owns it.
    private func submitReview(_ verdict: GitHubService.Verdict, summary: String) {
        let hasDrafts = draft?.isEmpty == false
        // GitHub's API refuses REQUEST_CHANGES and COMMENT without a body,
        // drafted comments or not: the summary is the one thing to write.
        if verdict != .approve, summary.trimmingCharacters(in: .whitespaces).isEmpty {
            prActionOutput = hasDrafts ? "Write the review summary first — GitHub requires one with this verdict."
                                       : "Write the comment first."
            return
        }
        prActionBusy = true
        Task {
            let error = await model.submitPRReview(pr.number, verdict: verdict,
                                                   body: summary, in: project.id)
            prActionOutput = error ?? (hasDrafts ? "Review sent with its comments ✓" : "Review sent ✓")
            if error == nil {
                // Emptied in the tab: the verdict bar follows what it holds.
                model.setPRTabSummary("", for: PRTab.key(project.id, pr.number))
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
            HStack(spacing: DefaultTheme.space(8)) {
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

// MARK: - The verdict — docked, so it is never a scroll away

/// The verdict bar under the workspace: what the review will carry, its
/// summary, the three verdicts.
/// The summary is this view's own text. It used to be written into the
/// PR's tab at every keystroke, and the tabs are read by the whole PRs tab:
/// each character re-ran the toolbar, the tab strip, the workspace and the
/// diff (audit 2026-11-15). It reaches the tab at a pause in the typing,
/// when a verdict is sent and when the bar leaves the screen.
struct PRVerdictBar: View {
    let model: AppModel
    let projectID: ProjectID
    let pr: GitHubService.PullRequest
    /// The comments drafted for this PR's review — the workspace's copy.
    let draft: ReviewDraft?
    let busy: Bool
    /// What the last action answered: "Review sent ✓", or GitHub's refusal.
    let output: String?
    let drawerLayout: PRDrawerLayout
    let onDiscardDraft: () -> Void
    /// A verdict was picked: the verdict, and the summary as typed.
    let onSubmit: (GitHubService.Verdict, String) -> Void

    /// What was typed here and may not be in the tab yet. nil: nothing was —
    /// the field shows the tab's summary, whoever wrote it.
    @State private var typed: String?

    private var tabID: String { PRTab.key(projectID, pr.number) }

    var body: some View {
        let tab: PRTab? = model.prTabs.tab(tabID)
        let stored: String = tab?.reviewSummary ?? ""
        VStack(alignment: .leading, spacing: DefaultTheme.space(6)) {
            if let raw = tab?.suggestedVerdict,
               let suggested = AutoReviewReport.Verdict(rawValue: raw) {
                Label("A scheduled review suggests: \(suggested.label) — the summary and the pending comments are claude's draft. Read, edit, then submit your verdict.",
                      systemImage: "sparkles")
                    .themeFont(size: 11)
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            if let draft, !draft.isEmpty {
                pendingStrip(draft)
            }
            HStack(spacing: DefaultTheme.space(8)) {
                TextField(draft?.isEmpty == false ? "Review summary…" : "Review comment…",
                          text: Binding(get: { typed ?? stored }, set: { typed = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .themeFont(size: 12)
                    .lineLimit(1...4)
                    .padding(.horizontal, DefaultTheme.space(10)).padding(.vertical, DefaultTheme.space(7))
                    .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                    .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6))
                        .stroke(DefaultTheme.fieldBorder, lineWidth: 1))
                    .themeShadow(.xs, radius: 6)
                    .onSubmit { writeSummary() }
                AccentButton("Approve") { submit(.approve, stored: stored) }
                GhostButton("Request changes", systemImage: "exclamationmark.bubble") {
                    submit(.requestChanges, stored: stored)
                }
                GhostButton("Comment", systemImage: "bubble.left") {
                    submit(.comment, stored: stored)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            if let output {
                Text(output)
                    .themeFont(size: 10, design: .monospaced)
                    .foregroundStyle(output.hasSuffix("✓") ? DefaultTheme.groupHeader
                                                           : DefaultTheme.secondaryText)
            }
        }
        .padding(.horizontal, DefaultTheme.space(14)).padding(.vertical, DefaultTheme.space(8))
        // The bar's controls step out from under the session drawer.
        .padding(.trailing, drawerLayout.covered(by: model, pr: pr.number, in: projectID))
        // Background after the inset: the strip still spans the window, only
        // its contents step out from under the drawer.
        .background(DefaultTheme.background)
        // Written at a pause, not at each character.
        .task(id: typed) {
            guard typed != nil else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            writeSummary()
        }
        .onChange(of: stored) { _, stored in
            guard let typed else { return }
            // Our own write, back from the tab — or the tab's summary
            // emptied: the review was sent, and the field empties whatever
            // was typed while it left. Either way the field follows the tab
            // again. Anything else is a scheduled review writing its summary
            // while keystrokes wait here: it only fills an empty summary,
            // this one is not — the typed text stays, and is written at the
            // next pause.
            if typed == stored || stored.isEmpty { self.typed = nil }
        }
        .onDisappear { writeSummary() }
    }

    /// Hands the typed text to the tab, where it follows the PR across the
    /// app's tabs and across relaunches.
    private func writeSummary() {
        guard let typed, let stored = model.prTabs.tab(tabID)?.reviewSummary,
              typed != stored else { return }
        model.setPRTabSummary(typed, for: tabID)
    }

    private func submit(_ verdict: GitHubService.Verdict, stored: String) {
        writeSummary()
        onSubmit(verdict, typed ?? stored)
    }

    /// What the verdict will carry: how many drafted comments, a way to drop
    /// them all, and a warning when the head moved under them.
    private func pendingStrip(_ draft: ReviewDraft) -> some View {
        let pending = DefaultTheme.badgeColor(for: .needsInput)
        let count = draft.comments.count
        return HStack(spacing: DefaultTheme.space(8)) {
            AppIcon("tray.and.arrow.down", size: 12).foregroundStyle(pending)
            Text(count == 1 ? "1 pending comment" : "\(count) pending comments")
                .themeFont(size: 11, weight: .semibold)
                .foregroundStyle(DefaultTheme.primaryText)
            Text("— sent together with your verdict, as one review")
                .themeFont(size: 11)
                .foregroundStyle(DefaultTheme.secondaryText)
            if !pr.headSHA.isEmpty, !draft.headSHA.isEmpty, draft.headSHA != pr.headSHA {
                Label("written against an older head — line numbers may have moved",
                      systemImage: "exclamationmark.triangle")
                    .themeFont(size: 10)
                    .foregroundStyle(pending)
            }
            Spacer()
            GhostButton("Discard", systemImage: "trash", role: .destructive) {
                onDiscardDraft()
            }
        }
    }
}
