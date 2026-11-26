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
                    ForEach(snapshot.windows.filter { model.settings.showsBar(id, $0) }) { window in
                        BarsWindowRow(window: window, provider: id, asOf: asOf, showsPercent: model.settings.barsShowPercent)
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
    let showsPercent: Bool
    @Environment(\.showsUsed) private var showsUsed

    var body: some View {
        let reserve = asOf.flatMap { window.signedReserveSeconds(asOf: $0) }
        GridRow {
            Text(window.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
            PaceBar(
                fraction: window.remainingPercent / 100, provider: provider,
                evenPace: asOf.flatMap { window.elapsedShare(asOf: $0) }.map { 1 - $0 })
            if showsPercent {
                Text("\(Int(shownPercent(left: window.remainingPercent, used: showsUsed).rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PercentText.color(window.remainingPercent))
                    .frame(width: 34, alignment: .trailing)
            }
            delta(reserve)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .frame(width: 40, alignment: .trailing)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title) \(PercentText.phrase(left: window.remainingPercent, used: showsUsed))")
        .accessibilityValue(reserve.map { $0 < 0 ? "\(Self.span(-$0)) over an even pace" : "\(Self.span($0)) to spare" } ?? "")
    }

    /// Over an even pace: white on a red tag, so it stands out from the rows that are fine.
    @ViewBuilder
    private func delta(_ reserve: TimeInterval?) -> some View {
        if let reserve, reserve < 0 {
            Text(Self.delta(reserve))
                .foregroundStyle(.white)
                .background(Color(red: 0.92, green: 0.2, blue: 0.2), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if let reserve {
            Text(Self.delta(reserve))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    /// "+2d" under an even pace, "−3h" over it: only the largest unit.
    static func delta(_ seconds: TimeInterval) -> String {
        "\(seconds < 0 ? "−" : "+")\(span(abs(seconds)))"
    }

    private static func span(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 86400 { return "\(s / 86400)d" }
        if s >= 3600 { return "\(s / 3600)h" }
        return "\(s / 60)m"
    }
}

/// The share left, with the even pace as a line taller than the bar and a gap cut around it, so it
/// shows on the fill, on the empty track and at either end alike.
private struct PaceBar: View {
    let fraction: Double
    let provider: ProviderID
    var evenPace: Double?
    @Environment(\.showsUsed) private var showsUsed

    var body: some View {
        GeometryReader { geo in
            let f = shown(fraction)
            let x = evenPace.map { min(max(geo.size.width * shown($0), 1), geo.size.width - 1) }
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(provider.color.opacity(0.18))
                    Capsule()
                        .fill(provider.barFill)
                        .mask(alignment: .leading) {
                            Capsule().frame(width: f > 0 ? max(6, geo.size.width * f) : 0)
                        }
                    if let x {
                        Rectangle().frame(width: 4).offset(x: x - 2).blendMode(.destinationOut)
                    }
                }
                .frame(height: 6)
                .compositingGroup()
                if let x {
                    Capsule().fill(.primary).frame(width: 2, height: 12).offset(x: x - 1)
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 12)
        .animation(.smooth(duration: 0.5), value: fraction)
        .animation(.smooth(duration: 0.5), value: evenPace)
    }

    private func shown(_ left: Double) -> Double {
        shownPercent(left: min(max(left, 0), 1) * 100, used: showsUsed) / 100
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

extension Settings {
    func showsBar(_ id: ProviderID, _ window: LimitWindow) -> Bool {
        !hiddenBars.contains(Self.barKey(id, window))
    }

    func setBar(_ id: ProviderID, _ window: LimitWindow, shown: Bool) {
        if shown { hiddenBars.remove(Self.barKey(id, window)) } else { hiddenBars.insert(Self.barKey(id, window)) }
    }

    private static func barKey(_ id: ProviderID, _ window: LimitWindow) -> String { "\(id.rawValue).\(window.id)" }
}

/// Settings' list of every Limit Window the overview can show as a bar, each toggled on or off.
/// Only windows a subscription has reported are listed, so it fills in as they're read.
struct OverviewBarsSection: View {
    let model: AppModel

    var body: some View {
        let rows = model.enabledProviders.flatMap { id in
            (model.providers[id]?.snapshot?.windows ?? []).map { (key: "\(id.rawValue).\($0.id)", id: id, window: $0) }
        }
        @Bindable var settings = model.settings
        SettingsSection("Overview bars", footer: "Turn off the limits you don't need to see at a glance. Their provider pages still show them.") {
            SettingsToggle(isOn: $settings.barsShowPercent, first: true) { Text("Show percentages") }
            ForEach(rows, id: \.key) { row in
                SettingsToggle(isOn: Binding(
                    get: { model.settings.showsBar(row.id, row.window) },
                    set: { model.settings.setBar(row.id, row.window, shown: $0) }))
                {
                    HStack(spacing: 8) {
                        ProviderDot(id: row.id, size: 7)
                        Text(row.id.displayName).foregroundStyle(.secondary)
                        Text(row.window.title)
                    }
                }
            }
        }
    }
}
