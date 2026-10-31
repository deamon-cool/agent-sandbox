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
2. **Start:** `run.sh` mounts your code as `/workspace` (secrets and hidden paths empty, git and auto-run files read-only), and the profile and `test/` read-only.
3. **Entrypoint (root, then drops to your user):** merges settings, writes the system CLAUDE.md, starts the proxy, closes the firewall, self-tests the policy, starts `claude`.

## Security model

| Layer | What it does |
|---|---|
| Egress | Only the proxy user may leave the container (iptables). HTTPS to listed hosts only, port 443 only. DNS is blocked for everyone else. |
| Host classes | Every connection is classified once (table below): Anthropic API, documentation, or an opaque tunnel. Anything unlisted is refused. |
| Anthropic API | Decrypted and filtered: Claude Code's own calls pass (messages, OAuth, docs). Files API, batches, foreign API keys (blocked even in learn mode), image/PDF `url` sources, `mcp_servers`/`container` and WebSocket upgrades are blocked. Server tools are an allowlist (web search, tool search): web fetch, code execution, MCP and any server tool Anthropic adds later stay blocked until reviewed. A body with a repeated JSON key is refused, so the proxy and the API can never read two different requests. This stops the known exfiltration of repos to an attacker's account through `api.anthropic.com`. |
| Documentation | Decrypted and shaped down to reading: GET/HEAD only, no request body, no connection upgrade (WebSocket), path ≤ 256 B, query ≤ 96 B, headers ≤ 2 kB, `authorization`/`cookie`/`x-api-key` stripped. A doc host cannot be used to post code out, and request sizes are logged. |
| Secrets & private code | Secrets look empty by default (`.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `.npmrc`, `.pypirc`, `.netrc`, `*.tfstate`, `*.tfvars`), so their values never reach the agent or Anthropic; templates (`.env.example`, `.env.sample`, `.env.template`, `.env.dist`) stay readable and writable, so the agent documents new variables there. `masked.txt` adds patterns, `!name` keeps one readable (read-only). `hidden.txt` paths (files or folders, e.g. code that must not leave your machine) look empty too. Masking cannot reach git history, so if git tracks a masked or hidden file, `run.sh` refuses to start unless `.git` is hidden as well. |
| Files | Read-only: `.git` (every nested repo and submodule too), `.claude`, `CLAUDE.md`, `readonly.txt` paths, `!name` files, and what your host runs without a second look: the `core.hooksPath` folder, `.husky`, `.githooks`, `.pre-commit-config.yaml`, lefthook configs, `.vscode`, `.devcontainer`. A missing `.git` or `.claude` is covered by an empty read-only folder, so the agent cannot plant one. The profile and `test/` are read-only; nothing else of this repo is mounted. |
| Policy | Root-owned managed settings: only managed permission rules, hooks and MCP servers apply; bypass mode, artifacts, claude.ai connectors, plugin marketplaces and auto memory are off; claude.ai login is forced. Instruction files and `.env`/`*.pem`/`*.key` are denied to **every** write tool (Write, Edit, NotebookEdit) through `Edit(...)` rules, which Claude Code applies to all of them. Other `.env.*` files are guarded by the mounts instead (masked, or read-only for `!name`), because a deny rule always beats an allow rule and would also lock the templates. |
| Persistence | Every start wipes the login volume down to the login (`.claude.json`, `.claude/.credentials.json`), transcripts and prompt history: skills, agents, rules, settings, plugins, memory, shell and tool dotfiles (`.bashrc`, `.gitconfig`, `.yarnrc`, ...) and caches all go. Bash can still write into `/home/claude` mid-session — the unconditional keep-list wipe, plus `claudeMdExcludes` over `/home/claude/**`, is what makes anything self-written (a skill, a git setting that runs code, a shell rc file) unable to reach the next session. From the project, Claude Code loads only the root `CLAUDE.md`, mounted read-only. `run.sh` refuses to start when `CLAUDE.local.md`, a nested `.claude/` (folder or symlink) or an untracked root `CLAUDE.md` exists in the project, and after every session it lists any `.git`, `.claude` or `CLAUDE.local.md` the agent created. |
| Limits | CPU, memory, PIDs, shm from `.env`; disk from the profile's `tmpfs.txt` — `/tmp` (and `/var/tmp`, a link to it) is a size-capped RAM-backed mount, so a runaway test run or database hits `ENOSPC` there instead of filling the host disk. `/workspace` and the login volume are not capped. |
| Versions | Every `build` takes the newest Debian packages and the newest Claude Code (unless `CLAUDE_CODE_VERSION` in the root `.env` holds it), so security patches arrive by rebuilding; the auto-updater stays off, so nothing moves mid-session. Nothing here depends on a frozen version: a package change that breaks the proxy policy cannot slip through — the addon fails to load or the start-up self-test fails, and the container refuses to start. |
| Fail closed | Invalid profile, domain or setting → no start. At every start the proxy must refuse, with its own reason, an unknown host, a tunnel host's TLS SNI on another host, a foreign API key, a forbidden Anthropic route, a `url` source in a message, an unknown server tool and a write to a doc host, or the container does not start. A proxy crash closes the network; the watchdog restarts it and repeats the self-test. |

### Host classes

| Class | Source | TLS | Rule |
|---|---|---|---|
| `api` | Anthropic hosts, fixed in `proxy-policy.py` | intercepted | route allowlist + `/v1/messages` body inspection |
| `docs` | `base/allowed-domains.txt` + profile `allowed-domains.txt` + `EXTRA_DOC_DOMAINS` | intercepted | GET/HEAD, no body, no upgrade, URL and header budget, credentials stripped |
| `tunnel` | profile `tunnel-domains.txt` | passthrough | host and TLS SNI checked (must match), bytes not — for the app's own runtime calls |

Clients inside the container trust the proxy CA (system store and `NODE_EXTRA_CA_CERTS`). A browser with its own certificate store (Chromium/Electron outside Cypress) may not — that is the other reason a runtime host belongs in `tunnel-domains.txt`.

### Residual risks

- Your code is sent to Anthropic's API; that is how Claude works. Whatever must not leave your machine goes in `hidden.txt` (and `.git` with it, if git tracks it).
- Masking reaches files, not history: a secret that was ever committed stays readable in `.git` even after you untrack it (`run.sh` only sees what git tracks now). Rotate it, or hide `.git`.
- Masking happens at start: a secret file you create while the agent runs stays visible and writable until the next start.
- The agent can run code inside the container (linters, tests, a twin app): the network rules, not permission prompts, are the real boundary.
- Files the agent may write are later executed **on your host** by your own commands — tool configs (vite/eslint/jest/tsconfig), `scripts/`, migrations. Git hooks, `.vscode` and `.devcontainer` are read-only by default; review the other diffs first, or add them to `readonly.txt` for tasks that don't need them.
- The agent can create a `.git` in any folder it writes, and a `.git` config runs commands as soon as git, a git-aware shell prompt or an editor touches that folder on your host. `run.sh` lists new ones when the session ends: read that warning before you `cd` there.
- A `tunnel-domains.txt` host is an unfiltered CONNECT. If it is a large CDN edge, a deliberate client can reach other sites behind that CDN. Keep the list to hosts your app must call.
- WebSearch runs on Anthropic's side, so its results can come from any site (prompt-injection source). Full pages are fetched only from listed hosts, read-only.
- List only doc hosts where nobody else can publish. An exact single-project GitHub Pages host (`kysely-org.github.io`) qualifies; `github.com`, gists, `*.githubusercontent.com`, `npmjs.com`, `stackoverflow.com` and any wildcard over a shared suffix do not.
- `/workspace` is your own filesystem: the agent can fill it. The disk cap covers `/tmp`, not your project folder or the login volume (wiped down to the login at the next start).
- A missing `.git` or `.claude` is covered by an empty read-only folder; Docker leaves that empty, root-owned folder in your project. Git ignores it; `rmdir` removes it.
- The login token lives in the agent's login volume (Claude Code needs it); the proxy rules keep it from leaving, and doc hosts never see an `authorization` header. Requests to the allowed Anthropic routes are not tied to your token, so keep the route list minimal.
- `learn` mode reports content violations instead of blocking them (the host allowlist and the foreign-API-key block still hold): run it on an empty project, never on real code, and only while you watch.

## Requirements

- Linux host with Docker and the `xt_owner` kernel module (`sudo modprobe xt_owner`).
- Claude Pro or Max subscription.

## Quick start

1. Optional: `cp .env.example .env` to change shared defaults (proxy mode, limits, Claude Code version).
2. `cp -r profiles/example profiles/my-app`, then `cp profiles/my-app/.env.example profiles/my-app/.env`: set `PROJECT_PATH` and your stack (`BUILD_*`, read by the profile `Dockerfile`).
3. Secrets are masked by default. List anything else private in `profiles/my-app/hidden.txt`.
4. Review the project's existing `.claude/` folder: it is mounted read-only but still loaded.
5. `chmod +x run.sh && ./run.sh my-app build`
6. Optional, to record Claude Code's calls on an empty project: `PROJECT_PATH=$(mktemp -d) AGENT_PROXY_MODE=learn ./run.sh my-app --name learn`, then `/login`, send a prompt, try one WebSearch and one WebFetch. In a second terminal: `./run.sh my-app --name learn proxy-log`. Lines with `"would_block"` are calls that enforce mode stops; add the legitimate ones to `base/proxy-policy.py` and rebuild.
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
| `BUILD_<ARG>` | profile `.env` only | your stack: passed as build arg `<ARG>` to the profile `Dockerfile` (e.g. `BUILD_NODE_IMAGE`) |
| `CLAUDE_CODE_VERSION` | root `.env` only | `latest` (default), `stable` or a version number; one base image serves every profile |
| `AGENT_PROXY_MODE` | either | `enforce` (default) or `learn` |
| `EXTRA_DOC_DOMAINS` | either | extra doc hosts, space separated |
| `AGENT_CPUS`, `AGENT_MEMORY`, `AGENT_PIDS`, `AGENT_SHM` | either | container limits (default 4, 8g, 2048, 1g) |

Disk is not here: it is per profile in `tmpfs.txt`, because only the profile knows whether it runs a database.

## Profile files

| File | Applied at | Purpose |
|---|---|---|
| `Dockerfile` | build | tools to install, `FROM ${BASE_IMAGE}` (required); its `ARG`s come from `BUILD_*` in `.env` |
| `.env` | build, start | `PROJECT_PATH`, the `BUILD_*` stack and per-profile overrides (gitignored) |
| `allowed-domains.txt` | start | doc hosts, one per line; `*.example.com` = its subdomains |
| `tunnel-domains.txt` | start | the app's runtime hosts, exact names, not content-filtered |
| `readonly.txt` | start | project paths mounted read-only |
| `hidden.txt` | start | project paths (files or folders) that always look empty: code or data that must not leave your machine |
| `masked.txt` | start | more file name patterns that always look empty, on top of the secret defaults; `!name` keeps a file readable |
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

- Claude Code and Debian packages: `./run.sh <profile> build` — it always takes the newest. Set `CLAUDE_CODE_VERSION` in the root `.env` to a version number if you ever need to hold it still.
- Your stack: change `BUILD_*` in the profile `.env`, then `./run.sh <profile> build`.
- A request refused with `tool <type>` is a server tool the policy has not reviewed: add its prefix to `API_ALLOWED_TOOL_PREFIXES` in `base/proxy-policy.py` only if it cannot fetch URLs, run code or reach other services.
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
| `masked or hidden files are tracked by git` | untrack them (`git rm --cached`, and rotate a committed secret), keep them readable with `!name` in `masked.txt`, or add `.git` to `hidden.txt` |
| `hidden path does not exist (typo?)` | fix the path in `hidden.txt` |
| `core.hooksPath is the project root` | move the hooks into a folder and point `core.hooksPath` there |
| `WARNING: created during the session` | inspect the listed `.git`/`.claude` before running git there; delete what you did not expect |
| `HOST_GID ... collides with the proxy group` | run as a user whose primary group is not 65533 |
| `ENOSPC` inside the container | raise the `/tmp` size in the profile's `tmpfs.txt` (it counts against `AGENT_MEMORY`) |
| login asked again | every `--name` has its own login volume |
