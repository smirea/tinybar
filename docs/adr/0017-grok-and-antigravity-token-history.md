# Token history from Grok's and Antigravity's own records

Token history and Stats counted Claude Code, Codex and OpenCode Go only. ADR 0012 left Grok's session files out because they had no per-model split, and Gemini had no local history Tinybar knew of. So a day spent in Grok or Antigravity looked idle, and the combined totals were short by whatever those tools did.

T3 Code counts both:

- **Grok**: each turn's `turn_completed` update in `sessions/<cwd>/<session>/updates.jsonl` now splits usage by model (`modelUsage`) and logs what it cost (`costUsdTicks`, ten billion to the dollar).
- **Antigravity**: each conversation is a SQLite database whose `steps` and `gen_metadata` rows hold protobuf metadata with every model call's usage and ids. This covers the CLI, the IDE and the profiles T3 Code runs Antigravity with.

Tinybar reads both the same way, in `Usage/ForkHistory.swift`, into the same daily rows as the other logs. Grok's files are append-only and read by byte offset. Antigravity's databases are read whole whenever the database or its WAL changes, in place rather than copied (one can be close to 100 MB). A call is known by any of its ids, since Antigravity files it under its step and its generation, and a fuller later copy adds only the difference. Each conversation's workspace gives the project. Step rows name the model only by number, so the number is named from the same database's generation rows; newer models aren't in T3 Code's table.

## Pricing

- Grok is priced at the cost its CLI logged. models.dev lists `grok-4.7`, but not the CLI's `-build` models, and the logged cost for `grok-4.7-build-fast` is exactly twice `grok-4.7`'s rates, so a guessed mapping would be wrong.
- Antigravity's Gemini, Claude and GPT models are priced from Google's, Anthropic's and OpenAI's models.dev tables. A thinking level shares its model's price, and Google's names drop `-preview`. A model models.dev doesn't list (`gemini-4-argon-trial`) stays unpriced.

## Consequences

- Stats counts every Provider's tokens and cost. Prompts, tool calls and the other Activity figures still come from Claude Code and Codex only, and the note about partly read Activity covers only those two. On the card, Claude and Codex keep its two tones and the others take their own colour; Gemini's is now its spark's green, as its blue was Grok's on a chart.
- Both formats are undocumented and T3 Code's readers are the reference. If either changes, a file reads as nothing until the reader follows; it never stops the other sources.
- The SSH hosts' history counts too, under each host (FORK.md). Grok's files are streamed like their Claude Code logs. Antigravity's databases can't be opened over SSH, so each one that changed is snapshotted there with `sqlite3 .backup` (read-only, so a write mid-copy can't tear it), sent compressed, read here and deleted. The first read of a host copies all of them (about 430 MB, two minutes for `mini`); later ones copy only conversations that changed. A response already counted on another machine, as a copied session holds it, counts once, under the machine first read.
