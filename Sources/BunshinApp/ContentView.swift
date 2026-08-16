import BunshinCore
import BunshinGit
import BunshinTerminal
import BunshinUI
import BunshinWeb
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var selected: SessionID?
    @State private var prompt = ""
    @State private var directory = FileManager.default.homeDirectoryForCurrentUser
    @State private var browserShown = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Actives") {
                    ForEach(model.sessions) { item in
                        SessionCardView(title: item.title, state: item.state, preview: "")
                            .tag(item.id)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button("Archiver") { Task { await model.archiveSession(item.id) } }
                            }
                    }
                }
                if !model.interruptedSessions.isEmpty {
                    Section("Interrompues") {
                        ForEach(model.interruptedSessions, id: \.id) { record in
                            HStack {
                                SessionCardView(title: record.title, state: record.state, preview: "")
                                Button("Reprendre") {
                                    Task { await model.resumeSession(record) }
                                }
                                .buttonStyle(.bordered)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                if !model.historySessions.isEmpty {
                    Section("Historique") {
                        ForEach(model.historySessions, id: \.id) { record in
                            SessionCardView(title: record.title, state: record.state, preview: "")
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    Button("Archiver") { Task { await model.archiveSession(record.id) } }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .safeAreaInset(edge: .bottom) { quickStart }
        } detail: {
            if let selected {
                SessionDetailView(model: model, sessionID: selected)
                    .id(selected)
            } else {
                Text("Choisis une session, ou lances-en une")
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
        .background(DefaultTheme.background)
        .toolbar {
            Button {
                browserShown.toggle()
            } label: {
                Label("Navigateur", systemImage: "globe")
            }
        }
        .sheet(isPresented: $browserShown) {
            BrowserPanelView(onVisit: { url, title in model.recordVisit(url: url, title: title) })
                .frame(minWidth: 900, minHeight: 600)
        }
        .onAppear { model.start() }
        .alert("Démarrage incomplet", isPresented: .constant(model.startupError != nil)) {
            Button("OK") {}
        } message: {
            Text(model.startupError ?? "")
        }
    }

    /// UC-1 : un objectif, un dossier, une session.
    private var quickStart: some View {
        VStack(spacing: 6) {
            TextField("Décris la tâche…", text: $prompt)
                .textFieldStyle(.roundedBorder)
                .onSubmit { launch() }
            HStack {
                Button("Dossier…") { pickDirectory() }
                Text(directory.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .lineLimit(1)
                Spacer()
                Button("Lancer") { launch() }
                    .buttonStyle(.borderedProminent)
                    .tint(DefaultTheme.accent)
                    .disabled(prompt.isEmpty)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
    }

    private func launch() {
        guard !prompt.isEmpty else { return }
        let task = prompt
        prompt = ""
        Task { await model.launchSession(prompt: task, in: directory) }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
        }
    }
}

/// UC-3 : la vue terminal — attachée tant qu'affichée, la session survit au retour.
struct SessionDetailView: View {
    let model: AppModel
    let sessionID: SessionID
    @State private var surface: TerminalSurface?
    @State private var input = ""
    @State private var gitShown = false
    @State private var gitData: AppModel.GitPanelData?

    var body: some View {
        Group {
            if let surface {
                VStack(spacing: 0) {
                    HSplitView {
                        TerminalScreenView(screen: surface.screen)
                        if gitShown { gitPanel }
                    }
                    HStack {
                        TextField("Répondre à l'agent…", text: $input)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                surface.send(input + "\r")
                                input = ""
                            }
                        Button(gitShown ? "Masquer Git" : "Git") {
                            gitShown.toggle()
                            if gitShown { Task { gitData = await model.gitPanel(for: sessionID) } }
                        }
                        Button("Stop", role: .destructive) {
                            Task { await model.stopSession(sessionID) }
                        }
                    }
                    .padding(8)
                }
                .task { await surface.attached() }
            } else {
                ProgressView()
            }
        }
        .task { surface = await model.surface(for: sessionID) }
        .background(DefaultTheme.background)
    }

    /// GIT-03 : panneau latéral lecture seule — fichiers modifiés + diff unifié.
    private var gitPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Modifications").font(.headline)
                Spacer()
                Button {
                    Task { gitData = await model.gitPanel(for: sessionID) }
                } label: { Image(systemName: "arrow.clockwise") }
            }
            if let gitData {
                if gitData.changes.isEmpty {
                    Text("Worktree propre").foregroundStyle(DefaultTheme.secondaryText)
                } else {
                    ForEach(gitData.changes, id: \.path) { change in
                        Label(change.path, systemImage: symbol(for: change.kind))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                    ScrollView {
                        Text(gitData.diff)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Pas de worktree pour cette session")
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
            Spacer()
        }
        .padding(10)
        .frame(minWidth: 280, maxWidth: 420)
        .background(DefaultTheme.surface)
    }

    private func symbol(for kind: FileChange.Kind) -> String {
        switch kind {
        case .modified: "pencil"
        case .added: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .untracked: "questionmark"
        }
    }
}
