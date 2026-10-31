#!/usr/bin/env bash
#
# The container's first process: Docker starts it as root, it locks the box down,
# then hands over to `claude` running as you. Refuses to start on anything
# unexpected - a half-applied sandbox is worse than none.
#
#   1. check what run.sh handed us; create `claude` with your host uid
#   2. wipe the login volume down to the login, transcripts and prompt history
#   3. build from base + profile: doc hosts, tunnel hosts, Claude Code policy,
#      system CLAUDE.md, a wrapper per profile command (e.g. `twin`)
#   4. iptables: only the proxy user may send packets, port 443 only, DNS too
#   5. start the proxy, install its CA, then prove the policy blocks its
#      probes - if any passes, exit rather than run with an open network
#   6. watch the proxy (dead proxy = no egress), drop root, exec `claude`
#
set -euo pipefail
umask 022

BASE=/etc/agent/base
PROFILE=/etc/agent/profile
STAGE=/run/agent-profile
CC=/etc/claude-code
POLICY=/etc/agent-proxy
PROXY_RUN=/run/agent-proxy
PROXY_LOGS=/var/log/agent-proxy
PROXY_PORT=8118
PROXY_URL="http://127.0.0.1:$PROXY_PORT"
HOME_DIR=/home/claude
PUID="${HOST_UID:-}"
PGID="${HOST_GID:-}"
MODE="${AGENT_PROXY_MODE:-enforce}"
PROJECT="${AGENT_PROJECT:-}"
DOMAIN_RE='^(\*\.)?[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
PROXY_PID=

fail() {
  echo "agent: $*" >&2
  exit 1
}

