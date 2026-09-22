import Charts
import LoomAgents
import LoomCore
import LoomPersistence
import LoomUI
import SwiftUI

/// "Usage & estimated costs": every claude session on this machine, priced
/// from the public list. Opens from the `$` in the navbar. All the work
/// (scan + aggregate) runs off the main actor; the sheet only displays.
struct UsageSheet: View {
    let model: AppModel
    let onClose: () -> Void

    enum Metric: String, CaseIterable { case cost = "Cost", tokens = "Tokens" }
    enum Window: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var label: String { "\(rawValue)d" }
    }

    @State private var report: UsageReport?
    @State private var refreshing = false
    @State private var error: String?
    @State private var updatedAt: Date?
    @State private var metric: Metric = .cost
    @State private var window: Window = .month

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DefaultTheme.cardBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Cost values are estimates based on public list prices (as of \(ModelPricing.asOf)). Usage data stays in your local database.")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(DefaultTheme.danger)
                    }
                    if let report {
                        tiles(report)
                        chartCard(report)
                        byModel(report)
                    } else if refreshing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Indexing local session records…")
                                .font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(24)
            }
            Divider().overlay(DefaultTheme.cardBorder)
            footer
        }
        .frame(width: 1000, height: 880)
        .background(DefaultTheme.surface)
        .preferredColorScheme(DefaultTheme.colorScheme)
        .task { await refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "dollarsign")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DefaultTheme.accent)
            Text("Usage & Estimated Costs")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DefaultTheme.primaryText)
            Spacer()
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                GhostButton(systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .help("Rescan local session records")
            }
            GhostButton(systemImage: "xmark", action: onClose)
                .help("Close")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func tiles(_ report: UsageReport) -> some View {
        HStack(spacing: 14) {
            tile("Today", icon: "dollarsign", value: report.today)
            tile("Last 7 days", icon: "chart.line.uptrend.xyaxis", value: report.last7Days)
            tile("Last 30 days", icon: "calendar", value: report.last30Days)
        }
    }

    private func tile(_ title: String, icon: String, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(DefaultTheme.secondaryText)
            Text(Self.money(value))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(DefaultTheme.primaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder))
    }

    private func chartCard(_ report: UsageReport) -> some View {
        let points = report.points(lastDays: window.rawValue)
        let families = Array(Set(points.map(\.family))).sorted()
        let palette = Self.palette(for: families)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric == .cost ? "DAILY COST" : "DAILY TOKENS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DefaultTheme.secondaryText)
                    Text(metric == .cost
                         ? "\(Self.money(report.total(lastDays: window.rawValue))) over \(window.rawValue) days"
                         : "\(Self.tokens(points.reduce(0) { $0 + $1.tokens })) tokens over \(window.rawValue) days")
                        .font(.system(size: 14))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                Spacer()
                segmented(Metric.allCases, selected: $metric, label: \.rawValue)
                segmented(Window.allCases, selected: $window, label: \.label)
            }
            HStack(spacing: 12) {
                ForEach(families, id: \.self) { family in
                    HStack(spacing: 5) {
                        Circle().fill(palette[family] ?? DefaultTheme.mutedText).frame(width: 7, height: 7)
                        Text(family).font(.system(size: 11)).foregroundStyle(DefaultTheme.secondaryText)
                    }
                }
            }
            Chart(points) { point in
                BarMark(x: .value("Day", UsageDay.date(forKey: point.day) ?? Date(), unit: .day),
                        y: .value(metric.rawValue, metric == .cost
                                  ? NSDecimalNumber(decimal: point.cost).doubleValue
                                  : Double(point.tokens)))
                    .foregroundStyle(by: .value("Model", point.family))
            }
            .chartForegroundStyleScale(domain: families, range: families.map { palette[$0] ?? DefaultTheme.mutedText })
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(DefaultTheme.cardBorder)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(metric == .cost ? "$\(Int(v))" : Self.tokens(Int(v)))
                                .font(.system(size: 10)).foregroundStyle(DefaultTheme.secondaryText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: window == .week ? 1 : window == .month ? 5 : 15)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US")))
                        .font(.system(size: 10)).foregroundStyle(DefaultTheme.secondaryText)
                }
            }
            .frame(height: 240)
        }
        .padding(16)
        .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder))
    }

    private func byModel(_ report: UsageReport) -> some View {
        let lines = report.byModel(lastDays: window.rawValue)
        let max = lines.compactMap(\.cost).max() ?? 0
        let palette = Self.palette(for: lines.map(\.family))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COST BY MODEL")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Spacer()
                Text(Self.money(report.total(lastDays: window.rawValue)))
                    .font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
            }
            if lines.isEmpty {
                Text("No usage records found under \(ClaudeNativeSessions.defaultProjectsDirectory.path)")
                    .font(.system(size: 12)).foregroundStyle(DefaultTheme.mutedText)
            }
            ForEach(lines, id: \.family) { line in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.family)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(DefaultTheme.primaryText)
                        Text("\(Self.tokens(line.input)) in / \(Self.tokens(line.output)) out / \(Self.tokens(line.cacheWrite5m + line.cacheWrite1h)) cache-w / \(Self.tokens(line.cacheRead)) cache-r")
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                    Spacer()
                    if let cost = line.cost {
                        GeometryReader { geo in
                            Capsule().fill(palette[line.family] ?? DefaultTheme.mutedText)
                                .frame(width: max > 0 ? geo.size.width * CGFloat(NSDecimalNumber(decimal: cost / max).doubleValue) : 0)
                        }
                        .frame(width: 140, height: 6)
                        Text(Self.money(cost))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DefaultTheme.primaryText)
                            .frame(width: 80, alignment: .trailing)
                    } else {
                        Text("unpriced")
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.mutedText)
                            .frame(width: 228, alignment: .trailing)
                    }
                }
                .padding(.vertical, 8)
                Divider().overlay(DefaultTheme.cardBorder)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text(updatedAt.map { "Data from local per-turn session records, updated \(Self.clock.string(from: $0))" }
                 ?? "Data from local per-turn session records")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.mutedText)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private func segmented<T: Hashable>(_ options: [T], selected: Binding<T>,
                                        label: @escaping (T) -> String) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selected.wrappedValue = option } label: {
                    Text(label(option))
                        .font(.system(size: 11, weight: selected.wrappedValue == option ? .semibold : .regular))
                        .foregroundStyle(selected.wrappedValue == option ? DefaultTheme.primaryText : DefaultTheme.secondaryText)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selected.wrappedValue == option ? DefaultTheme.surface : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DefaultTheme.background, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Work

    private func refresh() async {
        guard let index = model.usageIndex() else {
            error = "The local database is not available."
            return
        }
        refreshing = true
        defer { refreshing = false }
        let projects = ClaudeNativeSessions.defaultProjectsDirectory
        let today = Date()
        let result: Result<UsageReport, Error> = await Task.detached(priority: .userInitiated) {
            do {
                _ = try index.refresh(projectsDirectory: projects)
                let since = UsageDay.keys(lastDays: 90, endingAt: today).first ?? "2000-01-01"
                let totals = try index.dailyTotals(fromDay: since)
                return .success(UsageReport(totals: totals, today: today))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let built):
            report = built
            error = nil
            updatedAt = Date()
        case .failure(let failure):
            error = "Could not read usage records: \(failure.localizedDescription)"
        }
    }

    // MARK: - Formatting

    /// Cached like `clock` below: building a NumberFormatter per cell is costly.
    private static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func money(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        return currency.string(from: number) ?? "$0.00"
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 10_000...: return String(format: "%.1fk", Double(count) / 1000)
        default: return "\(count)"
        }
    }

    /// One hue per tier (fable/mythos = accent, opus = orange, sonnet = blue,
    /// haiku = gray); within a tier the newest version is the fullest shade.
    static func palette(for families: [String]) -> [String: Color] {
        func tier(_ f: String) -> (Color, Int) {
            if f.hasPrefix("fable") || f.hasPrefix("mythos") { return (DefaultTheme.accent, 0) }
            if f.hasPrefix("opus") { return (.orange, 1) }
            if f.hasPrefix("sonnet") { return (Color(red: 0.35, green: 0.55, blue: 1.0), 2) }
            if f.hasPrefix("haiku") { return (.gray, 3) }
            return (DefaultTheme.mutedText, 4)
        }
        let shades: [Double] = [1.0, 0.6, 0.38, 0.25]
        var result: [String: Color] = [:]
        let grouped = Dictionary(grouping: families, by: { tier($0).1 })
        for (_, members) in grouped {
            // Descending string order puts the newest version first (5-1 > 5 > 4-8).
            for (rank, family) in members.sorted(by: >).enumerated() {
                result[family] = tier(family).0.opacity(shades[min(rank, shades.count - 1)])
            }
        }
        return result
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
