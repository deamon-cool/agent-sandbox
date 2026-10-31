#!/usr/bin/env bash
#
# Sandbox self-check: one line per protection, exit 1 on any FAIL (see TEST.md).
# Runs as the agent user inside the container, from the agent or from the host:
#   docker exec -u claude <name> bash /etc/agent/test/sandbox-check.sh
# Probes are meant to be refused; the only requests that leave the container go
# to hosts the policy allows. Writes nothing outside its own temp dir.
#
set -uo pipefail

PROXY=http://127.0.0.1:8118
CC=/etc/claude-code
HOME_DIR=/home/claude
API=api.anthropic.com
MARK='blocked by agent proxy'
PASS=0
FAIL=0
WARN=0
SKIP=0
CODE=
BODY=

if [ "$(id -u)" -eq 0 ]; then
  echo "sandbox-check: run it as the agent user: docker exec -u claude <name> bash $0" >&2
  exit 2
fi
if [ ! -r "$CC/CLAUDE.md" ] || [ ! -r "$CC/proxy-ca.pem" ]; then
  echo "sandbox-check: not inside a started sandbox ($CC is incomplete)" >&2
  exit 2
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

result() {
  local status="$1" id="$2" text="$3" detail="${4:-}"
  case "$status" in
    PASS) PASS=$((PASS + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
    WARN) WARN=$((WARN + 1)) ;;
    *) SKIP=$((SKIP + 1)) ;;
  esac
  detail="${detail//$'\n'/ }"
  printf '%-4s %-4s %s%s\n' "$status" "$id" "$text" "${detail:+ -- ${detail:0:160}}"
}

# id text command...: PASS when the command succeeds
works() {
  local id="$1" text="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then result PASS "$id" "$text"; else result FAIL "$id" "$text" "failed: $1"; fi
}

# id text command...: PASS when the command fails
refused() {
  local id="$1" text="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then result FAIL "$id" "$text" "succeeded: $*"; else result PASS "$id" "$text"; fi
}

fact() {
  sed -n "s|^- $1: ||p" "$CC/CLAUDE.md" | head -n 1
}

pad() {
  head -c "$1" /dev/zero | tr '\0' a
}

send() {
  rm -f "$TMP/body"
  CODE="$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 20 -x "$PROXY" "$@" 2>/dev/null || true)"
  BODY="$(cat "$TMP/body" 2>/dev/null || true)"
}

# id text reason curl-args...: PASS when the proxy itself answers 403 for that reason
blocked() {
  local id="$1" text="$2" reason="$3"
  shift 3
  send "$@"
  if [ "$CODE" = 403 ] && [[ $BODY == *"$MARK: $reason"* ]]; then
    result PASS "$id" "$text" "$reason"
  else
    result FAIL "$id" "$text" "HTTP $CODE ${BODY:-(no body)}"
  fi
}

# learn mode reports content violations instead of blocking them
content() {
  if [ "$MODE" = learn ]; then
    result SKIP "$1" "$2" "learn mode reports instead of blocking"
  else
    blocked "$@"
  fi
}

# id text curl-args...: PASS when the request reaches the real host
passes() {
  local id="$1" text="$2"
  shift 2
  send "$@"
  if [[ $BODY == *"$MARK"* ]]; then
    result FAIL "$id" "$text" "$BODY"
  elif [ "$CODE" = 000 ]; then
    result WARN "$id" "$text" "no answer from upstream"
  else
    result PASS "$id" "$text" "upstream HTTP $CODE"
  fi
}

# id text url: PASS when the proxy refuses the CONNECT
connect_refused() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_connect}' --max-time 15 -x "$PROXY" "$3" 2>/dev/null || true)"
  if [ "$code" = 403 ]; then result PASS "$1" "$2"; else result FAIL "$1" "$2" "CONNECT answered $code"; fi
}

message() {
  printf '{"model":"sandbox-check","max_tokens":1,"messages":[{"role":"user","content":[%s]}]}' "$1"
}