entries() {
  [ -f "$1" ] || return 0
  sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

start_proxy() {
  local -a args=(
    -q --listen-host 127.0.0.1 --listen-port "$PROXY_PORT"
    --set confdir="$PROXY_RUN" --set connection_strategy=lazy --set termlog_verbosity=warn
  )
  # tunnel hosts are the only ones left opaque (the policy checks their TLS SNI); everything else is inspected
  args+=(-s "$BASE/proxy-policy.py")
  # -C /: the proxy must not run from /workspace, a folder the agent writes
  setsid gosu agentproxy env -i -C / \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/nonexistent PYTHONDONTWRITEBYTECODE=1 \
    AGENT_PROXY_MODE="$MODE" \
    AGENT_PROXY_ALLOWED="$POLICY/allowed-hosts.txt" \
    AGENT_PROXY_TUNNEL="$POLICY/tunnel-hosts.txt" \
    AGENT_PROXY_LOG="$PROXY_LOGS/decisions.log" \
    mitmdump "${args[@]}" \
    >>"$PROXY_LOGS/mitmdump.log" 2>&1 </dev/null &
  PROXY_PID=$!
}

# The first proxy's parent becomes `claude` (exec), which never reaps it: a dead
# proxy stays a zombie with a /proc entry, so check its state and owner instead.
proxy_alive() {
  local state
  [ -n "$PROXY_PID" ] || return 1
  state="$(awk '$1 == "State:" {print $2}' "/proc/$PROXY_PID/status" 2>/dev/null)" || return 1
  [[ -n $state && $state != [ZX] ]] && [ "$(stat -c %u "/proc/$PROXY_PID" 2>/dev/null)" = "$PROXY_UID" ]
}

wait_proxy() {
  local _
  for _ in $(seq 1 150); do
    proxy_alive || return 1
    if (exec 3<>"/dev/tcp/127.0.0.1/$PROXY_PORT") 2>/dev/null && gosu agentproxy test -s "$PROXY_RUN/mitmproxy-ca-cert.pem"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

install_ca() {
  gosu agentproxy cat "$PROXY_RUN/mitmproxy-ca-cert.pem" >"$CC/proxy-ca.pem"
  chmod 0644 "$CC/proxy-ca.pem"
  install -m 0644 "$CC/proxy-ca.pem" /usr/local/share/ca-certificates/agent-proxy.crt
  update-ca-certificates >/dev/null 2>&1 || fail "could not install the proxy CA"
}

connect_code() {
  curl -s -o /dev/null -w '%{http_connect}' --max-time 10 -x "$PROXY_URL" "$1" 2>/dev/null || true
}

# The proxy's own refusal names its reason; a 403 from upstream would not.
proxy_refuses() {
  local reason="$1"
  shift
  [[ "$(curl -s --max-time 10 -x "$PROXY_URL" "$@" 2>/dev/null || true)" == *"blocked by agent proxy: $reason"* ]]
}

# Guards answered by the proxy itself (connection_strategy=lazy means no packet
# reaches the internet): unknown host, a tunnel host's TLS SNI on another host,
# foreign API key, forbidden Anthropic route, url source in a message, unknown
# server tool, write to a doc host. Any of them passing means the policy is not in
# force. learn mode reports content violations instead of blocking them, so there
# only the hard gates are probed.
self_test() {
  [ "$(connect_code https://agent-selftest.invalid/)" = 403 ] || return 1
  if [ "${#tunnels[@]}" -gt 0 ]; then
    proxy_refuses "tls sni mismatch" --connect-to "${tunnels[0]}:443:api.anthropic.com:443" "https://${tunnels[0]}/" || return 1
  fi
  proxy_refuses "header x-api-key" -H 'x-api-key: agent-selftest' https://api.anthropic.com/v1/models || return 1
  [ "$MODE" = enforce ] || return 0
  proxy_refuses "route not allowed" -X POST https://api.anthropic.com/v1/files &&
    proxy_refuses "url source" --data '{"messages":[{"role":"user","content":[{"type":"image","source":{"type":"url","url":"https://agent-selftest.invalid/"}}]}]}' https://api.anthropic.com/v1/messages &&
    proxy_refuses "tool agent_selftest" --data '{"tools":[{"type":"agent_selftest","name":"agent_selftest"}]}' https://api.anthropic.com/v1/messages &&
    proxy_refuses "method POST" -X POST https://docs.claude.com/
}

stop_proxy() {
  proxy_alive && gosu agentproxy kill "$PROXY_PID" 2>/dev/null || true
}

[ "$(id -u)" -eq 0 ] || fail "entrypoint must start as root"
[[ $PUID =~ ^[0-9]+$ ]] && [[ $PGID =~ ^[0-9]+$ ]] || fail "HOST_UID and HOST_GID must be numeric"
[ "$PUID" -ne 0 ] && [ "$PGID" -ne 0 ] || fail "HOST_UID and HOST_GID must not be 0"
case "$MODE" in enforce | learn) ;; *) fail "AGENT_PROXY_MODE must be enforce or learn" ;; esac
[[ $PROJECT =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "AGENT_PROJECT is missing or invalid"
[ -d "$PROFILE" ] || fail "project profile is not mounted at $PROFILE"
[ -d /workspace ] || fail "/workspace is not mounted"
[ -d "$HOME_DIR" ] || fail "$HOME_DIR is not mounted"
PROXY_UID="$(id -u agentproxy)"
PROXY_GID="$(id -g agentproxy)"
[ "$PUID" != "$PROXY_UID" ] || fail "HOST_UID $PUID collides with the proxy user"
[ "$PGID" != "$PROXY_GID" ] || fail "HOST_GID $PGID collides with the proxy group (it can read the proxy logs and host lists)"

getent group claude >/dev/null || groupadd -o -g "$PGID" claude
id claude >/dev/null 2>&1 || useradd -o -u "$PUID" -g "$PGID" -M -d "$HOME_DIR" -s /bin/bash claude
[ "$(stat -c %u "$HOME_DIR")" = "$PUID" ] || chown -R "$PUID:$PGID" "$HOME_DIR"
# Keep-list, not a block-list: anything else a session wrote here (skills, settings,
# memory, .bashrc, .gitconfig, .yarnrc, caches) could run or instruct the next one.
gosu claude bash -c '
  set -euo pipefail
  cd /home/claude
  chmod 0700 .
  chmod -R u+rwX .
  find . -mindepth 1 -maxdepth 1 \( -type l -o ! \( -name .claude -o -name ".claude.json*" \) \) -exec rm -rf {} +
  [ ! -d .claude ] || find .claude -mindepth 1 -maxdepth 1 \
    \( -type l -o ! \( -name .credentials.json -o -name history.jsonl -o -name projects \) \) -exec rm -rf {} +
  if [ -d .claude/projects ]; then
    find .claude/projects -mindepth 1 -maxdepth 1 ! -type d -exec rm -rf {} +
    find .claude/projects -mindepth 2 -maxdepth 2 ! \( -type f -name "*.jsonl" \) -exec rm -rf {} +
  fi
'

rm -rf "$STAGE"
install -d -m 0755 "$POLICY" "$CC" "$STAGE"
gosu claude tar -C "$PROFILE" -cf - . | tar -C "$STAGE" --no-same-owner -xf - || fail "cannot read the project profile"
read -r -a extra <<<"${EXTRA_DOC_DOMAINS:-}"
mapfile -t domains < <(
  {
    entries "$BASE/allowed-domains.txt"
    entries "$STAGE/allowed-domains.txt"
    printf '%s\n' "${extra[@]}"
  } | tr '[:upper:]' '[:lower:]' | grep -v '^$' | sort -u || true
)
[ "${#domains[@]}" -gt 0 ] || fail "the domain allowlist is empty"
for d in "${domains[@]}"; do
  [[ $d =~ $DOMAIN_RE ]] || fail "invalid domain entry: $d"
done
printf '%s\n' "${domains[@]}" >"$CC/allowed-domains.txt"
chmod 0644 "$CC/allowed-domains.txt"
install -m 0640 -o root -g agentproxy "$CC/allowed-domains.txt" "$POLICY/allowed-hosts.txt"

# tunnel hosts: content is not inspected, so they must be exact and few
mapfile -t tunnels < <(entries "$STAGE/tunnel-domains.txt" | tr '[:upper:]' '[:lower:]' | grep -v '^$' | sort -u || true)
for t in "${tunnels[@]}"; do
  [[ $t =~ $DOMAIN_RE ]] || fail "invalid tunnel entry: $t"
  [[ $t != \*.* ]] || fail "tunnel-domains.txt takes exact hosts, not wildcards: $t"
  if printf '%s\n' "${domains[@]}" | grep -qxF "$t"; then
    fail "$t is in both allowed-domains.txt and tunnel-domains.txt: pick one class"
  fi
done
: >"$CC/tunnel-domains.txt"
if [ "${#tunnels[@]}" -gt 0 ]; then
  printf '%s\n' "${tunnels[@]}" >"$CC/tunnel-domains.txt"
fi
chmod 0644 "$CC/tunnel-domains.txt"
install -m 0640 -o root -g agentproxy "$CC/tunnel-domains.txt" "$POLICY/tunnel-hosts.txt"

profile_settings="$STAGE/managed-settings.json"
if [ -f "$profile_settings" ]; then
  jq -e 'type == "object"' "$profile_settings" >/dev/null 2>&1 || fail "$PROFILE/managed-settings.json must be a JSON object"
else
  profile_settings=/dev/null
fi
jq -n --slurpfile base "$BASE/managed-settings.json" --slurpfile profile "$profile_settings" '
  def merge($a; $b):
    if ($a | type) == "object" and ($b | type) == "object" then
      reduce ((($a | keys_unsorted) + ($b | keys_unsorted)) | unique)[] as $k ({};
        .[$k] = if ($a | has($k)) and ($b | has($k)) then merge($a[$k]; $b[$k])
                elif ($a | has($k)) then $a[$k]
                else $b[$k] end)
    elif ($a | type) == "array" and ($b | type) == "array" then ($a + $b) | unique
    elif $a == null then $b
    else $a end;
  merge($base[0]; ($profile[0] // {}))
' >"$CC/managed-settings.json"
jq -e '.allowManagedPermissionRulesOnly == true and (.permissions.deny | length) > 0' "$CC/managed-settings.json" >/dev/null ||
  fail "merged managed settings failed validation"
chmod 0644 "$CC/managed-settings.json"

commands=()
if [ -d "$STAGE/bin" ]; then
  for f in "$STAGE"/bin/*; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    [[ $n =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "invalid profile command name: $n"
    if command -v "$n" >/dev/null 2>&1; then fail "profile command $n would shadow $(command -v "$n")"; fi
    printf '#!/bin/sh\nexec /bin/bash %s/bin/%s "$@"\n' "$PROFILE" "$n" >"/usr/local/bin/$n"
    chmod 0755 "/usr/local/bin/$n"
    commands+=("$n")
  done
fi

{
  cat "$BASE/CLAUDE.md"
  printf '\n## Sandbox facts (generated at start)\n'
  printf -- '- Project profile: %s (read-only at %s)\n' "$PROJECT" "$PROFILE"
  printf -- '- Read-only in /workspace: %s\n' "${AGENT_FACTS_READONLY:-.git .claude CLAUDE.md}"
  printf -- '- Hidden, always empty: %s\n' "${AGENT_FACTS_HIDDEN:-none}"
  printf -- '- Masked, always empty: %s\n' "${AGENT_FACTS_MASKED:-none}"
  printf -- '- Not masked: %s\n' "${AGENT_FACTS_UNMASKED:-none}"
  printf -- '- Size-capped tmpfs (RAM-backed, wiped on exit): %s\n' "${AGENT_FACTS_TMPFS:-none}"
  printf -- '- Profile commands: %s\n' "${commands[*]:-none}"
  printf -- '- Doc hosts (GET/HEAD only, no body, short URLs): %s/allowed-domains.txt\n' "$CC"
  printf -- '- Opaque tunnel hosts (app runtime only, never a doc source): %s\n' "${tunnels[*]:-none}"
  printf -- '- Proxy mode: %s\n' "$MODE"
  if [ -f "$STAGE/CLAUDE.md" ]; then
    printf '\n'
    cat "$STAGE/CLAUDE.md"
  fi
} >"$CC/CLAUDE.md"
chmod 0644 "$CC/CLAUDE.md"

install -d -m 0700 -o agentproxy -g agentproxy "$PROXY_RUN"
install -d -m 0750 -o root -g agentproxy "$PROXY_LOGS"
# chown last: install chowns before it chmods, and without CAP_FOWNER root cannot chmod a file it gave away
install -m 0640 /dev/null "$PROXY_LOGS/decisions.log"
chown agentproxy:agentproxy "$PROXY_LOGS/decisions.log"
install -m 0640 -o root -g agentproxy /dev/null "$PROXY_LOGS/mitmdump.log"

iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -A OUTPUT -d 127.0.0.11 -m owner --uid-owner "$PROXY_UID" -j ACCEPT ||
  fail "iptables owner match unavailable (the host needs the xt_owner module)"
iptables -A OUTPUT -d 127.0.0.11 -j DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$PROXY_UID" -j ACCEPT
iptables -F INPUT
iptables -P INPUT DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true

start_proxy
wait_proxy || fail "proxy failed to start, see $PROXY_LOGS/mitmdump.log"
install_ca
self_test || {
  stop_proxy
  fail "proxy policy is not active, refusing to start"
}

(
  trap '' INT QUIT TSTP HUP
  while sleep 5; do
    proxy_alive && continue
    start_proxy
    if ! wait_proxy || ! self_test; then
      stop_proxy
      echo "agent: proxy restart failed, network stays closed" >>"$PROXY_LOGS/mitmdump.log"
      exit 1
    fi
  done
) &

cd /workspace
exec gosu claude env \
  HOME="$HOME_DIR" USER=claude LOGNAME=claude SHELL=/bin/bash \
  AGENT_PROFILE_DIR="$PROFILE" \
  HTTPS_PROXY="$PROXY_URL" https_proxy="$PROXY_URL" HTTP_PROXY="$PROXY_URL" http_proxy="$PROXY_URL" \
  NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1" \
  NODE_EXTRA_CA_CERTS="$CC/proxy-ca.pem" \
  DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 CLAUDE_CODE_DISABLE_ARTIFACT=1 \
  ENABLE_CLAUDEAI_MCP_SERVERS=false CLAUDE_CODE_GZIP_REQUEST_BODIES=0 CLAUDE_CODE_NO_FLICKER=1 \
  claude "$@"
