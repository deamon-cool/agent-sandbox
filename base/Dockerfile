FROM debian:bookworm-slim

# Newest agent on every rebuild: what cages it is the sandbox (iptables, the
# read-only mounts, the proxy policy), not the version of the binary. The
# entrypoint still refuses to start if the merged managed settings lost their
# teeth, and the auto-updater stays off so nothing moves mid-session.
# Set CLAUDE_CODE_VERSION in the root .env to freeze it instead.
ARG CLAUDE_CODE_VERSION=latest

ENV PYTHONDONTWRITEBYTECODE=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git gosu iptables jq locales mitmproxy procps ripgrep \
 && localedef -i en_US -c -f UTF-8 en_US.UTF-8 \
 && { update-alternatives --set iptables /usr/sbin/iptables-legacy || true; } \
 && { update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true; } \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 65533 agentproxy \
 && useradd --system --uid 65533 --gid 65533 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin agentproxy \
 && mitmdump --version

RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
 && bash /tmp/claude-install.sh "$CLAUDE_CODE_VERSION" \
 && install -m 0755 "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude \
 && /usr/local/bin/claude --version \
 && rm -rf /tmp/claude-install.sh /root/.local /root/.claude /root/.claude.json /root/.cache

COPY entrypoint.sh /usr/local/sbin/agent-entrypoint
COPY CLAUDE.md allowed-domains.txt managed-settings.json proxy-policy.py /etc/agent/base/
COPY managed-mcp.json /etc/claude-code/managed-mcp.json

RUN chmod 0755 /usr/local/sbin/agent-entrypoint \
 && chmod 0755 /etc/agent /etc/agent/base /etc/claude-code \
 && chmod 0644 /etc/agent/base/* /etc/claude-code/managed-mcp.json \
 && jq empty /etc/agent/base/managed-settings.json /etc/claude-code/managed-mcp.json \
 && git config --system --add safe.directory /workspace \
 && rm -rf /var/tmp && ln -s /tmp /var/tmp && chmod 0755 /run/lock

WORKDIR /workspace
ENTRYPOINT ["/usr/local/sbin/agent-entrypoint"]