# id text reason json [path]
api_body() {
  content "$1" "$2" "$3" -H 'content-type: application/json' --data "$4" "https://$API${5:-/v1/messages}"
}

# id text cgroup-file
limit() {
  local value
  value="$(cat "$3" 2>/dev/null)"
  if [ -z "$value" ]; then
    result SKIP "$1" "$2" "$3 not found"
  elif [ "${value%% *}" = max ]; then
    result WARN "$1" "$2" "unlimited"
  else
    result PASS "$1" "$2" "$value"
  fi
}

MODE="$(fact 'Proxy mode')"
read -r -a READONLY <<<"$(fact 'Read-only in /workspace')"
read -r -a HIDDEN <<<"$(fact 'Hidden, always empty')"
read -r -a MASKED <<<"$(fact 'Masked, always empty')"
read -r -a UNMASKED <<<"$(fact 'Not masked')"
read -r -a TMPFS <<<"$(fact 'Size-capped tmpfs (RAM-backed, wiped on exit)')"
mapfile -t TUNNELS < <(grep -v '^[[:space:]]*$' "$CC/tunnel-domains.txt" 2>/dev/null)
DOC=docs.claude.com
grep -qxF "$DOC" "$CC/allowed-domains.txt" || DOC="$(grep -v -e '^\*' -e '^[[:space:]]*$' "$CC/allowed-domains.txt" | head -n 1)"
IMAGE_URL='{"type":"image","source":{"type":"url","url":"https://sandbox-check.invalid/x.png"}}'

echo "sandbox-check $(date -u +%FT%TZ) profile=$(fact 'Project profile' | cut -d' ' -f1) mode=${MODE:-unknown} doc-host=$DOC tunnels=${TUNNELS[*]:-none}"
if [ "$MODE" = enforce ]; then
  result PASS M1 "proxy runs in enforce mode"
else
  result WARN M1 "proxy runs in enforce mode" "mode is ${MODE:-unknown}"
fi

echo "== privileges"
result PASS A1 "agent is not root" "uid $(id -u)"
if awk '/^Cap(Inh|Prm|Eff|Amb):/ && $2 !~ /^0+$/ {found = 1} END {exit !found}' /proc/self/status; then
  result FAIL A2 "agent holds no capabilities" "$(grep '^Cap' /proc/self/status | tr '\n' ' ')"
else
  result PASS A2 "agent holds no capabilities"
fi
works A3 "no-new-privileges: setuid files cannot raise privileges" grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status
if command -v sudo >/dev/null 2>&1; then
  refused A4 "no way to root through sudo" sudo -n true
else
  result PASS A4 "no way to root through sudo" "not installed"
fi
proxy_gid="$(getent group agentproxy | cut -d: -f3)"
if [ -n "$proxy_gid" ] && [[ " $(id -G) " != *" $proxy_gid "* ]]; then
  result PASS A5 "agent is not in the proxy's group"
else
  result FAIL A5 "agent is not in the proxy's group" "groups $(id -G), agentproxy gid ${proxy_gid:-missing}"
fi
proxy_pid="$(pgrep -u agentproxy -f mitmdump 2>/dev/null | head -n 1)"
if [ -n "$proxy_pid" ]; then
  refused A6 "agent cannot signal the proxy" kill -0 "$proxy_pid"
else
  result FAIL A6 "agent cannot signal the proxy" "no mitmdump running as agentproxy"
fi
if [ -e /run/agent-proxy ]; then
  refused A7 "proxy CA private key is unreadable" ls /run/agent-proxy
else
  result FAIL A7 "proxy CA private key is unreadable" "/run/agent-proxy is missing"
fi
if [ -e /var/log/agent-proxy ]; then
  refused A8 "proxy logs are unreadable" cat /var/log/agent-proxy/decisions.log
else
  result FAIL A8 "proxy logs are unreadable" "/var/log/agent-proxy is missing"
