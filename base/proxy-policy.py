"""Egress policy for the agent sandbox.

Every byte the container sends leaves through this proxy: iptables lets only the
proxy user out, so a host that is refused here is unreachable. TLS is intercepted
for everything except the hosts in the profile's tunnel-domains.txt, and each host falls
into exactly one class:

  api     Anthropic hosts. Only the routes Claude Code itself uses pass, and
          /v1/messages bodies are checked, so the client cannot ask Anthropic's
          side to fetch a URL, run code or dial an MCP server on its behalf:
          server tools are an allowlist, so a new server tool stays blocked
          until it is reviewed here.
  docs    every host in the allowlist. The request is shaped down to reading:
          GET/HEAD, no body, small URL and header budget, credentials stripped,
          no connection upgrade. A doc host cannot be used to post the repo out.
  tunnel  hosts listed in the profile's tunnel-domains.txt. The CONNECT host is checked
          and the TLS SNI must name that same host; the bytes inside are not. For
          the app's own runtime calls (e.g. a captcha API) - never for documentation.

Anything else is refused. One JSON object per decision goes to the decision log.
"""

import json
import os
import re
import sys
import time

from mitmproxy import http

ALLOWED_PORT = 443

DOCS_METHODS = frozenset(("GET", "HEAD"))
DOCS_MAX_PATH = 256
DOCS_MAX_QUERY = 96
DOCS_MAX_HEADER_BYTES = 2048
DOCS_STRIP_HEADERS = ("authorization", "cookie", "x-api-key")

API_BLOCK_HEADERS = ("x-api-key",)
API_BODY_PATHS = frozenset(("/v1/messages", "/v1/messages/count_tokens"))
API_BLOCKED_BODY_KEYS = ("mcp_servers", "container")
# Client tools have no type (or "custom"); server tools run on Anthropic's side.
# Only these server tools pass: search, and search over the request's own tools.
API_ALLOWED_TOOL_PREFIXES = ("web_search_", "tool_search_tool_")
API_SAFE_SEGMENT = re.compile(r"^[A-Za-z0-9._~-]+$")
UNSAFE_CHARS = re.compile(r"[\x00-\x20\x7f]")


def route(methods, kind, value):
    return frozenset(methods.split()), kind, value


# Claude Code's own calls, nothing else. Every route is a way out: keep minimal.
API_ROUTES = {
    "api.anthropic.com": (
        route("POST", "exact", "/v1/messages"),
        route("POST", "exact", "/v1/messages/count_tokens"),
        route("GET", "exact", "/v1/models"),
        route("GET", "prefix", "/v1/models/"),
        route("GET POST", "prefix", "/v1/oauth/"),
        route("GET POST", "prefix", "/api/oauth/"),
        route("GET", "exact", "/api/web/domain_info"),
        route("GET", "prefix", "/api/claude_code/"),
        route("GET", "exact", "/api/hello"),
    ),
    "claude.ai": (
        route("GET POST", "prefix", "/oauth/"),
        route("GET POST", "prefix", "/v1/oauth/"),
        route("GET POST", "prefix", "/api/oauth/"),
    ),
    "claude.com": (
        route("GET", "exact", "/docs"),
        route("GET", "prefix", "/docs/"),
        route("GET POST", "prefix", "/oauth/"),
    ),
    "platform.claude.com": (
        route("GET POST", "prefix", "/v1/oauth/"),
        route("GET POST", "prefix", "/oauth/"),
        route("GET POST", "prefix", "/api/oauth/"),
        route("GET", "exact", "/docs"),
        route("GET", "prefix", "/docs/"),
        route("GET", "exact", "/llms.txt"),
    ),
    "console.anthropic.com": (
        route("GET POST", "prefix", "/v1/oauth/"),
        route("GET POST", "prefix", "/oauth/"),
    ),
}


def normalize_host(value):
    return str(value or "").strip().lower().rstrip(".")


def load_hosts(path, optional=False):
    """Read a host list: exact names plus '*.example.com' suffix entries."""
    if optional and not (path and os.path.exists(path)):
        return frozenset(), ()
    exact = set()
    suffixes = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            entry = normalize_host(line)
            if not entry:
                continue
            if entry.startswith("*."):
                suffixes.append(entry[1:])
            else:
                exact.add(entry)
    return frozenset(exact), tuple(suffixes)


