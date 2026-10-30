#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BASE_IMAGE=agent-base
NETWORK=claude-net
EMPTY_DIR=
ROOT_KEYS=" AGENT_PROXY_MODE EXTRA_DOC_DOMAINS AGENT_CPUS AGENT_MEMORY AGENT_PIDS AGENT_SHM "
PROJECT_KEYS=" PROJECT_PATH$ROOT_KEYS"
RELATIVE_PATH_PATTERN='^[A-Za-z0-9._@+-][A-Za-z0-9._@+/-]*$'
DOT_SEGMENT='(^|/)\.\.?(/|$)'
DEFAULT_CPUS=4
DEFAULT_MEMORY=8g
DEFAULT_PIDS=2048
DEFAULT_SHM=1g

profile_names() {
  local dir
  local -a names=()
  for dir in "$ROOT"/profiles/*/; do
    if [ -f "${dir}Dockerfile" ]; then names+=("$(basename "$dir")"); fi
  done
  echo "${names[*]:-none yet: cp -r profiles/example profiles/my-app}"
}

usage() {
  cat <<USAGE
Usage: ./run.sh <profile> [start|build|proxy-log] [--name NAME]

Runs Claude Code for one project in a locked Docker sandbox: all traffic through a filtering
proxy, read-only policy and instructions, your code mounted as /workspace.
Without arguments it only prints this help. Daily use: ./run.sh <profile>

Commands:
  start               start an agent (default); builds the images first when missing or changed
  build               rebuild base and profile images from scratch: newest Debian packages and Claude Code
  proxy-log           only in a second terminal while the agent runs: its last 200 proxy decisions,
                      "block" = refused; the log is gone once the agent stops

Options:
  --name NAME         agent name, default <profile>; each name keeps its own login volume
  -h, --help          show this help

Settings (shell variable > profiles/<profile>/.env > .env > default):
  PROJECT_PATH        code to mount as /workspace, profile .env only
  AGENT_PROXY_MODE    enforce (default) or learn: learn reports content violations instead of blocking
  EXTRA_DOC_DOMAINS   more doc hosts, space separated
  AGENT_CPUS, AGENT_MEMORY, AGENT_PIDS, AGENT_SHM
                      container limits, default ${DEFAULT_CPUS}, ${DEFAULT_MEMORY}, ${DEFAULT_PIDS}, ${DEFAULT_SHM}

Profiles: $(profile_names)

Examples:
  ./run.sh my-app                           daily use
  ./run.sh my-app --name second             a second agent with its own login
  ./run.sh my-app proxy-log                 second terminal: what the proxy refused
  AGENT_PROXY_MODE=learn ./run.sh my-app    record Claude Code's calls without blocking content
  docker exec -u claude my-app bash /etc/agent/test/sandbox-check.sh
                                            check every protection (full self-test: test/TEST.md)

Exit codes: 2 = wrong command line, 1 = refused to start, anything else comes from Docker or the agent
USAGE
}

fail() {
  echo "run.sh: $*" >&2
  exit 1
}

usage_error() {
  usage >&2
  echo >&2
  echo "run.sh: $*" >&2
  exit 2
}

entries() {
  [ -f "$1" ] || return 0
  sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

is_safe_relative_path() {
  [[ $1 =~ $RELATIVE_PATH_PATTERN ]] && [[ ! $1 =~ $DOT_SEGMENT ]]
}

load_env() {
  local file="$1" allowed="$2" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || fail "$file: invalid line: $line"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    [[ $allowed == *" $key "* ]] || fail "$file: key $key is not allowed here"
    if [[ $value =~ ^\"(.*)\"$ ]] || [[ $value =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    [[ -v $key ]] || export "$key=$value"
  done <"$file"
}

stage_images() {
  awk 'toupper($1) == "FROM" {
    i = 2
    if ($i ~ /^--platform=/) i++
    alias = (toupper($(i + 1)) == "AS") ? $(i + 2) : ""
    print $i "\t" alias
  }' "$PROFILE_DIR/Dockerfile"
}

pull_stage_images() {
  local image alias
  local -A aliases=()
  while IFS=$'\t' read -r image alias; do
    if [ -n "$alias" ]; then aliases[$alias]=1; fi
  done < <(stage_images)
  while IFS=$'\t' read -r image alias; do
    [[ $image == *'$'* || $image == scratch || -n ${aliases[$image]:-} ]] && continue
    docker pull -q "$image" >/dev/null || fail "cannot pull $image"
  done < <(stage_images)
}

build_images() {
  local out=/dev/stdout
  local -a opts=()
  if [ "${1:-}" = fresh ]; then
    docker build --pull --no-cache -t "$BASE_IMAGE" "$ROOT/base"
    pull_stage_images
    docker build --no-cache --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE" "$PROFILE_DIR"
    return
  fi
  if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    opts=(-q)
    out=/dev/null
  fi
  docker build "${opts[@]}" -t "$BASE_IMAGE" "$ROOT/base" >"$out"
  docker build "${opts[@]}" --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE" "$PROFILE_DIR" >"$out"
}

proxy_log() {
  docker container inspect "$NAME" >/dev/null 2>&1 || fail "agent $NAME is not running: start it, then run proxy-log in a second terminal"
  docker exec -u agentproxy "$NAME" tail -n 200 /var/log/agent-proxy/decisions.log
}

start_agent() {
  local project_dir="${PROJECT_PATH:-}"
  local line readonly_path pattern masked_file secret_file target tmpfs_path tmpfs_size tmpfs_target extra_columns
  local -A mounted=()
  local -a tmpfs_prune=()
  local -a instruction_files=()
  local -a readonly_paths=(.git .claude CLAUDE.md)
  local -a mounted_readonly_paths=()
  local -a masked_file_patterns=()
  local -a find_name_filters=()
  local -a tmpfs_flags=()
  local -a tmpfs_paths=()
  local -a mount_flags=()

  [ -n "$project_dir" ] || fail "PROJECT_PATH is not set: add it to profiles/$PROJECT/.env (see profiles/example/.env.example)"
  [ -d "$project_dir" ] || fail "PROJECT_PATH does not exist: $project_dir"
  project_dir="$(cd "$project_dir" && pwd -P)"
  [[ $project_dir != *[:,]* ]] || fail "PROJECT_PATH must not contain ':' or ','"
  case "$HOME/" in "$project_dir/"*) fail "PROJECT_PATH must be a project folder, not $project_dir" ;; esac
  case "$ROOT/" in "$project_dir/"*) fail "PROJECT_PATH must not contain this sandbox repo" ;; esac
  case "$project_dir/" in "$ROOT/"*) fail "PROJECT_PATH must not be inside this sandbox repo" ;; esac

  mapfile -t instruction_files < <(find "$project_dir" \( -name node_modules -o -name .git \) -prune -o \
    \( -name CLAUDE.local.md -o \( -type d -name .claude ! -path "$project_dir/.claude" \) \) -print)
  if [ "${#instruction_files[@]}" -gt 0 ]; then
    echo "run.sh: agent instruction files outside git review:" >&2
    printf '  %s\n' "${instruction_files[@]}" >&2
    fail "review and remove them, then start again"
  fi
  if [ -e "$project_dir/CLAUDE.md" ] && ! git -C "$project_dir" ls-files --error-unmatch CLAUDE.md >/dev/null 2>&1; then
    fail "CLAUDE.md is not tracked by git: review it, then commit or delete it"
  fi

  while IFS= read -r line; do
    is_safe_relative_path "$line" || fail "readonly.txt: invalid path $line"
    readonly_paths+=("${line%/}")
  done < <(entries "$PROFILE_DIR/readonly.txt")

  while IFS= read -r line; do
    [[ $line =~ ^[A-Za-z0-9._*?-]+$ ]] || fail "masked.txt: invalid file name pattern $line"
    masked_file_patterns+=("$line")
  done < <(entries "$PROFILE_DIR/masked.txt")

  # Size-capped RAM-backed scratch: a workspace-relative path keeps the host copy
  # private, /tmp bounds everything the agent and its tools write outside the project.
  while read -r tmpfs_path tmpfs_size extra_columns; do
    [ -z "$extra_columns" ] || fail "tmpfs.txt: expected 'path size' per line"
    [[ ${tmpfs_size:-} =~ ^[0-9]+[kmg]$ ]] || fail "tmpfs.txt: invalid size for $tmpfs_path"
    if [[ $tmpfs_path == /* ]]; then
      [[ $tmpfs_path == /tmp || $tmpfs_path == /tmp/* ]] || fail "tmpfs.txt: absolute paths must be /tmp or below: $tmpfs_path"
      [[ ! $tmpfs_path =~ $DOT_SEGMENT ]] || fail "tmpfs.txt: invalid path $tmpfs_path"
      tmpfs_target="${tmpfs_path%/}"
    else
      is_safe_relative_path "$tmpfs_path" || fail "tmpfs.txt: invalid path $tmpfs_path"
      tmpfs_target="/workspace/${tmpfs_path%/}"
    fi
    tmpfs_flags+=(--tmpfs "$tmpfs_target:rw,mode=1777,nosuid,nodev,size=$tmpfs_size")
    tmpfs_paths+=("$tmpfs_target")
  done < <(entries "$PROFILE_DIR/tmpfs.txt")

  EMPTY_DIR="$(mktemp -d)"
  chmod 555 "$EMPTY_DIR"
  trap 'rmdir "$EMPTY_DIR" 2>/dev/null || true' EXIT

  mount_flags=(
    -v "$project_dir:/workspace"
    -v "$PROFILE_DIR:/etc/agent/profile:ro"
    -v "$ROOT/test:/etc/agent/test:ro"
    -v "claude-home-$NAME:/home/claude"
  )

  for readonly_path in "${readonly_paths[@]}"; do
    if [ -L "$project_dir/$readonly_path" ]; then
      fail "readonly path is a symlink: $readonly_path"
    elif [ -e "$project_dir/$readonly_path" ]; then
      mount_flags+=(-v "$project_dir/$readonly_path:/workspace/$readonly_path:ro")
      mounted["/workspace/$readonly_path"]=1
      mounted_readonly_paths+=("$readonly_path")
    elif [ "$readonly_path" = .claude ]; then
      mount_flags+=(-v "$EMPTY_DIR:/workspace/.claude:ro")
      mounted["/workspace/.claude"]=1
      mounted_readonly_paths+=("$readonly_path")
    fi
  done

  if [ "${#masked_file_patterns[@]}" -gt 0 ]; then
    for pattern in "${masked_file_patterns[@]}"; do find_name_filters+=(-o -name "$pattern"); done
    find_name_filters=("${find_name_filters[@]:1}")
    while IFS= read -r -d '' masked_file; do
      [[ $masked_file != *[:,]* ]] || fail "cannot mask a path with ':' or ',': $masked_file"
      mount_flags+=(-v "/dev/null:/workspace${masked_file#"$project_dir"}:ro")
      mounted["/workspace${masked_file#"$project_dir"}"]=1
    done < <(find "$project_dir" \( -name node_modules -o -name .git \) -prune -o -type f \( "${find_name_filters[@]}" \) -print0)
  fi

  # Secrets stay readable, but no tool or script can overwrite them: deny rules only
  # bind Claude's own file tools. Skips what is mounted already or hidden by a tmpfs.
  for tmpfs_target in "${tmpfs_paths[@]}"; do
    if [[ $tmpfs_target == /workspace/* ]]; then tmpfs_prune+=(-o -path "$project_dir${tmpfs_target#/workspace}"); fi
  done
  while IFS= read -r -d '' secret_file; do
    target="/workspace${secret_file#"$project_dir"}"
    [ -z "${mounted[$target]:-}" ] || continue
    [[ $secret_file != *[:,]* ]] || fail "cannot protect a path with ':' or ',': $secret_file"
    mount_flags+=(-v "$secret_file:$target:ro")
    mounted_readonly_paths+=("${target#/workspace/}")
  done < <(find "$project_dir" \( -name node_modules -o -name .git "${tmpfs_prune[@]}" \) -prune -o -type f \
    \( -name .env -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \) -print0)

  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null

  docker run --rm -it --init \
    --name "$NAME" --network "$NETWORK" \
    --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN \
    --security-opt no-new-privileges \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
    --pids-limit "${AGENT_PIDS:-$DEFAULT_PIDS}" --memory "${AGENT_MEMORY:-$DEFAULT_MEMORY}" --memory-swap "${AGENT_MEMORY:-$DEFAULT_MEMORY}" \
    --cpus "${AGENT_CPUS:-$DEFAULT_CPUS}" --shm-size "${AGENT_SHM:-$DEFAULT_SHM}" \
    "${tmpfs_flags[@]}" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e AGENT_PROJECT="$PROJECT" -e AGENT_PROXY_MODE="$MODE" -e EXTRA_DOC_DOMAINS="${EXTRA_DOC_DOMAINS:-}" \
    -e AGENT_FACTS_READONLY="${mounted_readonly_paths[*]}" \
    -e AGENT_FACTS_MASKED="${masked_file_patterns[*]:-none}" \
    -e AGENT_FACTS_TMPFS="${tmpfs_paths[*]:-none}" \
    "${mount_flags[@]}" \
    "$IMAGE"
}

CMD=start
NAME=
PROJECT=
if [ $# -eq 0 ]; then
  usage
  exit 2
fi
while [ $# -gt 0 ]; do
  case "$1" in
    start | build | proxy-log)
      CMD="$1"
      shift
      ;;
    --name)
      [ $# -ge 2 ] || usage_error "--name needs a value"
      NAME="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      [ -z "$PROJECT" ] || usage_error "unexpected argument: $1 (one profile per run; commands: start, build, proxy-log)"
      PROJECT="$1"
      shift
      ;;
  esac
done

[ -n "$PROJECT" ] || usage_error "missing profile name"
[[ $PROJECT =~ ^[a-z0-9][a-z0-9_-]*$ ]] || usage_error "profile name must match [a-z0-9][a-z0-9_-]*"
PROFILE_DIR="$ROOT/profiles/$PROJECT"
[ -f "$PROFILE_DIR/Dockerfile" ] || usage_error "unknown profile: $PROJECT"
NAME="${NAME:-$PROJECT}"
[[ $NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || usage_error "invalid --name: $NAME"
[ "$(id -u)" -ne 0 ] || fail "do not run as root, use your normal user"
command -v docker >/dev/null 2>&1 || fail "docker is not installed"
load_env "$PROFILE_DIR/.env" "$PROJECT_KEYS"
load_env "$ROOT/.env" "$ROOT_KEYS"

IMAGE="agent-$PROJECT"
MODE="${AGENT_PROXY_MODE:-enforce}"
case "$MODE" in enforce | learn) ;; *) fail "AGENT_PROXY_MODE must be enforce or learn" ;; esac

case "$CMD" in
  build) build_images fresh ;;
  proxy-log) proxy_log ;;
  start)
    build_images
    start_agent
    ;;
esac