fi
writable=()
for path in "$CC" "$CC"/* /etc/agent/base /etc/agent/base/* /etc/agent/profile /etc/agent/test /etc/agent/test/* /usr/local/bin /usr/local/share/ca-certificates /etc/ssl/certs; do
  if [ -w "$path" ]; then writable+=("$path"); fi
done
if [ "${#writable[@]}" -eq 0 ]; then
  result PASS A9 "policy, profile, tests, commands and CA store are read-only"
else
  result FAIL A9 "policy, profile, tests, commands and CA store are read-only" "writable: ${writable[*]}"
fi

echo "== network"
refused N1 "no direct TCP out (1.1.1.1:443, no proxy)" timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
refused N2 "no direct UDP out (1.1.1.1:53)" timeout 5 bash -c 'echo x >/dev/udp/1.1.1.1/53'
refused N3 "no DNS for the agent (no data out through lookups)" timeout 5 getent hosts example.com
refused N4 "Docker's DNS server unreachable for the agent" timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.11/53'
if [ -d /proc/sys/net/ipv6 ]; then
  works N5 "IPv6 is off" grep -qx 1 /proc/sys/net/ipv6/conf/all/disable_ipv6
else
  result PASS N5 "IPv6 is off" "kernel without IPv6"
fi
listen="$(awk '$4 == "0A" && $2 ~ /:1FB6$/ {print $2}' /proc/net/tcp | sort -u | tr '\n' ' ')"
if [ "$listen" = "0100007F:1FB6 " ]; then
  result PASS N6 "proxy listens on 127.0.0.1:8118 only"
else
  result FAIL N6 "proxy listens on 127.0.0.1:8118 only" "listening on: ${listen:-nothing}"
fi

echo "== proxy gate"
connect_refused P1 "unknown host refused" https://example.com/
connect_refused P2 "bare IP address refused" https://1.1.1.1/
connect_refused P3 "allowed host on another port refused" "https://$DOC:8443/"
blocked P4 "plain HTTP refused" "not https on 443" "http://$DOC/"
blocked P5 "Host header must name the connected host" "host header mismatch" -H 'Host: example.com' "https://$DOC/"
blocked P6 "TLS SNI must name the connected host" "tls sni mismatch" --connect-to "sandbox-check.invalid:443:$DOC:443" https://sandbox-check.invalid/
if [ "${#TUNNELS[@]}" -eq 0 ]; then
  result SKIP P7 "a tunnel host's name cannot open another host" "no tunnel hosts"
  result SKIP P8 "tunnel hosts are opaque and reachable" "no tunnel hosts"
fi
# trust only the proxy CA: with --cacert alone, Debian's curl still trusts every CA in /etc/ssl/certs
mkdir "$TMP/no-capath"
for tunnel in "${TUNNELS[@]}"; do
  blocked P7 "tunnel name $tunnel cannot open $API" "tls sni mismatch" --connect-to "$tunnel:443:$API:443" "https://$tunnel/"
  blocked P7 "tunnel name $tunnel cannot open $DOC" "tls sni mismatch" --connect-to "$tunnel:443:$DOC:443" "https://$tunnel/"
  curl -s -o /dev/null --max-time 20 -x "$PROXY" --cacert "$CC/proxy-ca.pem" --capath "$TMP/no-capath" "https://$tunnel/" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    result FAIL P8 "tunnel $tunnel is opaque" "the proxy decrypts it"
  elif [ "$rc" -eq 60 ]; then
    passes P8 "tunnel $tunnel is opaque and reachable" "https://$tunnel/"
  else
    result WARN P8 "tunnel $tunnel is opaque and reachable" "curl exit $rc"
  fi
done
if curl -s -o /dev/null --max-time 20 -x "$PROXY" --cacert "$CC/proxy-ca.pem" --capath "$TMP/no-capath" "https://$DOC/" >/dev/null 2>&1; then
  result PASS P9 "doc host traffic is decrypted and inspected"
else
  result FAIL P9 "doc host traffic is decrypted and inspected" "not signed by the proxy CA, or unreachable"
fi

echo "== doc host $DOC"
passes D1 "GET reaches the doc host" "https://$DOC/"
send -I "https://$DOC/"
if [ "$CODE" = 000 ] || [ "$CODE" = 403 ]; then
  result WARN D2 "HEAD reaches the doc host" "HTTP $CODE; a refused HEAD hides its reason, check proxy-log"
else
  result PASS D2 "HEAD reaches the doc host" "upstream HTTP $CODE"
fi
content D3 "POST refused" "method POST" -X POST "https://$DOC/"
content D4 "PUT refused" "method PUT" -X PUT "https://$DOC/"
content D5 "DELETE refused" "method DELETE" -X DELETE "https://$DOC/"
content D6 "GET with a body refused" "request body" -X GET --data x "https://$DOC/"
content D7 "chunked body refused" "request body" -X GET -H 'Transfer-Encoding: chunked' --data x "https://$DOC/"
content D8 "path over 256 bytes refused" "path over 256 bytes" "https://$DOC/$(pad 300)"
content D9 "query over 96 bytes refused" "query over 96 bytes" "https://$DOC/?q=$(pad 120)"
content D10 "headers over 2 kB refused" "headers over 2048 bytes" -H "X-Sandbox-Check: $(pad 2100)" "https://$DOC/"
content D11 "dot-dot path refused" "unsafe path" --path-as-is "https://$DOC/a/../b"
content D13 "WebSocket upgrade refused" "connection upgrade" --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: c2FuZGJveC1jaGVjay0xMg==' "https://$DOC/"
send -H 'Authorization: Bearer sandbox-check' -H 'Cookie: sandbox=check' "https://$DOC/sandbox-check"
result SKIP D12 "credentials are stripped on doc hosts" "check on the host: ./run.sh <profile> proxy-log | grep /sandbox-check"

echo "== Anthropic API"
content X1 "Files API upload refused" "route not allowed" -X POST "https://$API/v1/files"
content X2 "Files API listing refused" "route not allowed" "https://$API/v1/files"
content X3 "Message Batches refused" "route not allowed" -X POST "https://$API/v1/messages/batches"
blocked X4 "foreign API key refused, in learn mode too" "header x-api-key" -H 'x-api-key: sandbox-check' "https://$API/v1/models"
content X5 "dot-dot API path refused" "unsafe path" --path-as-is "https://$API/v1/messages/../files"
content X6 "encoded dot-dot API path refused" "unsafe path" --path-as-is "https://$API/v1/%2e%2e/files"
content X7 "claude.ai route outside OAuth refused" "route not allowed" https://claude.ai/api/organizations
api_body X8 "non-JSON message body refused" "body is not json" 'not json'
api_body X9 "MCP servers in a message refused" "body key mcp_servers" '{"mcp_servers":[]}'
api_body X10 "code-execution container refused" "body key container" '{"container":"sandbox-check"}'
api_body X11 "server-side web fetch refused" "tool web_fetch" '{"tools":[{"type":"web_fetch_20250910","name":"web_fetch"}]}'
api_body X12 "server-side code execution refused" "tool code_execution" '{"tools":[{"type":"code_execution_20250825","name":"code_execution"}]}'
api_body X13 "MCP toolset refused" "tool mcp_toolset" '{"tools":[{"type":"mcp_toolset","mcp_server_name":"sandbox-check"}]}'
api_body X14 "image URL for Anthropic to download refused" "url source" "$(message "$IMAGE_URL")"
api_body X15 "PDF URL for Anthropic to download refused" "url source" "$(message "${IMAGE_URL/image/document}")"
api_body X16 "URL hidden in a tool result refused" "url source" "$(message "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_sandbox\",\"content\":[$IMAGE_URL]}")"
api_body X17 "URL on count_tokens refused" "url source" "$(message "$IMAGE_URL")" /v1/messages/count_tokens
message "$IMAGE_URL" | gzip -c >"$TMP/message.gz"
content X18 "URL inside a gzip body refused" "url source" -H 'content-type: application/json' -H 'content-encoding: gzip' --data-binary "@$TMP/message.gz" "https://$API/v1/messages"
content X19 "unknown body encoding refused" "body decode failed" -H 'content-type: application/json' -H 'content-encoding: sandbox-check' --data '{}' "https://$API/v1/messages"
api_body X22 "unknown server tool refused (allowlist)" "tool sandbox_check" '{"tools":[{"type":"sandbox_check_20990101","name":"sandbox_check"}]}'
api_body X23 "duplicate JSON key refused" "duplicate key tools" '{"tools":[],"tools":[]}'
content X24 "WebSocket upgrade to the API refused" "connection upgrade" --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: c2FuZGJveC1jaGVjay0xMg==' "https://$API/api/claude_code/sandbox-check"
passes X20 "model list reaches Anthropic" "https://$API/v1/models"
passes X21 "clean message reaches Anthropic" -H 'content-type: application/json' --data "$(message '{"type":"text","text":"sandbox-check"}')" "https://$API/v1/messages"
passes X26 "Claude docs start page reaches Anthropic (docs.claude.com redirects there)" https://platform.claude.com/docs
passes X25 "client tools and web search reach Anthropic" -H 'content-type: application/json' \
  --data '{"model":"sandbox-check","max_tokens":1,"tools":[{"name":"Bash","input_schema":{"type":"object"}},{"type":"web_search_20250305","name":"web_search","max_uses":1}],"messages":[{"role":"user","content":"sandbox-check"}]}' \
  "https://$API/v1/messages"

echo "== files"
read_only=0
writable=()
absent=()
for path in "${READONLY[@]}"; do
  if [ ! -e "/workspace/$path" ]; then
    absent+=("$path")
  elif [ -w "/workspace/$path" ]; then
    writable+=("$path")
  else
    read_only=$((read_only + 1))
  fi
done
if [ "${#writable[@]}" -gt 0 ]; then
  result FAIL F1 "read-only project paths cannot be written" "writable: ${writable[*]}"
elif [ "$read_only" -eq 0 ]; then
  result FAIL F1 "read-only project paths cannot be written" "none found in the sandbox facts"
else
  result PASS F1 "read-only project paths cannot be written" "$read_only paths${absent[*]:+, absent: ${absent[*]}}"
fi
if [ "${#MASKED[@]}" -eq 0 ] || [ "${MASKED[0]}" = none ]; then
  result SKIP F2 "masked files read as empty" "no masked patterns"
else
  masked=0
  leaked=()
  keep=()
  if [ "${UNMASKED[0]:-none}" != none ]; then
    for pattern in "${UNMASKED[@]}"; do keep+=(! -name "$pattern"); done
  fi
  for pattern in "${MASKED[@]}"; do
    while IFS= read -r -d '' path; do
      masked=$((masked + 1))
      if [ ! -c "$path" ] && [ -s "$path" ]; then leaked+=("${path#/workspace/}"); fi
    done < <(find /workspace \( -name node_modules -o -name .git -o -path /workspace/.sandbox-check \) -prune -o \
      ! -type d -name "$pattern" "${keep[@]}" -print0 2>/dev/null)
  done
  if [ "${#leaked[@]}" -gt 0 ]; then
    result FAIL F2 "masked files read as empty" "readable: ${leaked[*]}"
  else
    result PASS F2 "masked files read as empty" "$masked files"
  fi
fi
if [ "${#HIDDEN[@]}" -eq 0 ] || [ "${HIDDEN[0]}" = none ]; then
  result SKIP F8 "hidden paths read as empty" "no hidden.txt in this profile"
else
  shown=()
  for path in "${HIDDEN[@]}"; do
    if [ -d "/workspace/$path" ] && [ -n "$(ls -A "/workspace/$path" 2>/dev/null)" ]; then
      shown+=("$path")
    elif [ -f "/workspace/$path" ] && [ -s "/workspace/$path" ]; then
      shown+=("$path")
    fi
  done
  if [ "${#shown[@]}" -gt 0 ]; then
    result FAIL F8 "hidden paths read as empty" "visible: ${shown[*]}"
  else
    result PASS F8 "hidden paths read as empty" "${#HIDDEN[@]} paths"
  fi
fi
if [ "${#TMPFS[@]}" -eq 0 ] || [ "${TMPFS[0]}" = none ]; then
  result SKIP F3 "scratch paths are size-capped tmpfs" "no tmpfs.txt in this profile"
else
  for path in "${TMPFS[@]}"; do
    if [ "$(stat -f -c %T "$path" 2>/dev/null)" = tmpfs ]; then
      result PASS F3 "$path is a size-capped tmpfs" "$(df -h --output=size "$path" | tail -n 1 | tr -d ' ')"
    else
      result FAIL F3 "$path is a size-capped tmpfs" "$(stat -f -c %T "$path" 2>&1)"
    fi
  done
fi
# .sandbox-check is this test's own scratch folder (TEST.md creates a .claude/ in it on purpose)
nested="$(find /workspace \( -name node_modules -o -name .git -o -path /workspace/.sandbox-check \) -prune -o \
  \( -name CLAUDE.local.md -o \( \( -type d -o -type l \) -name .claude ! -path /workspace/.claude \) \) -print 2>/dev/null | head -n 5 | tr '\n' ' ')"
if [ -z "$nested" ]; then
  result PASS F4 "no CLAUDE.local.md or nested .claude/ in the project"
else
  result FAIL F4 "no CLAUDE.local.md or nested .claude/ in the project" "$nested"
fi
# templates are writable, except where readonly.txt or !name in masked.txt locks them
if [ "${UNMASKED[0]:-none}" = none ]; then
  result SKIP F9 "secret templates are writable" "no template names"
else
  templates=0
  locked=()
  for pattern in "${UNMASKED[@]}"; do
    while IFS= read -r -d '' path; do
      rel="${path#/workspace/}"
      kept=0
      for ro in "${READONLY[@]}"; do
        if [[ $rel == "$ro" || $rel == "$ro"/* ]]; then kept=1; fi
      done
      [ "$kept" -eq 0 ] || continue
      templates=$((templates + 1))
      [ -w "$path" ] || locked+=("$rel")
    done < <(find /workspace \( -name node_modules -o -name .git -o -path /workspace/.sandbox-check \) -prune -o \
      -type f -name "$pattern" -print0 2>/dev/null)
  done
  if [ "${#locked[@]}" -gt 0 ]; then
    result FAIL F9 "secret templates are writable" "read-only: ${locked[*]}"
  elif [ "$templates" -eq 0 ]; then
    result SKIP F9 "secret templates are writable" "no template file in the project"
  else
    result PASS F9 "secret templates are writable" "$templates files"
  fi
fi
left=()
for name in CLAUDE.md rules skills agents commands output-styles hooks agent-memory settings.local.json; do
  path="$HOME_DIR/.claude/$name"
  if [ -f "$path" ] || { [ -d "$path" ] && [ -n "$(find "$path" -mindepth 1 -print -quit 2>/dev/null)" ]; }; then
    left+=("$name")
  fi
done
if [ "${#left[@]}" -eq 0 ]; then
  result PASS F5 "login volume holds no instruction files"
else
  result FAIL F5 "login volume holds no instruction files" "present: ${left[*]}"
fi
if [ -e "$HOME_DIR/.claude/settings.json" ]; then
  result WARN F6 "no user settings.json" "present: written during this session?"
else
  result PASS F6 "no user settings.json"
fi
memory="$(find "$HOME_DIR/.claude/projects" -path '*/memory/*' -type f 2>/dev/null | head -n 3 | tr '\n' ' ')"
if [ -z "$memory" ]; then
  result PASS F7 "no auto-memory files"
else
  result WARN F7 "no auto-memory files" "not loaded while auto memory is off, but present: $memory"
fi

echo "== Claude Code policy"
SETTINGS="$CC/managed-settings.json"
# shellcheck disable=SC2016 # a jq program, not shell
works S1 "merged policy keeps every base rule and value" jq -e --slurpfile base /etc/agent/base/managed-settings.json '
  . as $merged | $base[0] as $b
  | ([$b | paths(type != "object" and type != "array") | select(all(.[]; type == "string"))]
      | all(.[]; . as $p | ($merged | getpath($p)) == ($b | getpath($p))))
  and ([$b | paths(type == "array")]
      | all(.[]; . as $p | (($b | getpath($p)) - (($merged | getpath($p)) // [])) == []))' "$SETTINGS"
works S2 "bypass mode off; only managed permissions, hooks and MCP; no auto memory, artifacts, claude.ai connectors" jq -e '
  .allowManagedPermissionRulesOnly == true and .allowManagedHooksOnly == true
  and .allowManagedMcpServersOnly == true and .permissions.disableBypassPermissionsMode == "disable"
  and .enableAllProjectMcpServers == false and .disableClaudeAiConnectors == true
  and .autoMemoryEnabled == false and .enableArtifact == false and .forceLoginMethod == "claudeai"' "$SETTINGS"
if missing="$(jq -r '
  (.permissions.deny // []) as $deny
  | [("//home/claude/**", "**/CLAUDE.md", "**/CLAUDE.local.md", "**/AGENTS.md", "**/.claude/**",
      "**/.env", "**/*.pem", "**/*.key") | "Edit(\(.))"]
  + ["Read(//home/claude/**)"]
  + [("push", "commit", "merge", "rebase", "cherry-pick", "revert", "am", "stash", "checkout", "switch",
      "restore", "clean", "reset", "rm", "mv", "apply", "-c", "-C", "--git-dir", "--work-tree",
      "--exec-path", "clone", "fetch", "pull", "submodule") | "Bash(git \(.):*)"]
  | . - $deny | join(" ")' "$SETTINGS" 2>/dev/null)"; then
  if [ -z "$missing" ]; then
    result PASS S3 "deny rules cover instruction files, secrets, the login volume and git writes"
  else
    result FAIL S3 "deny rules cover instruction files, secrets, the login volume and git writes" "missing: $missing"
  fi
