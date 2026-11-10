import AppKit
import LoomAPI
import LoomCore
import LoomUI
import LoomWorkflows
import SwiftUI

// What the Workflows tab draws natively since ADR-0021: the templates to
// start from, and a run as a list — every step in the order the run reaches
// it, with its state, its verdict and its answer, and what the run leaves
// behind (a branch, its changes, a report). The graph stays one click away.

// MARK: - Small pieces

/// A caption in mono capitals, as the rest of the tab writes its section titles.
@MainActor
private func caption(_ text: String, color: Color? = nil) -> some View {
    Text(text.uppercased())
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .kerning(0.53)
        .foregroundStyle(color ?? DefaultTheme.mutedText)
        .lineLimit(1)
}

/// How a workspace reads on a card: where a run works, what it leaves.
@MainActor
struct WorkspaceTag: View {
    let workspace: Workspace

    var body: some View {
        switch workspace {
        case .worktree:
            MonoTag("its own branch", systemImage: "arrow.triangle.branch")
                .help("A run makes a worktree on a loom/… branch and works there: your folder is left alone")
        case .project:
            MonoTag("reads the project", systemImage: "eye", color: DefaultTheme.secondaryText)
                .help("A run reads the project's folder, or a pull request's read-only checkout")
        }
    }
}

// MARK: - Gallery

/// The templates Loom offers (ADR-0021): each a workflow ready to run. The
/// library starts empty; picking one copies it there, where it is the
/// person's to edit.
struct WorkflowGalleryView: View {
    let model: AppModel
    /// Adds the template to the library and opens the Run sheet on it.
    let onRun: (WorkflowTemplate) -> Void
    /// Adds the template to the library and opens it in the editor.
    let onCustomize: (WorkflowTemplate) -> Void
    let onImport: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workflows")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(DefaultTheme.primaryText)
                    Text("Give a task, get it done in steps: agents that plan, write, check each other, and stop where you decide. Start from one of these — each becomes yours to change.")
                        .font(.system(size: 13))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(WorkflowTemplates.all) { template in
                        TemplateCard(template: template,
                                     inLibrary: model.workflows.workflows.contains { $0.name == template.name },
                                     onRun: { onRun(template) }, onCustomize: { onCustomize(template) })
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    caption("Or build your own")
                    HStack(spacing: 10) {
                        GhostButton("✦ Create with AI", systemImage: nil) { Task { await model.startWorkflowBuilder() } }
                            .help("A session asks what the workflow is for, then builds it: you validate what it proposes")
                        GhostButton("Blank workflow", systemImage: "plus") {
                            model.workflows.createWorkflow()
                            model.workflows.detail = .workflow
                        }
                        GhostButton("Import…", systemImage: "square.and.arrow.down", action: onImport)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct TemplateCard: View {
    let template: WorkflowTemplate
    let inLibrary: Bool
    let onRun: () -> Void
    let onCustomize: () -> Void
    @State private var hovered = false

    var body: some View {
        // Built once per body: a template's workflow is a value, cheap to make.
        let bundle = template.bundle()
        let outline = WorkflowOutline(bundle.workflow, experts: bundle.experts)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AppIcon(template.icon, size: 16)
                    .foregroundStyle(AppModel.color(hex: bundle.workflow.color))
                Text(template.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer(minLength: 6)
                WorkspaceTag(workspace: bundle.workflow.workspace)
            }
            Text(template.tagline)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DefaultTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(template.highlights.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("·").foregroundStyle(DefaultTheme.mutedText)
                        Text(line)
                            .foregroundStyle(DefaultTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11.5))
                }
            }
            Text(outline.oneLine)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(DefaultTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                AccentButton("Run…", systemImage: "play.fill", action: onRun)
                GhostButton(inLibrary ? "Open" : "Customize", systemImage: "slider.horizontal.3", action: onCustomize)
                    .help(inLibrary ? "Already in your library: open it in the editor"
                          : "Copy it into your library and open it in the editor")
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(hovered ? DefaultTheme.line3 : DefaultTheme.cardBorder, lineWidth: 1))
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}

// MARK: - A run, as a list

/// A watched run: what it leaves (its branch and changes, its report), then
/// its steps in order — state, pass, verdict, time — each opening on its
/// answer. Redrawn as the run moves.
struct RunTimelineView: View {
    let model: AppModel
    let run: WorkflowRun
    /// Steps whose answer is unfolded; the last settled one opens by itself.
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<String> = []

    private var outline: WorkflowOutline {
        WorkflowOutline(run.workflow, experts: run.experts, blocks: run.blocks)
    }

    var body: some View {
        let steps = outline.steps
        let latest = latestSettled(steps)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !run.inputs.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        caption("Task")
                        Text(run.inputs.task.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 13))
                            .foregroundStyle(DefaultTheme.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if run.worktree != nil {
                    RunOutcomeCard(model: model, run: run)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        RunStepRow(model: model, run: run, step: step,
                                   isOpen: isOpen(step.id, latest: latest),
                                   isLast: index == steps.count - 1) {
                            toggle(step.id, latest: latest)
                        }
                    }
                }
                .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder, lineWidth: 1))
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// The step that answered or failed last: its answer is what the person
    /// came to read.
    private func latestSettled(_ steps: [WorkflowOutline.Step]) -> String? {
        steps.compactMap { step -> (String, Date)? in
            guard let record = run.state.nodes[step.id], record.status == .done || record.status == .failed,
                  step.type != .artifact, let end = record.finishedAt else { return nil }
            return (step.id, end)
        }
        .max { $0.1 < $1.1 }?.0
    }

