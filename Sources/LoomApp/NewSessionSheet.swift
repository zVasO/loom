import LoomCore
import LoomPersistence
import LoomUI
import SwiftUI

/// The + button's sheet, and ⌘⇧N's: which project — found by typing, or a
/// folder registered as a project on the spot — and whether the session gets
/// a worktree of its own. Nothing else: the goal is typed in the terminal, as
/// always. The keyboard drives it: type to filter, ↑↓ to move, ↩ to launch,
/// Esc to leave.
struct NewSessionSheet: View {
    let model: AppModel
    let onLaunch: (ProjectID, AppModel.LaunchPlacement) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: ProjectID?
    @State private var placement: AppModel.LaunchPlacement = .projectFolder
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// The projects the query finds, best first; all of them, in the
    /// sidebar's order, while it is empty.
    private var matches: [ProjectRecord] {
        let projects = model.projects
        return CommandPalette.rankIndices(query: query,
                                          names: projects.map(\.name),
                                          details: projects.map(\.path))
            .map { projects[$0] }
    }

    var body: some View {
        let matches = self.matches
        VStack(alignment: .leading, spacing: 16) {
            Text("New session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("PROJECT")
                searchField(matches)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(matches, id: \.id) { project in
                                projectRow(project)
                                    .id(project.id)
                            }
                            if matches.isEmpty {
                                Text(model.projects.isEmpty
                                     ? "No project yet — choose a folder to start in."
                                     : "No project matches “\(query)”.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DefaultTheme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .onChange(of: projectID) {
                        guard let projectID else { return }
                        proxy.scrollTo(projectID, anchor: nil)
                    }
                }
                GhostButton("Choose a folder…", systemImage: "folder.badge.plus") {
                    // Any folder becomes a project: it joins the sidebar, and
                    // the session starts in it. An already-known folder is
                    // simply selected.
                    guard let url = AppModel.pickFolder(title: "Choose the folder to work in") else { return }
                    Task {
                        let id = await model.addProject(at: url)
                        query = ""
                        select(id)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("WHERE IT WORKS")
                Picker("", selection: $placement) {
                    Label("Project folder", systemImage: "folder").tag(AppModel.LaunchPlacement.projectFolder)
                    Label("New worktree", systemImage: "arrow.triangle.branch").tag(AppModel.LaunchPlacement.newWorktree)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.isGitRepository(projectID))
                Text(model.isGitRepository(projectID)
                     ? (placement == .newWorktree
                        ? "An isolated checkout on its own loom/<slug> branch — the project folder stays untouched."
                        : "The session works directly in the project folder, on its current branch.")
                     : "Not a git repository: the session works in the folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }

            HStack {
                GhostButton("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("↑↓ to choose · ↩ to launch")
                    .font(.system(size: 10))
                    .foregroundStyle(DefaultTheme.mutedText)
                AccentButton("Launch", systemImage: "play.fill") { launch() }
                    .disabled(projectID == nil)
                    .opacity(projectID == nil ? 0.5 : 1)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(DefaultTheme.background)
        .onAppear {
            select(model.selectedProject ?? model.projects.first?.id)
            searchFocused = true
        }
        // The selection follows the filter: the best match, unless the one
        // chosen is still among them.
        .onChange(of: query) {
            let found = self.matches
            if let projectID, found.contains(where: { $0.id == projectID }) { return }
            select(found.first?.id)
        }
    }

    private func searchField(_ matches: [ProjectRecord]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
            TextField("Search projects…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DefaultTheme.primaryText)
                .focused($searchFocused)
                .onSubmit { launch() }
                .onKeyPress(.upArrow) { move(-1, in: matches); return .handled }
                .onKeyPress(.downArrow) { move(1, in: matches); return .handled }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(searchFocused ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder, lineWidth: 1))
    }

    /// ↑↓ through the projects shown, stopping at either end.
    private func move(_ step: Int, in matches: [ProjectRecord]) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == projectID } ?? (step > 0 ? -1 : matches.count)
        let next = min(max(current + step, 0), matches.count - 1)
        select(matches[next].id)
    }

    private func launch() {
        guard let projectID else { return }
        onLaunch(projectID, model.isGitRepository(projectID) ? placement : .projectFolder)
        dismiss()
    }

    private func select(_ id: ProjectID?) {
        projectID = id
        placement = model.defaultPlacement(for: id)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(DefaultTheme.secondaryText)
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        let selected = project.id == projectID
        return Button {
            select(project.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? DefaultTheme.accent : DefaultTheme.mutedText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DefaultTheme.primaryText)
                    Text(project.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let branch = project.defaultBranch {
                    MonoTag(branch, systemImage: "arrow.triangle.branch", color: DefaultTheme.mutedText)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? DefaultTheme.surfaceRaised : DefaultTheme.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? DefaultTheme.accent.opacity(0.6) : DefaultTheme.cardBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A double click launches at once.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            select(project.id)
            launch()
        })
    }
}
