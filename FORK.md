# Fork

This fork of [ThiloReintjes/tinybar](https://github.com/ThiloReintjes/tinybar) also counts the Claude Code and Codex
usage of other machines, read over SSH without copying their logs.

- Hosts are in `Sources/TinybarCore/Usage/RemoteHosts.swift`: names from `~/.ssh/config` that connect without a prompt.
- `RemoteLogs.swift` lists and streams `~/.claude/projects` and `~/.codex/{sessions,archived_sessions}` on each host.
  Their cursors use paths like `/@mini/.claude/projects/…`. A host that is offline is skipped and caught up later.
- The rest of the diff is a few hooks in `UsageStore.swift`, kept small so the daily rebase stays clean.

The Codex card can also use a banked reset, through `codex app-server` ([ADR 0014](docs/adr/0014-using-codex-banked-resets.md)).
An expired Grok login is renewed by running `grok models` ([ADR 0015](docs/adr/0015-grok-renewed-through-its-cli.md)).
Claude and Codex limits come only through their CLIs, as T3 Code reads them: `claude` in SDK mode and `codex app-server`.
The CLIs renew their own logins, so those cards don't go stale; the token reads, HTTP calls and browser fallback are gone
([ADR 0016](docs/adr/0016-limits-only-through-the-clis.md)).
The overview defaults to Bars: a row per Limit Window with its pace notch, share left and signed Reserve as time
(`ForkViews.swift`). Settings → Overview switches back to the upstream rings.

`Scripts/install.sh` builds, signs with the local Apple Development identity and replaces `/Applications/Tinybar.app`.
`fork-sync` (in `~/code/scripts`) rebases `main` onto `upstream/main` every day at noon, pushes, and reinstalls.
Don't install the Homebrew cask alongside it: its updater would put the upstream app back.
