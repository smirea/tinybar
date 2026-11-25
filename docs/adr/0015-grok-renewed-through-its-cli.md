# Renewing an expired Grok login through the Grok CLI

ADR 0012 accepted that a Grok login goes Stale once it expires, assuming CodexBar's report of logins that last about seven days. In practice a `grok login` lasts six hours (`expires_at` is six hours after the file is written, seen on CLI 1.0.92). So the Grok card went Stale every afternoon after a morning session, which is most of the time for anyone not using Grok all day.

So when the login has expired, or the server turns it down with a 401, Tinybar runs `grok models` once with that login's `GROK_HOME`, reads `auth.json` again, and retries if the login changed. `grok models` is the quickest command that signs the CLI in (about a second, nothing sent to a model). The CLI renews the login under its own lock and writes it back itself, so Tinybar still never sends a refresh token or writes a credential, and the single-use refresh token can't be spent behind the CLI's back. A valid login is left alone, and if the CLI can't renew (a revoked login, no network, the CLI missing), the card goes Stale with the same hint as before.

This is the same pattern as `agy -p /usage` and `codex app-server` in ADR 0001: the client handles its own login. It runs at most once per expired login per check, which at six-hour logins is a few times a day.

## Considered options

- **Refreshing with the token in `auth.json`**: no process to start, but Tinybar would race the CLI for a single-use token and write the CLI's file, which ADR 0001 rules out.
- **Running the CLI before every check**: keeps the login fresh but starts a 180 MB binary every five minutes for nothing (ADR 0012's reason for not using `grok agent stdio`).
- **`grok usage`**: would be the natural call, but it needs the CLI's background service and refuses without one.

## Consequences

- Tinybar's polling can now renew a Grok login, the second exception after claude-swap (ADR 0010).
- If `grok models` stops signing in, or starts sending requests that matter, the card goes back to going Stale, which is the old behaviour.
