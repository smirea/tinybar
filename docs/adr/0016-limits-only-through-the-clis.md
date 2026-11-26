# Claude and Codex limits only through their CLIs

ADR 0001 read Claude Code's and Codex's stored tokens and called their usage endpoints directly, letting a login go Stale once it expired until the user ran the CLI again. Claude Code's access token lasts eight hours, so the Claude card went Stale every night and on any day spent in other tools, and "run `claude` once" became a chore several times a week.

T3 Code shows the same limits without ever going Stale, because it never reads a token:

- **Claude**: it starts `claude` in its Agent SDK mode (stream-json over stdio), sends the `initialize` and `get_usage` control requests, and never sends a prompt. Claude Code settles its own login before it reads usage, refreshing and saving an expired one.
- **Codex**: it starts `codex app-server` and asks `account/read`, then `account/rateLimits/read`. The CLI refreshes its own login while answering.
- It finds both CLIs on the PATH of an interactive login shell (`$SHELL -ilc`), so it runs the same CLI the user does.

Tinybar now does exactly that, and nothing else, for both: no Keychain or `auth.json` token read, no direct call to `api.anthropic.com` or `chatgpt.com`, and no browser-cookie fallback. The stored logins are still looked at, without their tokens, to tell whether a Provider has one and whose it is. Each check starts one short-lived process per login, about 0.3 s for `claude` with settings files, hooks, MCP servers, the IDE connection and session saving turned off.

## Considered options

- **Reading the token directly and the CLI only once it expired**: one process fewer per check for most of the day, but two ways to read the same limits, and the browser fallback beside them. Removed for one path that also renews the login.
- **Refreshing with the stored refresh token**: Tinybar would race the CLI for a single-use token and write its credential store, which ADR 0001 rules out.
- **`claude auth status`**: reports the login without settling it, so an expired token stays expired.

## Consequences

- Polling renews Claude and Codex logins, as it already did for Grok (ADR 0015) and claude-swap (ADR 0010). Tinybar still never sends a refresh token or writes a credential itself.
- A login the CLI can't renew (revoked, signed out, CLI missing) still goes Stale with the same hint.
- Claude's plan is the name Claude Code reports ("Ultra"), not one derived from the stored rate-limit tier. Claude's Banked Resets show only when `get_usage` carries them; T3 Code reads those with the token, which this ADR rules out.
- `get_usage` is marked experimental in the Agent SDK. If it changes shape, the Claude card shows an error until Tinybar follows.
- Removing the upstream files for the direct and browser paths makes the daily rebase onto upstream conflict when upstream edits them.