else
  result FAIL S3 "deny rules cover instruction files, secrets, the login volume and git writes" "cannot read $SETTINGS"
fi
works S4 "managed-mcp.json defines no MCP server" jq -e '(.mcpServers // {}) == {}' "$CC/managed-mcp.json"
if ! extra="$(jq -r '[(.allowedMcpServers // [])[], (.enabledMcpjsonServers // [])[], (.strictKnownMarketplaces // [])[]] | map(tostring) | join(" ")' "$SETTINGS" 2>/dev/null)"; then
  result FAIL S5 "no MCP server or plugin marketplace allowed" "cannot read $SETTINGS"
elif [ -z "$extra" ]; then
  result PASS S5 "no MCP server or plugin marketplace allowed"
else
  result WARN S5 "no MCP server or plugin marketplace allowed" "profile allows: $extra"
fi
if [ -z "${CLAUDECODE:-}" ]; then
  result SKIP S6 "Claude Code sends all traffic to the proxy" "not run from the agent"
elif [ "${HTTPS_PROXY:-}" = "$PROXY" ] && [ "${NO_PROXY:-}" = "localhost,127.0.0.1,::1" ]; then
  result PASS S6 "Claude Code sends all traffic to the proxy"
else
  result FAIL S6 "Claude Code sends all traffic to the proxy" "HTTPS_PROXY=${HTTPS_PROXY:-unset} NO_PROXY=${NO_PROXY:-unset}"
fi

echo "== limits"
limit L1 "memory is capped" /sys/fs/cgroup/memory.max
limit L2 "process count is capped" /sys/fs/cgroup/pids.max
limit L3 "CPU is capped" /sys/fs/cgroup/cpu.max

echo "RESULT: $PASS pass, $FAIL fail, $WARN warn, $SKIP skip"
[ "$FAIL" -eq 0 ]
