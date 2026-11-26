import SwiftUI
import TinybarCore

/// What sets this fork apart, shown in the app so it's never mistaken for an upstream build.
enum Fork {
    static let name = "smirea/tinybar"
    static let url = URL(string: "https://github.com/smirea/tinybar")!
}

/// The footer's link to the fork, before the status.
struct ForkLink: View {
    var body: some View {
        Button("[\(Fork.name)]") { NSWorkspace.shared.open(Fork.url) }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 4)
            .help(Fork.url.absoluteString)
    }
}

/// An overview row's errors and incidents as marks beside its name, so the line below keeps showing
/// usage. The details are in the tooltips and on the provider's page.
struct OverviewAlerts: View {
    let model: AppModel
    let id: ProviderID

    var body: some View {
        if let error = model.providers[id]?.error {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help(StaleText.short(id: id, error: error))
        }
        if let incident = model.loudIncident(id) {
            StatusLight(severity: incident.severity, size: 5)
                .help("\(incident.title)\n\(incident.summary)")
        }
    }
}

/// Settings' top note on what the fork adds.
struct ForkNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Fork").font(.system(size: 13, weight: .semibold))
                Button(Fork.name) { NSWorkspace.shared.open(Fork.url) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
            }
            Text("Also counts the Claude Code and Codex usage of \(RemoteHosts.all.joined(separator: ", ")), read over SSH. Rebased onto upstream and reinstalled daily at noon by fork-sync.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

/// How the overview shows each subscription: a row per Limit Window, or the upstream rings.
enum OverviewStyle: String, CaseIterable {
    case bars, rings

    var title: String {
        switch self {
        case .bars: "Bars"
        case .rings: "Rings"
        }
    }
}

/// An overview row that packs the provider page's Limit Windows into a table: name, bar with the
/// even-pace notch, share left, and the Reserve as signed time.
struct OverviewBarsRow: View {
    let model: AppModel
    let id: ProviderID

    var body: some View {
        let state = model.providers[id]
        let snapshot = state?.snapshot
        let stale = state?.isStale ?? false
        let asOf = stale ? nil : snapshot?.fetchedAt

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(id.displayName).font(.system(size: 13, weight: .semibold))
                if let plan = snapshot?.plan {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if model.pinned?.0 == id {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Shown in the menu bar")
                }
                OverviewAlerts(model: model, id: id)
                Spacer(minLength: 4)
                if snapshot == nil, state?.error == nil {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            if let snapshot, !snapshot.windows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                    ForEach(snapshot.windows) { window in
                        BarsWindowRow(window: window, provider: id, asOf: asOf)
                    }
                }
                .opacity(stale ? 0.55 : 1)
            } else if let error = state?.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(StaleText.short(id: id, error: error))
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(1)
            } else if snapshot != nil {
                Text("No limits reported").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

private struct BarsWindowRow: View {
    let window: LimitWindow
    let provider: ProviderID
    /// When the window's usage was read. nil while Stale: the pace is out of date.
    let asOf: Date?
    @Environment(\.showsUsed) private var showsUsed

    var body: some View {
        let reserve = asOf.flatMap { window.signedReserveSeconds(asOf: $0) }
        GridRow {
            Text(window.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
            RemainingBar(
                fraction: window.remainingPercent / 100, provider: provider,
                evenPace: asOf.flatMap { window.elapsedShare(asOf: $0) }.map { 1 - $0 })
            Text("\(Int(shownPercent(left: window.remainingPercent, used: showsUsed).rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PercentText.color(window.remainingPercent))
                .frame(width: 34, alignment: .trailing)
            Text(reserve.map(Self.delta) ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(reserve.map { $0 < 0 } == true ? AnyShapeStyle(.red)
                    : reserve == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .fixedSize()
                .frame(width: 56, alignment: .trailing)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title) \(PercentText.phrase(left: window.remainingPercent, used: showsUsed))")
        .accessibilityValue(reserve.map { $0 < 0 ? "\(Self.span(-$0)) over an even pace" : "\(Self.span($0)) to spare" } ?? "")
    }

    /// "+2d 9h" under an even pace, "−1d 3h" over it.
    static func delta(_ seconds: TimeInterval) -> String {
        "\(seconds < 0 ? "−" : "+")\(span(abs(seconds)))"
    }

    private static func span(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "0m" : Format.countdown(to: Date(timeIntervalSinceReferenceDate: seconds), now: Date(timeIntervalSinceReferenceDate: 0))
    }
}

extension LimitWindow {
    /// The share of the window passed, 0...1. nil for a Pool, whose Accounts don't share a window.
    func elapsedShare(asOf: Date) -> Double? {
        guard poolRefill == nil, let resetsAt, let duration = durationSeconds, duration > 0 else { return nil }
        let untilReset = resetsAt.timeIntervalSince(asOf)
        guard untilReset > 0, untilReset <= TimeInterval(duration) else { return nil }
        return 1 - untilReset / TimeInterval(duration)
    }

    /// The Reserve as time, negative when more is used than an even pace would have by now.
    func signedReserveSeconds(asOf: Date) -> TimeInterval? {
        guard let elapsed = elapsedShare(asOf: asOf), let duration = durationSeconds else { return nil }
        return (elapsed - min(max(usedPercent, 0), 100) / 100) * TimeInterval(duration)
    }
}

/// Settings' choice between the overview's bars and rings.
struct OverviewStylePicker: View {
    @Binding var style: OverviewStyle

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.leading, 14)
            HStack {
                Text("Overview").font(.system(size: 13))
                Spacer(minLength: 8)
                Picker("Overview", selection: $style) {
                    ForEach(OverviewStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}
