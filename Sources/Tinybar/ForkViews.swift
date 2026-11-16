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