    private func isOpen(_ id: String, latest: String?) -> Bool {
        if expanded.contains(id) { return true }
        return id == latest && !collapsed.contains(id)
    }

    private func toggle(_ id: String, latest: String?) {
        if isOpen(id, latest: latest) {
            expanded.remove(id)
            collapsed.insert(id)
        } else {
            collapsed.remove(id)
            expanded.insert(id)
        }
    }
}

/// What a run on its own branch leaves: the branch, how much changed, and
/// the ways to take it from there.
private struct RunOutcomeCard: View {
    let model: AppModel
    let run: WorkflowRun
    @State private var opening = false
    @State private var copied = false

    var body: some View {
        if let worktree = run.worktree {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    caption(run.status.isActive ? "Working on" : "Left on")
                    MonoTag(worktree.branch, systemImage: "arrow.triangle.branch")
                    if let changes = run.changes {
                        Text(changes.summary)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(changes.isEmpty ? DefaultTheme.mutedText : DefaultTheme.primaryText)
                    } else if run.status.isActive {
                        Text("changes are counted when the run ends")
                            .font(.system(size: 11)).foregroundStyle(DefaultTheme.mutedText)
                    }
                    Spacer(minLength: 8)
                }
                if let changes = run.changes, !changes.paths.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(changes.paths.prefix(8), id: \.self) { path in
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DefaultTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if changes.files > 8 {
                            Text("… \(changes.files - 8) more")
                                .font(.system(size: 11)).foregroundStyle(DefaultTheme.mutedText)
                        }
                    }
                }
                HStack(spacing: 8) {
                    AccentButton(opening ? "Opening…" : "Open a session there", systemImage: "terminal") {
                        guard !opening else { return }
                        opening = true
                        Task {
                            if let id = await model.sessionInRunWorktree(run.id) {
                                model.workflows.sessionToOpen = id
                            }
                            opening = false
                        }
                    }
                    .help("Carry on by hand in the run's worktree: review the diff, commit, push, open a pull request")
                    GhostButton(copied ? "Copied" : "Copy the branch", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(worktree.branch, forType: .string)
                        copied = true
                    }
                    GhostButton("Reveal", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
                    }
                    .help(worktree.path)
                    Spacer()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder, lineWidth: 1))
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        }
    }
}

/// One step of a run: a line that says where it stands, and its answer under it.
private struct RunStepRow: View {
    let model: AppModel
    let run: WorkflowRun
    let step: WorkflowOutline.Step
    let isOpen: Bool
    let isLast: Bool
    let onToggle: () -> Void
    @State private var hovered = false

    private var record: NodeRecord { run.state.nodes[step.id] ?? NodeRecord() }

