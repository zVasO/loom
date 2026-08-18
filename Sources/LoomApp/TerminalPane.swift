import LoomCore
import LoomTerminal
import LoomUI
import SwiftUI

/// The self-contained terminal pane: surface fetch, attach lifecycle, grid
/// resize (TRM-02, placeholder-proof), keyboard capture and boot placeholder.
/// Used by the session detail AND the embedded PR review pane — the wiring
/// lives once.
struct TerminalPane: View {
    let model: AppModel
    let sessionID: SessionID
    @State private var surface: TerminalSurface?
    @State private var firstResizeDone = false
    @State private var focusTick = 0

    var body: some View {
        Group {
            if let surface {
                GeometryReader { proxy in
                    TerminalScreenView(screen: surface.screen, history: surface.history,
                                       historyBase: surface.historyBase)
                        // TRM-02: the view announces its grid; task(id:) gives a
                        // free debounce while resizing.
                        .task(id: proxy.size) {
                            // Never apply the GeometryReader placeholder (100×100).
                            guard proxy.size.width >= 300, proxy.size.height >= 200 else { return }
                            if firstResizeDone {
                                try? await Task.sleep(for: .milliseconds(80))
                                guard !Task.isCancelled else { return }
                            }
                            firstResizeDone = true
                            let grid = TerminalMetrics.grid(fitting: proxy.size)
                            surface.resize(cols: grid.cols, rows: grid.rows)
                            model.noteTerminalGrid(cols: grid.cols, rows: grid.rows)
                        }
                        // Keystrokes go to the agent's field (first responder).
                        .background(KeyCaptureView(focusTick: focusTick) { surface.send($0) })
                        .contentShape(Rectangle())
                        .onTapGesture { focusTick += 1 }
                        // claude's boot takes seconds — never a silent black screen.
                        .overlay {
                            if surface.screen.revision == 0 {
                                VStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("claude is starting…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(DefaultTheme.secondaryText)
                                    Text("Plugins and MCP servers load first — unauthenticated MCP servers slow this down (run /mcp).")
                                        .font(.system(size: 10))
                                        .foregroundStyle(DefaultTheme.mutedText)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: 380)
                                }
                            }
                        }
                }
                .background(DefaultTheme.contentBackground)
                .task { await surface.attached() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sessionID) { surface = await model.surface(for: sessionID) }
    }
}
