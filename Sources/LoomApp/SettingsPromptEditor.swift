import LoomUI
import SwiftUI

/// A prompt in Settings — the session instructions, the review setup
/// command, the scheduled review's prompt — folded by default: its title,
/// whether it is still the default, a two-line preview. Unfolded, the
/// editor. The draft is THIS view's: a keystroke re-renders the editor, not
/// the whole Settings page, and the text is saved once typing pauses (and
/// when the editor goes), not at every key.
struct PromptEditor: View {
    let title: String
    let defaultText: String
    /// Where the text goes. Each setter here stores nothing when the text
    /// is the default, so a default improved in a release reaches everyone
    /// who never edited it.
    let save: (String) -> Void
    var minHeight: CGFloat = 200
    /// Shown faded: the prompt is not in use (its switch is off).
    var dimmed = false

    @State private var draft: String
    /// What was last handed to `save` — nothing pending when equal.
    @State private var saved: String
    @AppStorage private var expanded: Bool

    /// `id` names the fold in UserDefaults: unfolded stays unfolded.
    init(id: String, title: String, text: String, defaultText: String,
         minHeight: CGFloat = 200, dimmed: Bool = false, save: @escaping (String) -> Void) {
        self.title = title
        self.defaultText = defaultText
        self.minHeight = minHeight
        self.dimmed = dimmed
        self.save = save
        _draft = State(initialValue: text)
        _saved = State(initialValue: text)
        _expanded = AppStorage(wrappedValue: false, "loom.settings.prompt.\(id).expanded")
    }

    private var isDefault: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first two lines with words in them — what the folded card shows.
    private var preview: String {
        draft.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "---" }
            .prefix(2)
            .joined(separator: "\n")
    }

    private var lineCount: Int {
        draft.isEmpty ? 0 : draft.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                TextEditor(text: $draft)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: minHeight, maxHeight: 520)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
                    // Saved once typing pauses: a new task per change, the
                    // previous one cancelled before it writes.
                    .task(id: draft) {
                        guard draft != saved else { return }
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        commit()
                    }
                    .onDisappear { commit() }
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded = true }
                } label: {
                    Text(preview.isEmpty ? "Empty" : preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(DefaultTheme.surfaceRaised.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(DefaultTheme.cardBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverBrightness()
                .help("Edit the prompt")
            }
        }
        .opacity(dimmed ? 0.5 : 1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expanded { commit() }
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DefaultTheme.primaryText)
                    Text(isDefault ? "default" : "customized")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isDefault ? DefaultTheme.secondaryText : DefaultTheme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(isDefault ? DefaultTheme.surfaceRaised : DefaultTheme.accent.opacity(0.14),
                                    in: Capsule())
                    Text(lineCount == 1 ? "1 line" : "\(lineCount) lines")
                        .font(.system(size: 10))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Fold" : "Unfold to edit")
            Spacer()
            if !isDefault {
                GhostButton("Reset to default", systemImage: "arrow.counterclockwise") {
                    draft = defaultText
                    commit()
                }
            }
        }
    }

    private func commit() {
        guard draft != saved else { return }
        saved = draft
        save(draft)
    }
}
