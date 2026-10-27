import LoomAgents
import LoomCore
import LoomGit
import LoomUI
import SwiftUI

// MARK: - Settings

/// Settings › Scheduled reviews: when the app reviews on its own, which
/// PRs, how many at once, and what it asks claude.
struct ScheduledReviewsSettings: View {
    let model: AppModel
    @State private var promptDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SCHEDULED REVIEWS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DefaultTheme.secondaryText)
            VStack(alignment: .leading, spacing: 12) {
                Text("At the time you choose, Loom opens a tab for each pull request a schedule picks, starts its review session (/\(PRReviewCommand.name) first, when it is on), then asks claude for the full review. Claude's summary lands in the verdict bar and its line comments in the pending review: you read, edit, and submit. A PR is reviewed again only once someone pushed to it. Loom has to be open — a run slept through starts on wake, up to four hours late.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                ForEach(model.reviewSchedules.schedules) { schedule in
                    ReviewScheduleEditor(model: model, scheduleID: schedule.id)
                    Divider().overlay(DefaultTheme.cardBorder)
                }
                HStack(spacing: 12) {
                    GhostButton("Add a schedule", systemImage: "plus") { model.addReviewSchedule() }
                        .disabled(model.projects.isEmpty)
                    Spacer()
                    Stepper(value: Binding(get: { model.reviewSchedules.maxConcurrent },
                                           set: { model.setAutoReviewConcurrency($0) }),
                            in: 1...ReviewScheduleState.maxConcurrency) {
                        Text("\(model.reviewSchedules.maxConcurrent) at a time")
                            .font(.system(size: 12))
                            .foregroundStyle(DefaultTheme.primaryText)
                    }
                    .fixedSize()
                    .help("Reviews running at once — each one is a claude session at work")
                }
                if model.projects.isEmpty {
                    Text("Add a project first: a schedule reviews the pull requests of your projects.")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                Text("A review that stops on a permission prompt or a question waits for you; the others go on. To keep runs unattended, allow the read-only commands a review uses (gh pr view, gh pr diff, gh api) in your Claude Code settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Divider().overlay(DefaultTheme.cardBorder)
                HStack {
                    Text("Review prompt")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                    Spacer()
                    if promptDraft != AutoReviewPrompt.defaultTemplate {
                        GhostButton("Reset to default", systemImage: "arrow.counterclockwise") {
                            promptDraft = AutoReviewPrompt.defaultTemplate
                        }
                    }
                }
                TextEditor(text: $promptDraft)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 200)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
                    .onAppear { promptDraft = model.autoReviewPromptTemplate ?? AutoReviewPrompt.defaultTemplate }
                    .onChange(of: promptDraft) { _, draft in model.autoReviewPromptTemplate = draft }
                Text("Typed into the review session once the PR is loaded. Placeholders: \(AutoReviewPrompt.placeholders.joined(separator: ", ")). Keep the report part: it is what Loom imports — {{report}} is where claude writes it.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                if !model.reviewSchedules.reviewedHeads.isEmpty {
                    HStack {
                        Text(model.reviewSchedules.reviewedHeads.count == 1
                             ? "1 pull request reviewed at its current head"
                             : "\(model.reviewSchedules.reviewedHeads.count) pull requests reviewed at their current head")
                            .font(.system(size: 12))
                            .foregroundStyle(DefaultTheme.primaryText)
                        Spacer()
                        GhostButton("Review them again", systemImage: "arrow.counterclockwise") {
                            model.forgetAutoReviewedHeads()
                        }
                        .help("The next runs review these PRs again, even with no new push")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        }
    }
}

/// One schedule: name, on/off, time, days, and its slices of PRs.
private struct ReviewScheduleEditor: View {
    let model: AppModel
    let scheduleID: UUID

    /// Read from the model at every render: the edits go through it.
    private var schedule: ReviewSchedule? {
        model.reviewSchedules.schedules.first { $0.id == scheduleID }
    }

    /// Monday first.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        if let schedule {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Toggle("", isOn: field(\.enabled, of: schedule)).labelsHidden().toggleStyle(.switch)
                    TextField("Name", text: field(\.name, of: schedule))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                    Spacer()
                    GhostButton("Run now", systemImage: "play") { model.runReviewScheduleNow(schedule.id) }
                        .disabled(model.autoReviewRun?.isRunning == true || schedule.targets.isEmpty)
                        .help(model.autoReviewRun?.isRunning == true ? "A run is already going on"
                              : "Review the PRs this schedule picks, now")
                    HoverIconButton(systemImage: "trash", help: "Delete this schedule") {
                        model.removeReviewSchedule(schedule.id)
                    }
                }
                HStack(spacing: 10) {
                    DatePicker("", selection: time(of: schedule), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                    HStack(spacing: 4) {
                        ForEach(Self.weekdayOrder, id: \.self) { day in
                            dayChip(day, in: schedule)
                        }
                    }
                    Spacer()
                    Text(nextRunText(schedule))
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                ForEach(schedule.targets) { target in
                    targetRow(target, in: schedule)
                }
                GhostButton("Add pull requests from a project", systemImage: "plus") {
                    guard let projectID = model.selectedProject ?? model.projects.first?.id else { return }
                    var updated = schedule
                    updated.targets.append(ReviewScheduleTarget(projectID: projectID))
                    model.updateReviewSchedule(updated)
                }
                .disabled(model.projects.isEmpty)
            }
            .opacity(schedule.enabled ? 1 : 0.6)
        }
    }

    private func field<T>(_ keyPath: WritableKeyPath<ReviewSchedule, T>, of schedule: ReviewSchedule) -> Binding<T> {
        Binding(get: { (self.schedule ?? schedule)[keyPath: keyPath] },
                set: { value in
                    guard var updated = self.schedule else { return }
                    updated[keyPath: keyPath] = value
                    model.updateReviewSchedule(updated)
                })
    }

    private func time(of schedule: ReviewSchedule) -> Binding<Date> {
        Binding(get: {
                    let current = self.schedule ?? schedule
                    return Calendar.current.date(bySettingHour: current.hour, minute: current.minute,
                                                 second: 0, of: Date()) ?? Date()
                },
                set: { date in
                    guard var updated = self.schedule else { return }
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    updated.hour = parts.hour ?? updated.hour
                    updated.minute = parts.minute ?? updated.minute
                    model.updateReviewSchedule(updated)
                })
    }

    private func dayChip(_ day: Int, in schedule: ReviewSchedule) -> some View {
        let on = schedule.weekdays.contains(day)
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let label = symbols.indices.contains(day - 1) ? symbols[day - 1] : "\(day)"
        return Button {
            var updated = schedule
            if on { updated.weekdays.remove(day) } else { updated.weekdays.insert(day) }
            model.updateReviewSchedule(updated)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(on ? DefaultTheme.accentText : DefaultTheme.secondaryText)
                .background(on ? DefaultTheme.accent : DefaultTheme.surfaceRaised, in: Circle())
        }
        .buttonStyle(.plain)
        .help(Calendar.current.weekdaySymbols.indices.contains(day - 1)
              ? Calendar.current.weekdaySymbols[day - 1] : "")
    }

    private func nextRunText(_ schedule: ReviewSchedule) -> String {
        guard schedule.enabled else { return "Off" }
        guard !schedule.targets.isEmpty else { return "No pull requests chosen" }
        guard let next = schedule.nextOccurrence(after: Date()) else { return "No day chosen" }
        return "Next: " + next.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // MARK: Slices

    private func targetRow(_ target: ReviewScheduleTarget, in schedule: ReviewSchedule) -> some View {
        let error = target.query.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : PRFilter.validate(name: "slice", query: target.query)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: targetField(target.id, \.projectID, fallback: target.projectID, in: schedule)) {
                    ForEach(model.projects, id: \.id) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                TextField("GitHub search — empty: every open PR",
                          text: targetField(target.id, \.query, fallback: target.query, in: schedule))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Menu {
                    ForEach(model.prFilters) { filter in
                        Button(filter.name) {
                            setTarget(target.id, in: schedule) { $0.query = filter.query }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Take a PR filter's query")
                Stepper(value: targetField(target.id, \.limit, fallback: target.limit, in: schedule),
                        in: 1...ReviewScheduleTarget.maxLimit) {
                    Text("max \(target.limit)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                .fixedSize()
                .help("At most this many PRs from this project per run")
                HoverIconButton(systemImage: "xmark", help: "Remove these pull requests from the schedule") {
                    guard var updated = self.schedule else { return }
                    updated.targets.removeAll { $0.id == target.id }
                    model.updateReviewSchedule(updated)
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.danger)
            }
        }
    }

    private func setTarget(_ id: UUID, in schedule: ReviewSchedule,
                           _ change: (inout ReviewScheduleTarget) -> Void) {
        guard var updated = self.schedule,
              let index = updated.targets.firstIndex(where: { $0.id == id }) else { return }
        change(&updated.targets[index])
        model.updateReviewSchedule(updated)
    }

    private func targetField<T>(_ id: UUID, _ keyPath: WritableKeyPath<ReviewScheduleTarget, T>,
                                fallback: T, in schedule: ReviewSchedule) -> Binding<T> {
        Binding(get: {
                    self.schedule?.targets.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
                },
                set: { value in
                    setTarget(id, in: schedule) { $0[keyPath: keyPath] = value }
                })
    }
}

// MARK: - PRs sidebar

/// The PRs sidebar's "SCHEDULED REVIEWS": the run going on (or the last
/// one), a row per PR with where its review stands, and "Run now".
struct ScheduledReviewsSidebarSection: View {
    let model: AppModel
    /// The PR tab on screen, for the selected row.
    let activeTabID: String?
    @AppStorage("loom.pr.autoReviewsFolded") private var folded = false

    var body: some View {
        if !model.reviewSchedules.schedules.isEmpty || model.autoReviewRun != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.hover) { folded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(folded ? -90 : 0))
                            Image(systemName: "calendar.badge.clock").font(.system(size: 9, weight: .semibold))
                            Text("SCHEDULED REVIEWS")
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(0.8)
                        }
                        .foregroundStyle(DefaultTheme.groupHeader)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(folded ? "Unfold" : "Fold")
                    Spacer()
                    if model.autoReviewRun?.isRunning == true {
                        ProgressView().controlSize(.mini)
                    } else if !model.reviewSchedules.schedules.isEmpty {
                        Menu {
                            ForEach(model.reviewSchedules.schedules) { schedule in
                                Button(schedule.name) { model.runReviewScheduleNow(schedule.id) }
                                    .disabled(schedule.targets.isEmpty)
                            }
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Run a schedule now")
                    }
                }
                .padding(.horizontal, 2)
                if !folded {
                    if let run = model.autoReviewRun {
                        Text(runCaption(run))
                            .font(.system(size: 10))
                            .foregroundStyle(DefaultTheme.mutedText)
                            .padding(.leading, 2)
                        ForEach(run.errors, id: \.self) { error in
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(DefaultTheme.danger)
                                .textSelection(.enabled)
                        }
                        ForEach(run.items) { item in
                            AutoReviewRow(item: item, isSelected: item.id == activeTabID) {
                                if model.prTabs.contains(item.id) {
                                    model.activatePRTab(item.id)
                                } else {
                                    model.openPRTab(item.pr, in: item.projectID)
                                }
                            }
                        }
                    }
                    if let next = model.nextAutoReviewDate() {
                        Text("Next run " + next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.system(size: 10))
                            .foregroundStyle(DefaultTheme.mutedText)
                            .padding(.leading, 2)
                    }
                }
            }
        }
    }

    private func runCaption(_ run: AutoReviewRun) -> String {
        let start = run.startedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        var parts = ["\(run.scheduleName) · \(start)"]
        if run.items.isEmpty && run.errors.isEmpty && !run.isRunning {
            parts.append("nothing new to review")
        }
        if run.skipped > 0 {
            parts.append(run.skipped == 1 ? "1 already reviewed" : "\(run.skipped) already reviewed")
        }
        return parts.joined(separator: " · ")
    }
}

