# agent-sandbox

Hardened Docker sandbox for Claude Code with a Claude Pro/Max login: one secure base image, one small profile per project. Any stack — the profile brings the toolchain, the base brings the security.

## Layout

```
agent-sandbox/
├── base/                     security for every profile (never edit per profile)
│   ├── Dockerfile            Debian + Claude Code (native) + mitmproxy + firewall tools
│   ├── entrypoint.sh         applies the profile, locks the network, starts Claude as your user
│   ├── proxy-policy.py       the whole egress policy: host classes and request rules
│   ├── managed-settings.json Claude Code policy, merged with the profile's
│   ├── managed-mcp.json      MCP disabled
│   ├── CLAUDE.md             rules for every profile
│   └── allowed-domains.txt   Claude doc hosts for every profile
├── profiles/
│   ├── example/              template, committed (.env.example inside)
│   └── <your-profile>/       real profiles with their own .env, gitignored
├── test/                     mounted read-only at /etc/agent/test
│   ├── TEST.md               self-test: agent prompt + host-side checks
│   └── sandbox-check.sh      checks every protection from inside a running agent
├── run.sh                    ./run.sh <profile> [start|build|proxy-log]
├── .env.example              shared defaults, copy to .env (optional)
└── .gitignore
```

## How it works

1. **Build:** `base` image (security), then the profile image `FROM` base (your app's tools).
2. **Start:** `run.sh` mounts your code as `/workspace`, and the profile and `test/` read-only.
3. **Entrypoint (root, then drops to your user):** merges settings, writes the system CLAUDE.md, starts the proxy, closes the firewall, self-tests the policy, starts `claude`.

## Security model

| Layer | What it does |
|---|---|
| Egress | Only the proxy user may leave the container (iptables). HTTPS to listed hosts only, port 443 only. DNS is blocked for everyone else. |
| Host classes | Every connection is classified once (table below): Anthropic API, documentation, or an opaque tunnel. Anything unlisted is refused. |
| Anthropic API | Decrypted and filtered: Claude Code's own calls pass (messages, OAuth, docs). Files API, batches, foreign API keys, server-side web fetch (including image/PDF `url` sources), code execution and MCP are blocked. This stops the known exfiltration of repos to an attacker's account through `api.anthropic.com`. |
| Documentation | Decrypted and shaped down to reading: GET/HEAD only, no request body, path ≤ 256 B, query ≤ 96 B, headers ≤ 2 kB, `authorization`/`cookie`/`x-api-key` stripped. A doc host cannot be used to post code out, and request sizes are logged. |
| Files | `.git`, `.claude`, `CLAUDE.md`, `readonly.txt` paths and every `.env*`/`*.pem`/`*.key` file are read-only (secrets stay readable, but no tool or script can overwrite them); `masked.txt` files look empty; the profile and `test/` are read-only; nothing else of this repo is mounted. |
| Policy | Root-owned managed settings: only managed permission rules, hooks and MCP servers apply; bypass mode, artifacts, claude.ai connectors, plugin marketplaces and auto memory are off; claude.ai login is forced. Instruction files and `.env*`/`*.pem`/`*.key` are denied to **every** write tool (Write, Edit, NotebookEdit) through `Edit(...)` rules, which Claude Code applies to all of them. |
| Persistence | Every start wipes the login volume down to the login (`.claude.json`, `.claude/.credentials.json`), transcripts and prompt history: skills, agents, rules, settings, plugins, memory, shell and tool dotfiles (`.bashrc`, `.gitconfig`, `.yarnrc`, ...) and caches all go. Bash can still write into `/home/claude` mid-session — the unconditional keep-list wipe, plus `claudeMdExcludes` over `/home/claude/**`, is what makes anything self-written (a skill, a git setting that runs code, a shell rc file) unable to reach the next session. From the project, Claude Code loads only the root `CLAUDE.md`, mounted read-only. `run.sh` refuses to start when `CLAUDE.local.md`, a nested `.claude/` or an untracked root `CLAUDE.md` exists in the project. |
| Limits | CPU, memory, PIDs, shm from `.env`; disk from the profile's `tmpfs.txt` — `/tmp` is a size-capped RAM-backed mount, so a runaway build, database or test run hits `ENOSPC` instead of filling the host disk. |
| Versions | Every `build` takes the newest Debian packages and the newest Claude Code, so security patches arrive by rebuilding; the auto-updater stays off, so nothing moves mid-session. Nothing here depends on a frozen version: a package change that breaks the proxy policy cannot slip through — the addon fails to load or the start-up self-test fails, and the container refuses to start. |
| Fail closed | Invalid profile or domain → no start. At every start the proxy must refuse an unknown host, a tunnel host's TLS SNI on another host, a forbidden Anthropic route, a `url` source in a message and a write to a doc host, or the container does not start. A proxy crash closes the network. |

### Host classes

| Class | Source | TLS | Rule |
|---|---|---|---|
| `api` | Anthropic hosts, fixed in `proxy-policy.py` | intercepted | route allowlist + `/v1/messages` body inspection |
| `docs` | `base/allowed-domains.txt` + profile `allowed-domains.txt` + `EXTRA_DOC_DOMAINS` | intercepted | GET/HEAD, no body, URL and header budget, credentials stripped |
| `tunnel` | profile `tunnel-domains.txt` | passthrough | host and TLS SNI checked (must match), bytes not — for the app's own runtime calls |

Clients inside the container trust the proxy CA (system store and `NODE_EXTRA_CA_CERTS`). A browser with its own certificate store (Chromium/Electron outside Cypress) may not — that is the other reason a runtime host belongs in `tunnel-domains.txt`.

### Residual risks

- Your code is sent to Anthropic's API; that is how Claude works.
- The agent can run code inside the container (linters, tests, a twin app): the network rules, not permission prompts, are the real boundary.
- Files the agent may write are later executed **on your host** by your own commands — tool configs (vite/eslint/jest/tsconfig), `scripts/`, migrations. Review those diffs first, or add them to `readonly.txt` for tasks that don't need them.
- A `tunnel-domains.txt` host is an unfiltered CONNECT. If it is a large CDN edge, a deliberate client can reach other sites behind that CDN. Keep the list to hosts your app must call.
- WebSearch runs on Anthropic's side, so its results can come from any site (prompt-injection source). Full pages are fetched only from listed hosts, read-only.
- List only doc hosts where nobody else can publish. An exact single-project GitHub Pages host (`kysely-org.github.io`) qualifies; `github.com`, gists, `*.githubusercontent.com`, `npmjs.com`, `stackoverflow.com` and any wildcard over a shared suffix do not.
- `/workspace` is your own filesystem: the agent can fill it. The disk cap covers the container, not your project folder.
- The login token lives in the agent's login volume (Claude Code needs it); the proxy rules keep it from leaving, and doc hosts never see an `authorization` header.
- `learn` mode reports content violations instead of blocking them (the host allowlist still holds): use it briefly while you watch.

## Requirements

- Linux host with Docker and the `xt_owner` kernel module (`sudo modprobe xt_owner`).
- Claude Pro or Max subscription.

## Quick start

1. Optional: `cp .env.example .env` to change shared defaults (proxy mode, limits).
2. `cp -r profiles/example profiles/my-app`, then `cp profiles/my-app/.env.example profiles/my-app/.env` and set `PROJECT_PATH`.
3. Review the project's existing `.claude/` folder: it is mounted read-only but still loaded.
4. `chmod +x run.sh && ./run.sh my-app build`
5. First run, to record Claude Code's calls: `AGENT_PROXY_MODE=learn ./run.sh my-app`, then `/login`, send a prompt, try one WebSearch and one WebFetch.
6. In a second terminal: `./run.sh my-app proxy-log`. Lines with `"would_block"` are calls that enforce mode stops; add the legitimate ones to `base/proxy-policy.py` and rebuild.
7. Daily use: `./run.sh my-app`.

## Commands

| Command | Does |
|---|---|
| `./run.sh` | help: commands, settings, your profiles, examples |
| `./run.sh my-app` | start the agent (builds images when missing or changed) |
| `./run.sh my-app build` | rebuild base and profile images from scratch (newest packages) |
| `./run.sh my-app proxy-log` | in a second terminal while the agent runs: its last 200 proxy decisions |
| `./run.sh my-app --name second` | a second agent with its own login volume |
| `AGENT_MEMORY=12g ./run.sh my-app` | override any setting for one run |

Reuse an old login volume: `docker run --rm -v OLD_VOLUME:/from -v claude-home-<profile>:/to busybox cp -a /from/. /to/`

## Settings

Order of precedence: shell variable > `profiles/<profile>/.env` > root `.env` > built-in default.

| Key | Where | Meaning |
|---|---|---|
| `PROJECT_PATH` | profile `.env` only | absolute path of the code to mount |
| `AGENT_PROXY_MODE` | either | `enforce` (default) or `learn` |
| `EXTRA_DOC_DOMAINS` | either | extra doc hosts, space separated |
| `AGENT_CPUS`, `AGENT_MEMORY`, `AGENT_PIDS`, `AGENT_SHM` | either | container limits (default 4, 8g, 2048, 1g) |

Disk is not here: it is per profile in `tmpfs.txt`, because only the profile knows whether it runs a database.

## Profile files

| File | Applied at | Purpose |
|---|---|---|
| `Dockerfile` | build | tools to install, `FROM ${BASE_IMAGE}` (required) |
| `.env` | start | `PROJECT_PATH` and per-profile overrides (gitignored) |
| `allowed-domains.txt` | start | doc hosts, one per line; `*.example.com` = its subdomains |
| `tunnel-domains.txt` | start | the app's runtime hosts, exact names, not content-filtered |
| `readonly.txt` | start | project paths mounted read-only |
| `masked.txt` | start | file names that always look empty (opt-in; no default list) |
| `tmpfs.txt` | start | `path size` size-capped scratch: `/tmp 2g` is the disk cap, `backend/tmp 16m` hides the host's folder |
| `managed-settings.json` | start | extra allow/deny rules; merged with base, base wins on conflicts |
| `CLAUDE.md` | start | sandbox notes for this project, appended to the system CLAUDE.md |
| `bin/*` | start | commands the agent can run (e.g. `twin`) |

Edit a start-time file → restart. Edit the `Dockerfile` → `./run.sh <profile> build`.

Profile `managed-settings.json` arrays are merged, not replaced: a profile can only **add** allow rules on top of base. Base's deny list always wins, so keep profile allows narrow.

## Instruction layers

Three `CLAUDE.md` files, three scopes:

| File | Scope | Holds |
|---|---|---|
| `base/CLAUDE.md` | **every** project | the contract: what the sandbox blocks, how to use docs and web, KISS/triage/response modes, your expertise rules. Baked into the base image. |
| `profiles/<name>/CLAUDE.md` | **one app, in the sandbox** | how to work inside the container: scoped git for a partial mount, profile commands, the `/tmp` cap, tunnel hosts, where to put notes. Mounted read-only from the profile folder. |
| the project repo's root `CLAUDE.md` | **one app, anywhere** | facts about the app itself: stack, architecture, deploy rules. Tracked in that repo, mounted read-only. |

At start the entrypoint glues the first two into one system-level file — `base/CLAUDE.md`, then generated "Sandbox facts" (read-only paths, masks, scratch mounts, commands, host classes, proxy mode), then the profile's. The project's own `CLAUDE.md` is loaded separately as project instructions; other `CLAUDE.md` files in the project are ignored.

**Where a new rule goes:**

- true no matter the project → `base/CLAUDE.md`
- true only because it runs in a container (mounts, commands, a twin app) → the profile's
- true about the app even without the sandbox → the project repo's

The last one is the test worth remembering: if the rule would still matter when you code by hand, it belongs in the repo.

The agent cannot write any of them. To let it contribute rules anyway, give the profile an ordinary tracked file (e.g. `docs/AGENT-NOTES.md`) and tell it in the profile `CLAUDE.md` to append candidate lines there: it is plain data, it shows up in your diff review, and nothing applies until you move it into `CLAUDE.md` yourself. Same trick for a roadmap the agent keeps up to date — a tracked file you can diff beats hidden memory, which is off here on purpose.

## Updating

- Claude Code and Debian packages: `./run.sh <profile> build` — it always takes the newest. Set `CLAUDE_CODE_VERSION` in `base/Dockerfile` to a version number if you ever need to hold it still.
- After an agent update, watch the start-up for `Deny rule ... never matches` warnings: file deny rules are written as `Edit(...)`, which Claude Code applies to every write tool, and the self-test's tool checks prove each one is still refused.
- Proxy routes and budgets: `base/proxy-policy.py`. Keep them minimal: every route is a way out.
- After every build, base or profile change: run the self-test in `test/TEST.md`.

## Publishing this repo

`profiles/*` is gitignored except `profiles/example`, so real profiles stay local. If older commits contain project details, publish from a fresh repository.

## Troubleshooting

| Message | Fix |
|---|---|
| `iptables owner match unavailable` | `sudo modprobe xt_owner` on the host |
| `proxy policy is not active` | `docker exec -u agentproxy <name> cat /var/log/agent-proxy/mitmdump.log` |
| `blocked by agent proxy: method POST (doc hosts are read-only)` | correct: doc hosts take GET/HEAD only. Runtime hosts go in `tunnel-domains.txt` |
| `blocked by agent proxy: query over 96 bytes` | the URL carries too much; fetch the doc page itself, or raise the budget in `proxy-policy.py` |
| `blocked by agent proxy: ...` (anything else) | run once with `AGENT_PROXY_MODE=learn`, then check `./run.sh <profile> proxy-log` |
| `is in both allowed-domains.txt and tunnel-domains.txt` | pick one class for that host |
| `agent instruction files outside git review` | review the listed files, move anything useful into a tracked CLAUDE.md, delete them |
| `CLAUDE.md is not tracked by git` | review it, then commit or delete it |
| `invalid domain entry` | fix the line in `allowed-domains.txt` or `EXTRA_DOC_DOMAINS` |
| `ENOSPC` inside the container | raise the `/tmp` size in the profile's `tmpfs.txt` (it counts against `AGENT_MEMORY`) |
| login asked again | every `--name` has its own login volume |
