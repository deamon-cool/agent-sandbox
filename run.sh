#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BASE_IMAGE=agent-base
NETWORK=claude-net
EMPTY_DIR=
ROOT_KEYS=" AGENT_PROXY_MODE EXTRA_DOC_DOMAINS AGENT_CPUS AGENT_MEMORY AGENT_PIDS AGENT_SHM "
BASE_KEYS=" CLAUDE_CODE_VERSION "
PROJECT_KEYS=" PROJECT_PATH$ROOT_KEYS"
BUILD_KEY_PATTERN='^BUILD_[A-Z][A-Z0-9_]*$'
BUILD_KEYS=()
declare -A STAGE_ARGS=()
RELATIVE_PATH_PATTERN='^[A-Za-z0-9._@+-][A-Za-z0-9._@+/-]*$'
DOT_SEGMENT='(^|/)\.\.?(/|$)'
DEFAULT_CPUS=4
DEFAULT_MEMORY=8g
DEFAULT_PIDS=2048
DEFAULT_SHM=1g
# Read-only in every project: instructions, git metadata, and files your host runs
# without a second look (git hooks and their managers' configs, editor tasks, dev containers).
DEFAULT_READONLY=(.git .claude CLAUDE.md .husky .githooks .pre-commit-config.yaml lefthook.yml .lefthook.yml lefthook-local.yml .lefthook .vscode .devcontainer)
# Always look empty (masked.txt adds patterns, `!name` keeps a file readable, read-only).
# Templates stay readable and writable, so the agent can document a new variable.
DEFAULT_MASKED=(.env '.env.*' '*.pem' '*.key' '*.p12' '*.pfx' '*.jks' '*.keystore' .npmrc .pypirc .netrc '*.tfstate' '*.tfvars')
DEFAULT_UNMASKED=(.env.example .env.sample .env.template .env.dist)

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
  BUILD_<ARG>         profile .env only: build arg <ARG> of the profile Dockerfile (your stack, e.g. BUILD_NODE_IMAGE)
  CLAUDE_CODE_VERSION root .env only: latest (default), stable or a version number
  AGENT_PROXY_MODE    enforce (default) or learn: learn reports content violations instead of blocking
  EXTRA_DOC_DOMAINS   more doc hosts, space separated
  AGENT_CPUS, AGENT_MEMORY, AGENT_PIDS, AGENT_SHM
                      container limits, default ${DEFAULT_CPUS}, ${DEFAULT_MEMORY}, ${DEFAULT_PIDS}, ${DEFAULT_SHM}

Profiles: $(profile_names)

Examples:
  ./run.sh my-app                           daily use
  ./run.sh my-app --name second             a second agent with its own login
  ./run.sh my-app proxy-log                 second terminal: what the proxy refused
  PROJECT_PATH=\$(mktemp -d) AGENT_PROXY_MODE=learn ./run.sh my-app --name learn
                                            record Claude Code's calls on an empty project, without blocking content
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

