import AppKit
import LoomUI
import LoomWorkflows
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Theme, for documents (ADR-0017): a theme's look in a
/// workflow's report — fonts, radius, logo, extra CSS — with the report
/// previewed in it. And a theme file to import (docs/themes/homeserve.json).
struct ThemeDocumentSettings: View {
    @State private var familyName = ""
    @State private var draft = ThemeDocumentStyle()
    @State private var dark = false
    @State private var previewURL: URL?
    @State private var message: String?

    private var store: ThemeStore { ThemeStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reports")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                GhostButton("Import a theme file…", systemImage: "doc.badge.plus") { importFile() }
            }
            Text("A workflow's report wears a Loom theme: its colours by role — the accent for links and buttons, the group headers' colour for the brand's accent, the content background for the header band. A theme of your own also sets the report's fonts, corner radius and logo here.")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(DefaultTheme.secondaryText)
            }
            if store.customFamilies.isEmpty {
                Text("No theme of your own yet: import one from tweakcn or from a file (docs/themes/homeserve.json is ready).")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.mutedText)
            } else {
                HStack {
                    Picker("Theme", selection: $familyName) {
                        ForEach(store.customFamilies) { Text($0.name).tag($0.name) }
                    }
                    .fixedSize()
                    Toggle("Dark variant", isOn: $dark).toggleStyle(.checkbox)
                    Spacer()
                    GhostButton("Preview the report", systemImage: "eye") { preview() }
                    AccentButton("Save") { save() }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    row("Text font", text: binding(\.fontSans), placeholder: ArtifactPalette.defaultSans)
                    row("Code font", text: binding(\.fontMono), placeholder: ArtifactPalette.defaultMono)
                    row("Fonts stylesheet", text: binding(\.fontsURL), placeholder: "https://fonts.googleapis.com/css2?family=…")
                    row("Corner radius", text: binding(\.radius), placeholder: "16px")
                }
                if let url = draft.fontsURL, !url.isEmpty, !ThemeDocumentStyle.isAllowedFontsURL(url) {
                    Text("Only a fonts.googleapis.com stylesheet is loaded; this one would be ignored.")
                        .font(.system(size: 11)).foregroundStyle(DefaultTheme.danger)
                }
                Text("Logo — inline SVG markup").font(.system(size: 11, weight: .semibold)).foregroundStyle(DefaultTheme.secondaryText)
                code(binding(\.logoSVG), minHeight: 70)
                Text("Extra CSS — after the report's own").font(.system(size: 11, weight: .semibold)).foregroundStyle(DefaultTheme.secondaryText)
                code(binding(\.extraCSS), minHeight: 60)
                if let previewURL {
                    ArtifactWebView(url: previewURL)
                        .frame(height: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder, lineWidth: 1))
                }
            }
        }
        .onAppear { select(store.customFamilies.first?.name ?? "") }
        .onChange(of: familyName) { select(familyName) }
    }

    private func binding(_ keyPath: WritableKeyPath<ThemeDocumentStyle, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" },
                set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func row(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(DefaultTheme.primaryText)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func code(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private func select(_ name: String) {
        familyName = name
        draft = store.customFamilies.first { $0.name == name }?.document ?? ThemeDocumentStyle()
        previewURL = nil
    }

    private func save() {
        guard var family = store.customFamilies.first(where: { $0.name == familyName }) else { return }
        family.document = draft.isEmpty ? nil : draft
        do {
            try store.addFamily(family)
            NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
            message = "Saved — the next reports in \(family.name) use it."
            if previewURL != nil { preview() }
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    /// The sample report in the theme as edited, not yet saved.
    private func preview() {
        guard var family = store.customFamilies.first(where: { $0.name == familyName }) else { return }
        family.document = draft
        let palette = AppModel.artifactPalette(family: family, dark: dark)
        let html = ArtifactRenderer.html(template: "pr-review", title: "Aperçu", palette: palette,
                                         data: ArtifactRenderer.sampleData)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-report-preview-\(UUID().uuidString).html")
        try? html.write(to: url, atomically: true, encoding: .utf8)
        previewURL = url
    }

    /// A `ThemeFamily` JSON file (what Loom writes in its themes folder).
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let family = try JSONDecoder().decode(ThemeFamily.self, from: Data(contentsOf: url))
            try store.addFamily(family)
            NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
            select(family.name)
            message = "\(family.name) imported — pick it as the app's theme above, or in a workflow's report."
        } catch {
            message = "This file is not a Loom theme."
        }
    }
}
