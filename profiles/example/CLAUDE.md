# example sandbox

## Commands
- After code changes: `npm run typecheck`, `npm run lint`, then `npm test`.
- Never install, update or remove packages — tell me which one and why, then stop.

## Layout
- Source lives in `src/`, tests in `test/`.

## Roadmap & notes (docs/)
- `docs/ROADMAP.md`: the plan. Append and mark items done when a feature lands; never rewrite history.
- `docs/AGENT-NOTES.md`: append-only lessons for your next session, each written as a line I could paste into the root CLAUDE.md. Newest last, one line each.
- Both are plain data: only the root CLAUDE.md is loaded as instructions, so nothing you write here changes your own rules. I decide what moves into CLAUDE.md.
