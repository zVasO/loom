import LoomCore
import LoomPersistence
import LoomUI
import SwiftUI

/// The + button's sheet: which project — or which folder, registered as a
/// project on the spot — and whether the session gets a worktree of its own.
/// Nothing else: the goal is typed in the terminal, as always.
struct NewSessionSheet: View {
    let model: AppModel
    let onLaunch: (ProjectID, AppModel.LaunchPlacement) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: ProjectID?
    @State private var placement: AppModel.LaunchPlacement = .projectFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("PROJECT")
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.projects, id: \.id) { project in
                            projectRow(project)
                        }
                    }
                }
                .frame(maxHeight: 220)
                GhostButton("Choose a folder…", systemImage: "folder.badge.plus") {
                    // Any folder becomes a project: it joins the sidebar, and
                    // the session starts in it. An already-known folder is
                    // simply selected.
                    guard let url = AppModel.pickFolder(title: "Choose the folder to work in") else { return }
                    Task {
                        let id = await model.addProject(at: url)
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
                Spacer()
                AccentButton("Launch", systemImage: "play.fill") {
                    guard let projectID else { return }
                    onLaunch(projectID, model.isGitRepository(projectID) ? placement : .projectFolder)
                    dismiss()
                }
                .disabled(projectID == nil)
                .opacity(projectID == nil ? 0.5 : 1)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(DefaultTheme.background)
        .onAppear { select(model.selectedProject ?? model.projects.first?.id) }
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
    }
}
