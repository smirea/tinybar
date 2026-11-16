# Fork

This fork of [ThiloReintjes/tinybar](https://github.com/ThiloReintjes/tinybar) also counts the Claude Code and Codex
usage of other machines, read over SSH without copying their logs.

- Hosts are in `Sources/TinybarCore/Usage/RemoteHosts.swift`: names from `~/.ssh/config` that connect without a prompt.
- `RemoteLogs.swift` lists and streams `~/.claude/projects` and `~/.codex/{sessions,archived_sessions}` on each host.
  Their cursors use paths like `/@mini/.claude/projects/…`. A host that is offline is skipped and caught up later.
- The rest of the diff is a few hooks in `UsageStore.swift`, kept small so the daily rebase stays clean.

`Scripts/install-fork.sh` builds, signs with the local Apple Development identity and replaces `/Applications/Tinybar.app`.
`fork-sync` (in `~/code/scripts`) rebases `main` onto `upstream/main` every day at noon, pushes, and reinstalls.
Don't install the Homebrew cask alongside it: its updater would put the upstream app back.