# path prefix...: true when path is one of the prefixes or lies below one
is_under() {
  local path="$1" prefix
  shift
  for prefix in "$@"; do
    if [[ $path == "$prefix" || $path == "$prefix"/* ]]; then return 0; fi
  done
  return 1
}

# file allowed-keys [build]: build also accepts BUILD_<ARG> keys (the profile's stack)
load_env() {
  local file="$1" allowed="$2" build="${3:-}" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || fail "$file: invalid line: $line"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ $allowed != *" $key "* ]]; then
      [[ -n $build && $key =~ $BUILD_KEY_PATTERN ]] || fail "$file: key $key is not allowed here"
      [ "$key" != BUILD_BASE_IMAGE ] || fail "$file: BUILD_BASE_IMAGE is reserved: profiles always build FROM the sandbox base"
      BUILD_KEYS+=("$key")
    fi
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

# ${ARG} values for FROM lines: ARG defaults before the first FROM, then build args
stage_args() {
  local line key
  STAGE_ARGS=()
  while IFS= read -r line; do
    line="${line//\"/}"
    STAGE_ARGS[${line%%=*}]="${line#*=}"
  done < <(awk 'toupper($1) == "FROM" {exit} toupper($1) == "ARG" && $2 ~ /=/ {print $2}' "$PROFILE_DIR/Dockerfile")
  STAGE_ARGS[BASE_IMAGE]="$BASE_IMAGE"
  for key in "${BUILD_KEYS[@]}"; do STAGE_ARGS[${key#BUILD_}]="${!key}"; done
}

pull_stage_images() {
  local image alias name
  local -A aliases=()
  stage_args
  while IFS=$'\t' read -r image alias; do
    if [ -n "$alias" ]; then aliases[$alias]=1; fi
  done < <(stage_images)
  while IFS=$'\t' read -r image alias; do
    for name in "${!STAGE_ARGS[@]}"; do image="${image//"\${$name}"/${STAGE_ARGS[$name]}}"; done
    [[ $image == *'$'* || $image == scratch || $image == "$BASE_IMAGE" || -n ${aliases[$image]:-} ]] && continue
    docker pull -q "$image" >/dev/null || fail "cannot pull $image"
  done < <(stage_images)
}

build_images() {
  local out=/dev/stdout key
  local -a opts=() base_args=() profile_args=(--build-arg "BASE_IMAGE=$BASE_IMAGE")
  if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then base_args=(--build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION"); fi
  for key in "${BUILD_KEYS[@]}"; do profile_args+=(--build-arg "${key#BUILD_}=${!key}"); done
  if [ "${1:-}" = fresh ]; then
    docker build --pull --no-cache "${base_args[@]}" -t "$BASE_IMAGE" "$ROOT/base"
    pull_stage_images
    docker build --no-cache "${profile_args[@]}" -t "$IMAGE" "$PROFILE_DIR"
    return
  fi
  if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    opts=(-q)
    out=/dev/null
  fi
  docker build "${opts[@]}" "${base_args[@]}" -t "$BASE_IMAGE" "$ROOT/base" >"$out"
  docker build "${opts[@]}" "${profile_args[@]}" -t "$IMAGE" "$PROFILE_DIR" >"$out"
}

# Top folder of core.hooksPath when it lies inside the project: git runs hooks from it on your host.
# Fails when hooksPath is the project root itself.
hooks_dir() {
  local project_dir="$1" top path
  top="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
  path="$(git -C "$project_dir" config --type=path --get core.hooksPath 2>/dev/null)" || return 0
  [[ $path == /* ]] || path="$top/$path"
  path="$(realpath -m -- "$path")"
  case "$path/" in "$project_dir/"*) ;; *) return 0 ;; esac
  path="${path#"$project_dir"}"
  path="${path#/}"
  [ -n "$path" ] || return 1
  printf '%s\n' "${path%%/*}"
}

# What makes git (and git-aware shell prompts) or Claude Code run or load something from a folder.
agent_paths() {
  find "$1" -name node_modules -prune -o \( -name .git -o -name .claude -o -name CLAUDE.local.md \) -prune -print 2>/dev/null | sort
}

# project-dir paths-before...: the agent can create these anywhere it writes; flag new non-empty ones.
warn_new_agent_paths() {
  local project_dir="$1" path
  local -A before=()
  local -a created=()
  shift
  for path in "$@"; do before[$path]=1; done
  while IFS= read -r path; do
    [ -z "${before[$path]:-}" ] || continue
    if [ -d "$path" ] && [ -z "$(ls -A "$path" 2>/dev/null)" ]; then continue; fi
    created+=("$path")
  done < <(agent_paths "$project_dir")
  [ "${#created[@]}" -gt 0 ] || return 0
  echo "run.sh: WARNING: created during the session; a .git there can run its own commands as soon as git" >&2
  echo "run.sh: (or a git-aware shell prompt or editor) touches that folder on your host. Review or delete:" >&2
  printf '  %s\n' "${created[@]}" >&2
}

proxy_log() {
  docker container inspect "$NAME" >/dev/null 2>&1 || fail "agent $NAME is not running: start it, then run proxy-log in a second terminal"
  docker exec -u agentproxy "$NAME" tail -n 200 /var/log/agent-proxy/decisions.log
}

start_agent() {
  local project_dir="${PROJECT_PATH:-}"
  local line path pattern masked_file secret_file target tmpfs_path tmpfs_size tmpfs_target extra_columns hooks
  local git_hidden=0 rc=0
  local -A mounted=()
  local -a tmpfs_prune=()
  local -a hidden_prune=()
  local -a instruction_files=()
  local -a readonly_paths=("${DEFAULT_READONLY[@]}")
  local -a hidden_paths=()
  local -a covered_paths=()
  local -a mounted_readonly_paths=()
  local -a mounted_hidden_paths=()
  local -a masked_patterns=("${DEFAULT_MASKED[@]}")
  local -a unmasked_names=("${DEFAULT_UNMASKED[@]}")
  local -a pattern_filters=()
  local -a unmask_filters=()
  local -a template_filters=()
  local -a masked_files=()
  local -a tracked=()
  local -a tmpfs_flags=()
  local -a tmpfs_paths=()
  local -a mount_flags=()
  local -a ipv6_flags=()
  local -a agent_paths_before=()

  [ -n "$project_dir" ] || fail "PROJECT_PATH is not set: add it to profiles/$PROJECT/.env (see profiles/example/.env.example)"
  [ -d "$project_dir" ] || fail "PROJECT_PATH does not exist: $project_dir"
  project_dir="$(cd "$project_dir" && pwd -P)"
  [[ $project_dir != *[:,]* ]] || fail "PROJECT_PATH must not contain ':' or ','"
  case "$HOME/" in "${project_dir%/}/"*) fail "PROJECT_PATH must be a project folder, not $project_dir" ;; esac
  case "$ROOT/" in "${project_dir%/}/"*) fail "PROJECT_PATH must not contain this sandbox repo" ;; esac
  case "${project_dir%/}/" in "$ROOT/"*) fail "PROJECT_PATH must not be inside this sandbox repo" ;; esac

  mapfile -t instruction_files < <(find "$project_dir" \( -name node_modules -o -name .git \) -prune -o \
    \( -name CLAUDE.local.md -o \( \( -type d -o -type l \) -name .claude ! -path "$project_dir/.claude" \) \) -print)
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

  # sorted, so a folder comes before the paths below it
  while IFS= read -r line; do
    is_safe_relative_path "$line" || fail "hidden.txt: invalid path $line"
    hidden_paths+=("${line%/}")
  done < <(entries "$PROFILE_DIR/hidden.txt" | LC_ALL=C sort -u)

  while IFS= read -r line; do
    [[ $line =~ ^!?[A-Za-z0-9._*?-]+$ ]] || fail "masked.txt: invalid file name pattern $line"
    if [[ $line == '!'* ]]; then unmasked_names+=("${line#!}"); else masked_patterns+=("$line"); fi
  done < <(entries "$PROFILE_DIR/masked.txt")

  hooks="$(hooks_dir "$project_dir")" || fail "core.hooksPath is the project root: git would run hooks the agent can write"
  if [ -n "$hooks" ]; then readonly_paths+=("$hooks"); fi
  # every nested repo or submodule pointer: its config and hooks run on your host too
  while IFS= read -r -d '' path; do readonly_paths+=("${path#"$project_dir"/}"); done < <(
    find "$project_dir" -name node_modules -prune -o -name .git -prune -path "$project_dir/*/.git" -print0)

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
    mounted[$tmpfs_target]=1
    if [[ $tmpfs_target == /workspace/* ]]; then
      covered_paths+=("${tmpfs_target#/workspace/}")
      tmpfs_prune+=(-o -path "$project_dir${tmpfs_target#/workspace}")
    fi
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

  # Hidden first: a hidden path is never mounted from the host, not even read-only.
  # Nothing is mounted below a hidden folder or a scratch tmpfs: there is no host copy there to protect.
  for path in "${hidden_paths[@]}"; do
    target="/workspace/$path"
    [ -z "${mounted[$target]:-}" ] || continue
    if is_under "$path" "${covered_paths[@]}"; then continue; fi
    if [ -L "$project_dir/$path" ]; then
      fail "hidden path is a symlink: $path"
    elif [ -d "$project_dir/$path" ]; then
      mount_flags+=(-v "$EMPTY_DIR:$target:ro")
      hidden_prune+=(-o -path "$project_dir/$path")
    elif [ -e "$project_dir/$path" ]; then
      mount_flags+=(-v "/dev/null:$target:ro")
    else
      fail "hidden path does not exist (typo?): $path"
    fi
    [ "$path" != .git ] || git_hidden=1
    mounted[$target]=1
    mounted_hidden_paths+=("$path")
    covered_paths+=("$path")
  done

  for path in "${readonly_paths[@]}"; do
    target="/workspace/$path"
    [ -z "${mounted[$target]:-}" ] || continue
    if is_under "$path" "${covered_paths[@]}"; then continue; fi
    [[ $path != *[:,]* ]] || fail "cannot protect a path with ':' or ',': $path"
    if [ -L "$project_dir/$path" ]; then
      fail "readonly path is a symlink: $path"
    elif [ -e "$project_dir/$path" ]; then
      mount_flags+=(-v "$project_dir/$path:$target:ro")
    elif [ "$path" = .claude ] || [ "$path" = .git ] || [ "$path" = "$hooks" ]; then
      # missing: an empty read-only folder, so the agent cannot plant one for your host to load
      mount_flags+=(-v "$EMPTY_DIR:$target:ro")
    else
      continue
    fi
    mounted[$target]=1
    mounted_readonly_paths+=("$path")
  done

  for pattern in "${masked_patterns[@]}"; do pattern_filters+=(-o -name "$pattern"); done
  pattern_filters=(\( "${pattern_filters[@]:1}" \))
  for pattern in "${unmasked_names[@]}"; do unmask_filters+=(! -name "$pattern"); done
  for pattern in "${DEFAULT_UNMASKED[@]}"; do template_filters+=(! -name "$pattern"); done

  # Masked files (secrets by default) look empty: their content never reaches the agent or the API.
  while IFS= read -r -d '' masked_file; do
    target="/workspace${masked_file#"$project_dir"}"
    [ -z "${mounted[$target]:-}" ] || continue
    [[ $masked_file != *[:,]* ]] || fail "cannot mask a path with ':' or ',': $masked_file"
    mount_flags+=(-v "/dev/null:$target:ro")
    mounted[$target]=1
    masked_files+=("${masked_file#"$project_dir"/}")
  done < <(find "$project_dir" \( -name node_modules -o -name .git "${tmpfs_prune[@]}" "${hidden_prune[@]}" \) -prune -o \
    \( -type f -o -type l \) "${pattern_filters[@]}" "${unmask_filters[@]}" -print0)

  # !name files stay readable, but no tool or script can overwrite them: deny rules only
  # bind Claude's own file tools. Templates are left writable. Regular files only: a symlink
  # source would be resolved on your host and could mount a file from outside the project.
  while IFS= read -r -d '' secret_file; do
    target="/workspace${secret_file#"$project_dir"}"
    [ -z "${mounted[$target]:-}" ] || continue
    [[ $secret_file != *[:,]* ]] || fail "cannot protect a path with ':' or ',': $secret_file"
    mount_flags+=(-v "$secret_file:$target:ro")
    mounted[$target]=1
    mounted_readonly_paths+=("${target#/workspace/}")
  done < <(find "$project_dir" \( -name node_modules -o -name .git "${tmpfs_prune[@]}" "${hidden_prune[@]}" \) -prune -o \
    -type f "${pattern_filters[@]}" "${template_filters[@]}" -print0)

  # Masking covers the working tree only: whatever git tracks is readable from .git.
  if [ -d "$project_dir/.git" ] && [ "$git_hidden" -eq 0 ] && [ $((${#masked_files[@]} + ${#mounted_hidden_paths[@]})) -gt 0 ]; then
    mapfile -d '' -t tracked < <(git --literal-pathspecs -C "$project_dir" ls-files -z -- "${masked_files[@]}" "${mounted_hidden_paths[@]}" 2>/dev/null)
    if [ "${#tracked[@]}" -gt 0 ]; then
      echo "run.sh: masked or hidden files are tracked by git, so .git still holds their content:" >&2
      printf '  %s\n' "${tracked[@]:0:20}" >&2
      fail "untrack them (rotate any committed secret), keep them readable with !name in masked.txt, or add .git to hidden.txt"
    fi
  fi

  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
  # a kernel booted without IPv6 has no such sysctl, and no IPv6 to turn off
  if [ -d /proc/sys/net/ipv6 ]; then
    ipv6_flags=(--sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1)
  fi

  mapfile -t agent_paths_before < <(agent_paths "$project_dir")
  docker run --rm -it --init \
    --name "$NAME" --network "$NETWORK" \
    --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN \
    --security-opt no-new-privileges \
    "${ipv6_flags[@]}" \
    --pids-limit "${AGENT_PIDS:-$DEFAULT_PIDS}" --memory "${AGENT_MEMORY:-$DEFAULT_MEMORY}" --memory-swap "${AGENT_MEMORY:-$DEFAULT_MEMORY}" \
    --cpus "${AGENT_CPUS:-$DEFAULT_CPUS}" --shm-size "${AGENT_SHM:-$DEFAULT_SHM}" \
    "${tmpfs_flags[@]}" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e AGENT_PROJECT="$PROJECT" -e AGENT_PROXY_MODE="$MODE" -e EXTRA_DOC_DOMAINS="${EXTRA_DOC_DOMAINS:-}" \
    -e AGENT_FACTS_READONLY="${mounted_readonly_paths[*]}" \
    -e AGENT_FACTS_HIDDEN="${mounted_hidden_paths[*]:-none}" \
    -e AGENT_FACTS_MASKED="${masked_patterns[*]}" \
    -e AGENT_FACTS_UNMASKED="${unmasked_names[*]:-none}" \
    -e AGENT_FACTS_TMPFS="${tmpfs_paths[*]:-none}" \
    "${mount_flags[@]}" \
    "$IMAGE" || rc=$?
  warn_new_agent_paths "$project_dir" "${agent_paths_before[@]}"
  return "$rc"
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
load_env "$PROFILE_DIR/.env" "$PROJECT_KEYS" build
load_env "$ROOT/.env" "$ROOT_KEYS$BASE_KEYS"

IMAGE="agent-$PROJECT"
MODE="${AGENT_PROXY_MODE:-enforce}"
case "$MODE" in enforce | learn) ;; *) fail "AGENT_PROXY_MODE must be enforce or learn" ;; esac
[[ -z ${CLAUDE_CODE_VERSION:-} || $CLAUDE_CODE_VERSION =~ ^(latest|stable|[0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
  fail "CLAUDE_CODE_VERSION must be latest, stable or a version number like 2.1.0"

case "$CMD" in
  build) build_images fresh ;;
  proxy-log) proxy_log ;;
  start)
    build_images
    start_agent
    ;;
esac