def in_hosts(host, hosts):
    exact, suffixes = hosts
    return host in exact or (bool(suffixes) and host.endswith(suffixes))


def header_bytes(headers):
    return sum(len(name) + len(value) + 4 for name, value in headers.items(multi=True))


def body_bytes(request):
    try:
        return len(request.raw_content or b"")
    except Exception:
        return 0


def api_path_ok(path):
    if not path.startswith("/"):
        return False
    segments = path[1:].split("/")
    for index, segment in enumerate(segments):
        if segment == "":
            if index == len(segments) - 1:
                continue
            return False
        if segment in (".", "..") or not API_SAFE_SEGMENT.match(segment):
            return False
    return True


def api_route_allowed(routes, method, path):
    for methods, kind, value in routes:
        if method not in methods:
            continue
        if kind == "exact" and path == value:
            return True
        if kind == "prefix" and path.startswith(value):
            return True
    return False


def has_url_source(value):
    """An image or document block with a url source makes Anthropic's side download it."""
    if isinstance(value, list):
        return any(has_url_source(item) for item in value)
    if isinstance(value, dict):
        source = value.get("source")
        if isinstance(source, dict) and source.get("type") == "url":
            return True
        return any(has_url_source(item) for item in value.values())
    return False


class DuplicateKey(ValueError):
    pass


def unique_keys(pairs):
    """Two parsers may keep different copies of a repeated key: refuse instead of guessing."""
    data = {}
    for key, value in pairs:
        if key in data:
            raise DuplicateKey(key)
        data[key] = value
    return data


def api_body_violation(text):
    try:
        data = json.loads(text, object_pairs_hook=unique_keys)
    except DuplicateKey as error:
        return f"duplicate key {error}"
    except ValueError:
        return "body is not json"
    if not isinstance(data, dict):
        return "body is not an object"
    for key in API_BLOCKED_BODY_KEYS:
        if key in data:
            return f"body key {key}"
    tools = data.get("tools") or []
    if not isinstance(tools, list):
        return "tools is not a list"
    for tool in tools:
        if not isinstance(tool, dict):
            return "tool is not an object"
        kind = tool.get("type", "custom")
        if not isinstance(kind, str):
            return "tool type is not a string"
        if kind != "custom" and not kind.startswith(API_ALLOWED_TOOL_PREFIXES):
            return f"tool {kind}"
    if has_url_source(data):
        return "url source"
    return None


def api_violation(request, host, method):
    if "upgrade" in request.headers:
        return "connection upgrade"
    clean = request.path.split("?", 1)[0].split("#", 1)[0]
    if not api_path_ok(clean):
        return "unsafe path"
    if not api_route_allowed(API_ROUTES.get(host, ()), method, clean):
        return "route not allowed"
    if method == "POST" and clean in API_BODY_PATHS:
        try:
            return api_body_violation(request.get_text(strict=True) or "")
        except ValueError:
            return "body decode failed"
    return None


def docs_violation(request, method):
    """Doc hosts are for reading: no writes, and no room to smuggle data out."""
    if method not in DOCS_METHODS:
        return f"method {method} (doc hosts are read-only)"
    if (
        "transfer-encoding" in request.headers
        or request.headers.get("content-length", "0").strip() not in ("", "0")
        or body_bytes(request) > 0
    ):
        return "request body"
    if "upgrade" in request.headers:
        return "connection upgrade"
    clean, _, query = request.path.split("#", 1)[0].partition("?")
    if not clean.startswith("/"):
        return "unsafe path"
    if len(clean) > DOCS_MAX_PATH:
        return f"path over {DOCS_MAX_PATH} bytes"
    if UNSAFE_CHARS.search(clean) or ".." in clean.split("/"):
        return "unsafe path"
    if len(query) > DOCS_MAX_QUERY:
        return f"query over {DOCS_MAX_QUERY} bytes"
    if UNSAFE_CHARS.search(query):
        return "unsafe query"
    size = header_bytes(request.headers)
    if size > DOCS_MAX_HEADER_BYTES:
        return f"headers over {DOCS_MAX_HEADER_BYTES} bytes"
    return None


