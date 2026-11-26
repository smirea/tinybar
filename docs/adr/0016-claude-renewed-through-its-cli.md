# Renewing an expired Claude login through Claude Code

ADR 0001 let a Claude login go Stale once it expired, until the user ran `claude` again. Claude Code's access token lasts eight hours, so the card went Stale every night and on any day spent in other tools, and "run `claude` once" became a chore several times a week.

T3 Code shows Claude limits without ever going Stale. It never reads the token: it starts `claude` in its Agent SDK mode (stream-json over stdio), sends the `initialize` and `get_usage` control requests, and never sends a prompt. Claude Code settles its own login before it reads usage, so an expired token is refreshed and saved by the CLI itself.

Tinybar now does the same when the stored token has expired or the API answers 401 or 403: it runs `claude` once that way, with the login's `CLAUDE_CONFIG_DIR` for an added folder, and reads `rate_limits` from the answer, which has the same shape as `/api/oauth/usage`. The next check finds the renewed token and reads it directly again, so the CLI runs at most once per expired login, a few times a day. The process skips settings files, hooks, MCP servers and the IDE connection, saves no session, and is killed after the answer (about 0.3 s).

The same reasoning applies to Codex logins in added folders: they now fall back to `codex app-server` with that folder's `CODEX_HOME`, as the default login already did.

## Considered options

- **Always reading through the CLI, as T3 Code does**: no Keychain read at all, but a Node or native process every five minutes where a plain HTTP call works for the other seven hours and fifty minutes.
- **Refreshing with the stored refresh token**: Tinybar would race Claude Code for a single-use token and write its Keychain item, which ADR 0001 rules out.
- **`claude auth status`**: reports the login without settling it, so an expired token stays expired.

## Consequences

- Tinybar's polling can now renew a Claude login, as it already could for Grok (ADR 0015) and claude-swap (ADR 0010). Tinybar still never sends a refresh token or writes a credential itself.
- A login the CLI can't renew (revoked, signed out, no `claude` on disk) still goes Stale with the same hint.
- `get_usage` is marked experimental in the Agent SDK. If it changes shape, the card goes Stale on expiry again, which is the old behaviour.
