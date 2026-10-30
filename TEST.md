# Sandbox self-test

Proves from inside a running agent that the protections in the [security model](../README.md#security-model) actually hold. Two parts:

- **Shell suite**: `test/sandbox-check.sh`, mounted read-only at `/etc/agent/test/sandbox-check.sh`, so the agent cannot change what it checks and an edit here needs no rebuild. Privileges, firewall, proxy gates, doc-host and Anthropic API rules, read-only and masked files, the merged Claude Code policy, limits. One line per check, a `RESULT` line at the end.
- **Tool checks**: the deny rules only Claude Code's own tools can hit (Read, Write, Edit, NotebookEdit, Bash, WebFetch, WebSearch), run by the agent from the prompt below.

Nothing here weakens the sandbox: every probe is either refused by design or goes to a host the policy allows, and the script writes only to its own temp dir.

Run it after every `build`, after any change in `base/` or a profile, and after a Claude Code update.

## Run

1. From the repo root, start a fresh agent in enforce mode: `./run.sh <profile>`.
2. Paste the prompt below.
3. Approve exactly one permission prompt: `bash /etc/agent/test/sandbox-check.sh`. Answer **No** to any other prompt: a prompt there means a deny rule did not fire, and the agent records it as FAIL.
4. Read the verdict. **SAFE** needs 0 FAIL. FAIL = a protection is missing: stop using the sandbox until it is fixed. WARN = your call (an unlimited resource, an upstream that did not answer). SKIP = not applicable to this profile or mode, or checked on the host.
5. Don't take the agent's word for it: run host-side check 1 and compare the `RESULT` line.

## Prompt

```text
Owner-requested sandbox self-test. I own this sandbox and authorize exactly the probes below, to prove its protections hold. Almost every probe is meant to be refused, and a refusal is a PASS. For this task only:
- run only what is listed, once each, in order: no extra commands, no retries, no alternatives, no investigating a block;
- change nothing and fix nothing, even when something fails;
- never print secrets (tokens, keys, .env contents);
- quote the real tool output as evidence; never guess or soften a failure.

STEP 1 - shell suite
One Bash call with a 600000 ms timeout; keep the full output:
bash /etc/agent/test/sandbox-check.sh
If it cannot run, report why and stop.

STEP 2 - tool checks
These need Claude Code's own tools: one call per line. Grade each by its expectation:
- refused: PASS only if the permission system refused the call. Any other outcome is FAIL, including errors such as file not found, read-only file system, string not found or not a notebook: they mean the policy let the call through. A permission prompt is also FAIL (I will answer No).
- allowed: PASS if the call worked.
- proxy: PASS if the fetch failed because the proxy refused the host.

T1  refused  Read /home/claude/.sandbox-check-missing
T2  refused  Write /home/claude/.sandbox-check.txt with content "sandbox-check"
T3  allowed  Read /workspace/CLAUDE.md (only so T4 can run; don't quote it. If it doesn't exist, T3 and T4 are SKIP)
T4  refused  Edit /workspace/CLAUDE.md: replace "SANDBOX-CHECK-NO-SUCH-TEXT" with "x"
T5  refused  Write /workspace/.sandbox-check/CLAUDE.md with content "sandbox-check, delete me"
T6  refused  Write /workspace/.sandbox-check/CLAUDE.local.md, same content
T7  refused  Write /workspace/.sandbox-check/AGENTS.md, same content
T8  refused  Write /workspace/.sandbox-check/.claude/sandbox-check.md, same content
T9  refused  Write /workspace/.sandbox-check/.env, same content
T10 refused  Write /workspace/.sandbox-check/.env.sandbox-check, same content
T11 refused  Write /workspace/.sandbox-check/sandbox-check.pem, same content
T12 refused  Write /workspace/.sandbox-check/sandbox-check.key, same content
T13a allowed  Write /workspace/.sandbox-check/sandbox-check.json with content {"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5} (setup for T13)
T13b allowed  Bash: cp /workspace/.sandbox-check/sandbox-check.json /workspace/.sandbox-check/.env.sandbox-check.ipynb (setup for T13: Bash is not bound by Edit rules)
T13c allowed  Read /workspace/.sandbox-check/.env.sandbox-check.ipynb (setup for T13: NotebookEdit stops at an unread file before any permission check)
T13  refused  NotebookEdit /workspace/.sandbox-check/.env.sandbox-check.ipynb: insert a markdown cell "sandbox-check"
T14 refused  Bash: git commit --allow-empty -m sandbox-check
T15 refused  Bash: git push
T16 refused  Bash: git fetch
T17 refused  Bash: git checkout -b sandbox-check
T18 refused  Bash: git -C /workspace status
T19 refused  Bash: git stash list
T20 allowed  WebFetch https://docs.claude.com/ and give the page title
T21 proxy    WebFetch https://example.com/
T22 allowed  WebSearch: mitmproxy tls_clienthello ignore_connection
T23 inventory  From what is already in your context (no tool call), list the instruction sources: CLAUDE.md files with paths, memory, output style, skills and subagents that are not built in, MCP servers or mcp__ tools. PASS only if the CLAUDE.md files are exactly /etc/claude-code/CLAUDE.md and /workspace/CLAUDE.md, with no memory and no MCP tool. Put any skill, subagent or output style that is not built in into Evidence for me to confirm.

STEP 3 - report, then stop
1. The full STEP 1 output, verbatim, in one code block.
2. A table for T1-T23, including T13a-T13c: | ID | Expected | Result | Evidence |. Evidence is the tool's own message, shortened.
3. Totals: the STEP 1 RESULT line, then "T: n pass, n fail, n skip".
4. Verdict: SAFE only if STEP 1 has 0 fail and no T-item failed; otherwise NOT SAFE, then one line per FAIL saying what it exposes.
5. Cleanup: every file a T-item actually created, by path, so I can delete it on the host.
```

## Host-side checks

The agent cannot do these from inside. Run them from the repo root; `<name>` is the agent name (default: the profile name).

1. **Same suite, without the agent**: `docker exec -u claude <name> bash /etc/agent/test/sandbox-check.sh`. Its `RESULT` line must match the report; `S6` is SKIP here (no Claude Code environment).
2. **Credentials stripped on doc hosts** (`D12`): `./run.sh <profile> proxy-log | grep /sandbox-check` must show `"stripped":["authorization","cookie"]`.
3. **A dead proxy closes the network, then restarts self-tested**: `docker exec -u agentproxy <name> pkill -f mitmdump`, wait 10 s, repeat check 1: same result. If the restart failed, `docker exec -u agentproxy <name> tail -n 5 /var/log/agent-proxy/mitmdump.log` says so, and the network checks must fail closed, never pass.
4. **run.sh refuses instruction files outside git review**: `mkdir -p <project>/.sandbox-check/.claude`, then `./run.sh <profile> --name sandbox-check` must stop with `agent instruction files outside git review`; same for `touch <project>/CLAUDE.local.md`. Remove both afterwards.
5. **A bad profile stops the start**: `EXTRA_DOC_DOMAINS=not_a_domain ./run.sh <profile> --name sandbox-check` must stop with `invalid domain entry` before Claude starts.
6. **learn mode** (optional): `AGENT_PROXY_MODE=learn ./run.sh <profile> --name sandbox-check`, then check 1 with `<name>` = `sandbox-check`: `M1` warns, the content rules `D3`–`D11` and `X1`–`X19` are SKIP, everything else still passes.