/// One PR of a run: number, title, and where its review stands.
private struct AutoReviewRow: View {
    let item: AutoReviewRun.Item
    let isSelected: Bool
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        let described = Self.describe(item.status)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: described.symbol)
                .font(.system(size: 11))
                .foregroundStyle(described.color)
                .frame(width: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(item.pr.number)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(DefaultTheme.accent)
                    Text(item.pr.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                        .lineLimit(1)
                }
                Text(described.text)
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(isSelected ? DefaultTheme.surfaceRaised
                    : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : DefaultTheme.surface,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }

    static func describe(_ status: AutoReviewRun.Status) -> (symbol: String, color: Color, text: String) {
        switch status {
        case .queued:
            return ("clock", DefaultTheme.mutedText, "Queued")
        case .preparing:
            return ("hourglass", DefaultTheme.badgeColor(for: .starting), "Preparing the review session…")
        case .reviewing:
            return ("sparkles", DefaultTheme.badgeColor(for: .working), "Claude is reviewing…")
        case .waitingOnYou:
            return ("exclamationmark.bubble", DefaultTheme.badgeColor(for: .needsInput),
                    "Waiting on you — answer it in the drawer")
        case .ready(let verdict, let comments, let inSummary):
            let label = AutoReviewReport.Verdict(rawValue: verdict)?.label ?? verdict
            var text = "Ready · suggests \(label)"
            if comments > 0 { text += comments == 1 ? " · 1 comment" : " · \(comments) comments" }
            if inSummary > 0 { text += " · \(inSummary) in the summary" }
            return ("checkmark.circle.fill", DefaultTheme.groupHeader, text)
        case .noReport:
            return ("text.bubble", DefaultTheme.secondaryText, "Done — its review is in the conversation")
        case .failed(let reason):
            return ("xmark.octagon", DefaultTheme.danger, reason)
        }
    }
}