    /// The pass the step is in: one more than the answers it already gave.
    private var pass: Int { (run.state.history[step.id]?.count ?? 0) + 1 }

    private var verdict: String? {
        guard record.status == .done else { return nil }
        return record.output?["verdict"]?.plainText
    }

    private var answer: String? {
        switch record.status {
        case .failed, .skipped: return record.error
        case .done: return record.text
        case .pending, .running, .waitingOnUser: return nil
        }
    }

    private var sessionID: SessionID? {
        let raw = record.sessionID ?? run.state.conversations[step.id]?.sessionID
        return raw.flatMap(UUID.init(uuidString:)).map(SessionID.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                statusIcon.frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(record.status == .pending || record.status == .skipped
                                         ? DefaultTheme.secondaryText : DefaultTheme.primaryText)
                        .lineLimit(1)
                    caption(kindLine)
                }
                Spacer(minLength: 10)
                if let verdict, !verdict.isEmpty {
                    StatusTag(verdict, color: verdictColor(verdict), dot: false)
                }
                if pass > 1 {
                    caption("pass \(pass)", color: DefaultTheme.secondaryText)
                }
                if let duration {
                    Text(duration)
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                if let cost = record.costUSD, cost > 0 {
                    Text(String(format: "%.2f $", cost))
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                if let sessionID {
                    // A running step whose session asks something waits on the
                    // person, not on claude: say so where the run is watched.
                    if record.status == .running,
                       model.sessions.first(where: { $0.id == sessionID })?.state == .needsInput {
                        StatusTag("waits for you", color: DefaultTheme.badgeColor(for: .needsInput))
                    }
                    GhostButton("Session", systemImage: "terminal") { model.workflows.sessionToOpen = sessionID }
                        .help("Open this step's session in Sessions: follow it, answer it, take over")
                }
                if answer != nil {
                    AppIcon(isOpen ? "chevron.down" : "chevron.right", size: 11)
                        .foregroundStyle(DefaultTheme.mutedText)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(hovered && answer != nil ? DefaultTheme.wash : .clear)
            .contentShape(Rectangle())
            .onTapGesture { if answer != nil { onToggle() } }
            .onHover { hovered = $0 }
            if isOpen, let text = answer, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(record.status == .failed ? DefaultTheme.danger : DefaultTheme.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .frame(maxHeight: 340)
                .background(DefaultTheme.contentBackground)
                .overlay(alignment: .top) { Rectangle().fill(DefaultTheme.line).frame(height: 1) }
            }
            if !isLast { Rectangle().fill(DefaultTheme.line).frame(height: 1) }
        }
    }

    /// "AGENT · Développeur · session", "APPROVAL · your decision", "↺ à revoir → Plan ≤2×".
    private var kindLine: String {
        var parts: [String] = [step.type == .forEach ? "for each" : step.type.rawValue]
        if let expert = step.expert { parts.append(expert) }
        if step.visible { parts.append("session") }
        if let target = step.continues, target != step.id {
            parts.append("continues \(run.workflow.node(target)?.title ?? target)")
        }
        if record.status == .waitingOnUser { parts.append("your decision") }
        parts += step.retries
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .pending:
            Circle().strokeBorder(DefaultTheme.line3, lineWidth: 1.5).frame(width: 12, height: 12)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .waitingOnUser:
            Image(systemName: "hand.raised.fill").font(.system(size: 12))
                .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                .foregroundStyle(DefaultTheme.badgeColor(for: .idle))
        case .failed:
            Image(systemName: "xmark.octagon.fill").font(.system(size: 13)).foregroundStyle(DefaultTheme.danger)
        case .skipped:
            Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(DefaultTheme.mutedText)
        }
    }

    /// The first option of a verdict is its best: the others ask for something.
    private func verdictColor(_ verdict: String) -> Color {
        guard let best = step.verdicts.first else { return DefaultTheme.secondaryText }
        return VerdictConfig.same(best, verdict) ? DefaultTheme.badgeColor(for: .idle)
            : DefaultTheme.badgeColor(for: .needsInput)
    }

    private var duration: String? {
        guard let start = record.startedAt, let end = record.finishedAt else { return nil }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}
