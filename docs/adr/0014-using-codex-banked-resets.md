# Using a Codex Banked Reset from the popover

ADR 0001 kept Tinybar from calling anything that changes account state, Banked Resets included. Using a Codex reset meant leaving the menu bar for the Codex CLI or ChatGPT, at the moment a limit runs out, which is when Tinybar is already open.

So the Codex card's Banked Resets line has a button that uses one. It goes through the Codex CLI's own app-server, `account/rateLimitResetCredit/consume`, run with the Account's `CODEX_HOME`. The CLI uses and renews its own login, as it does for the app-server fallback, so Tinybar still never sends a request that changes state with a token it read. Each press carries a new idempotency key, so a retried request can't spend a second reset. The backend picks which reset to use.

The button is confirmed in place, never on the first click. When the window a reset refills that has the least left still has more than 20%, a second confirmation names how much would be thrown away.

## Considered options

- **Posting to `chatgpt.com` with the token Tinybar reads**: one request less, but it would be Tinybar's own write with a borrowed token, which ADR 0001 rules out.
- **Claude's "Reset for free" grants**: no public way to use one is known, and the grant ids are never read (SPEC §4), so Claude's line stays display only.

## Consequences

- A Codex Account read only through the browser session has no button: that session may not be the CLI's login.
- The button needs the Codex CLI installed; without it the press fails with a message in place.
- Every other part of ADR 0001 stands: Tinybar still never refreshes a token or sends a prompt.
