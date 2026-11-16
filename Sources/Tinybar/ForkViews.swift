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