class AgentPolicy:
    def __init__(self):
        self.mode = os.environ.get("AGENT_PROXY_MODE", "enforce")
        if self.mode not in ("enforce", "learn"):
            raise ValueError("AGENT_PROXY_MODE must be enforce or learn")
        self.allowed = load_hosts(os.environ["AGENT_PROXY_ALLOWED"])
        self.tunnel = load_hosts(os.environ.get("AGENT_PROXY_TUNNEL"), optional=True)
        try:
            self.log = open(os.environ["AGENT_PROXY_LOG"], "a", buffering=1, encoding="utf-8")
        except (KeyError, OSError):
            self.log = sys.stderr

    def host_class(self, host):
        if host in API_ROUTES:
            return "api"
        if in_hosts(host, self.tunnel):
            return "tunnel"
        if in_hosts(host, self.allowed):
            return "docs"
        return None

    def record(self, **event):
        event["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        event["mode"] = self.mode
        try:
            self.log.write(json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n")
        except Exception:
            pass

    @staticmethod
    def deny(flow, reason):
        body = json.dumps(
            {"type": "error", "error": {"type": "permission_error", "message": f"blocked by agent proxy: {reason}"}}
        )
        flow.response = http.Response.make(403, body.encode(), {"Content-Type": "application/json"})

    def refuse(self, flow, event, reason, hard=False):
        """learn mode reports content violations; the host gate always blocks."""
        if self.mode == "learn" and not hard:
            self.record(decision="would_block", reason=reason, **event)
            return
        self.record(decision="block", reason=reason, **event)
        self.deny(flow, reason)

    def http_connect(self, flow):
        try:
            host = normalize_host(flow.request.host)
            port = int(flow.request.port)
            kind = self.host_class(host)
            allowed = port == ALLOWED_PORT and kind is not None
        except Exception:
            host, port, kind, allowed = "?", 0, None, False
        self.record(
            event="connect", decision="allow" if allowed else "block", host=host, port=port, cls=kind or "none"
        )
        if not allowed:
            self.deny(flow, "host not allowed")

    def tls_clienthello(self, data):
        """Only a tunnel host whose TLS SNI names that same host passes through unopened."""
        address = data.context.server.address
        host = normalize_host(address[0] if address else "")
        data.ignore_connection = (
            self.host_class(host) == "tunnel" and normalize_host(data.client_hello.sni) == host
        )

    def request(self, flow):
        try:
            self.check(flow)
        except Exception as error:
            self.record(event="request", decision="block", reason=f"policy error {type(error).__name__}")
            self.deny(flow, "policy error")

    def check(self, flow):
        request = flow.request
        method = request.method.upper()
        if method == "CONNECT":
            return
        address = flow.server_conn.address if flow.server_conn else None
        host = normalize_host(address[0] if address else request.host)
        port = int(address[1] if address else request.port)
        kind = self.host_class(host)
        event = {
            "event": "request",
            "host": host,
            "method": method,
            "path": request.path.split("?", 1)[0],
            "bytes": header_bytes(request.headers) + body_bytes(request),
            "cls": kind or "none",
        }
        if request.scheme != "https" or port != ALLOWED_PORT:
            self.refuse(flow, event, "not https on 443", hard=True)
            return
        if kind is None:
            self.refuse(flow, event, "host not allowed", hard=True)
            return
        sni = flow.client_conn.sni
        if sni and normalize_host(sni) != host:
            self.refuse(flow, event, "tls sni mismatch", hard=True)
            return
        header_host = request.host_header
        if header_host is not None and normalize_host(header_host.split(":", 1)[0]) != host:
            self.refuse(flow, event, "host header mismatch", hard=True)
            return
        if kind == "tunnel":
            self.record(decision="allow", **event)
            return
        if kind == "api":
            # A foreign API key is how a repo lands in someone else's account: blocked even in learn mode.
            blocked_header = next((name for name in API_BLOCK_HEADERS if name in request.headers), None)
            if blocked_header:
                self.refuse(flow, event, f"header {blocked_header}", hard=True)
                return
            reason = api_violation(request, host, method)
        else:
            reason = docs_violation(request, method)
        if reason is not None:
            self.refuse(flow, event, reason)
            return
        if kind == "docs":
            stripped = [name for name in DOCS_STRIP_HEADERS if name in request.headers]
            for name in stripped:
                del request.headers[name]
            if stripped:
                event["stripped"] = stripped
        self.record(decision="allow", **event)

    def responseheaders(self, flow):
        if flow.response is not None:
            flow.response.stream = True


addons = [AgentPolicy()]
