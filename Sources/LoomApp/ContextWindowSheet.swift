import LoomAgents
import LoomCore
import LoomUI
import SwiftUI

extension ContextWindow.Level {
    /// Invariant semantics, theme hue: green while comfortable, amber past
    /// half, the accent past three quarters, danger at the edge.
    @MainActor var color: Color {
        switch self {
        case .normal: DefaultTheme.badgeColor(for: .working)
        case .elevated: DefaultTheme.badgeColor(for: .needsInput)
        case .high: DefaultTheme.accent
        case .critical: DefaultTheme.danger
        }
    }
}

/// "Context Window": one session's window, read from claude's own records.
/// Opens from the ring in the session header. The whole native file is read
/// here (the cumulative figures need it), off the main actor.
struct ContextWindowSheet: View {
    let model: AppModel
    let sessionID: SessionID
    let onClose: () -> Void

    @State private var usage: SessionUsageSummary?
    @State private var loaded = false
    @State private var refreshing = false

    private var state: SessionState? {
        model.sessions.first { $0.id == sessionID }?.state
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DefaultTheme.cardBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let usage {
                        usageSection(usage)
                        banner(usage)
                        tiles(usage)
                        breakdown(usage)
                        details(usage)
                    } else if loaded {
                        Text("No usage recorded yet — the agent has not answered in this session.")
                            .font(.system(size: 12))
                            .foregroundStyle(DefaultTheme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the session's records…")
                                .font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 620, height: 760)
        .background(DefaultTheme.surface)
        .preferredColorScheme(DefaultTheme.colorScheme)
        .task(id: state) { await refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DefaultTheme.accent)
            Text("Context Window")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            Spacer()
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                GhostButton(systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .help("Re-read the session's records")
            }
            GhostButton(systemImage: "xmark", action: onClose)
                .help("Close")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func usageSection(_ usage: SessionUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Usage")
                    .font(.system(size: 13))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Spacer()
                Text(Self.percent(usage.fraction))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(usage.level.color)
            }
            ContextBar(fraction: usage.fraction, color: usage.level.color, height: 8)
            HStack {
                Text("\(UsageSheet.tokens(usage.contextTokens)) used")
                Spacer()
                Text("\(UsageSheet.tokens(usage.windowTokens)) total")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(DefaultTheme.secondaryText)
        }
    }

    private static func bannerText(for level: ContextWindow.Level) -> (title: String, body: String)? {
        switch level {
        case .normal:
            return nil
        case .elevated:
            return ("Context window filling up",
                    "You have some room left, but long conversations may start losing earlier context.")
        case .high, .critical:
            return ("Context window nearly full",
                    "Claude Code will compact the conversation soon: earlier details get summarised.")
        }
    }

    @ViewBuilder
    private func banner(_ usage: SessionUsageSummary) -> some View {
        if let text = Self.bannerText(for: usage.level) {
            let color = usage.level.color
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                    Text(text.body)
                        .font(.system(size: 12))
                        .foregroundStyle(color.opacity(0.85))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
        }
    }

    private func tiles(_ usage: SessionUsageSummary) -> some View {
        HStack(spacing: 14) {
            tile("Input Tokens", icon: "arrow.down.to.line", value: UsageSheet.tokens(usage.inputTokens),
                 tint: DefaultTheme.badgeColor(for: .idle))
            tile("Output Tokens", icon: "arrow.up.to.line", value: UsageSheet.tokens(usage.outputTokens),
                 tint: DefaultTheme.badgeColor(for: .working))
        }
    }

    private func tile(_ title: String, icon: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
                Text(title).font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(DefaultTheme.primaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder))
    }

    private func breakdown(_ usage: SessionUsageSummary) -> some View {
        let window = Double(max(usage.windowTokens, 1))
        let read = DefaultTheme.badgeColor(for: .idle)
        let write = DefaultTheme.accent
        let fresh = DefaultTheme.primaryText
        return VStack(alignment: .leading, spacing: 12) {
            Text("BREAKDOWN")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DefaultTheme.secondaryText)
            VStack(alignment: .leading, spacing: 6) {
                row("Context (latest turn)", UsageSheet.tokens(usage.contextTokens))
                StackedBar(segments: [
                    (Double(usage.lastTurnCacheRead) / window, read),
                    (Double(usage.lastTurnCacheWrite) / window, write),
                    (Double(usage.lastTurnInput) / window, fresh),
                ], height: 6)
                HStack(spacing: 12) {
                    legend("cache read \(UsageSheet.tokens(usage.lastTurnCacheRead))", read)
                    legend("cache write \(UsageSheet.tokens(usage.lastTurnCacheWrite))", write)
                    legend("fresh input \(UsageSheet.tokens(usage.lastTurnInput))", fresh)
                }
            }
            bar("Cumulative input", usage.inputTokens, over: usage.windowTokens, color: read)
            bar("Cumulative output", usage.outputTokens, over: usage.windowTokens,
                color: DefaultTheme.badgeColor(for: .working))
            bar("Cumulative cache read", usage.cacheReadTokens, over: usage.windowTokens, color: read.opacity(0.6))
        }
    }

    private func bar(_ title: String, _ count: Int, over window: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(title, UsageSheet.tokens(count))
            ContextBar(fraction: Double(count) / Double(max(window, 1)), color: color, height: 6)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(DefaultTheme.primaryText)
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(DefaultTheme.mutedText)
        }
    }

    private func details(_ usage: SessionUsageSummary) -> some View {
        VStack(spacing: 0) {
            detail("Model", usage.model, icon: "cpu")
            detail("Window Size", "\(UsageSheet.tokens(usage.windowTokens)) tokens")
            detail("Remaining", "\(UsageSheet.tokens(usage.remainingTokens)) (\(Self.percent(1 - usage.fraction)))")
            detail("Session Cost", usage.cost.map { UsageSheet.money($0) } ?? "—")
            detail("Turns", "\(usage.turnCount)")
            if let rate = usage.cacheHitRate {
                detail("Cache hit rate", Self.percent(rate))
            }
            detail("Duration", Self.duration(usage.duration))
            if usage.models.count > 1 {
                detail("Models used", usage.models.map { ModelPricing.family(for: $0) }.joined(separator: ", "))
            }
            Text("Cost is an estimate from public list prices (as of \(ModelPricing.asOf)); the window sizes date from \(ContextWindow.asOf).")
                .font(.system(size: 10))
                .foregroundStyle(DefaultTheme.mutedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder))
    }

    private func detail(_ label: String, _ value: String, icon: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(DefaultTheme.secondaryText)
            }
            Text(label).font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DefaultTheme.primaryText)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Work

    private func refresh() async {
        refreshing = true
        defer { refreshing = false; loaded = true }
        let id = sessionID
        // The whole file: the cumulative figures need every turn, and the
        // megabytes never stall the UI from a detached utility task.
        usage = await Task.detached(priority: .utility) {
            ClaudeNativeSessions.usage(for: id, tailBytes: nil)
        }.value
    }

    // MARK: - Formatting

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", max(0, fraction) * 100)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        let (h, m, s) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

/// Linear window gauge: the same track/fill recipe as the ring, laid flat.
struct ContextBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DefaultTheme.cardBorder)
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: height)
    }
}

/// Segments laid end to end over one track — the latest window by origin.
struct StackedBar: View {
    let segments: [(fraction: Double, color: Color)]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DefaultTheme.cardBorder)
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { entry in
                        Rectangle().fill(entry.element.color)
                            .frame(width: geo.size.width * CGFloat(min(1, max(0, entry.element.fraction))))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }
}
