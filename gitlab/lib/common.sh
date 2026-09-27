#!/usr/bin/env bash
#
# Shared helpers for the scripts in gitlab/. Sourced, never executed: the entry
# scripts set `set -euo pipefail` themselves so that sourcing this file cannot
# change the options of a shell that only wanted the functions.


# ---------------------------------------------------------------- layout
# Resolved from this file's own location, so every script works no matter which
# directory it is invoked from or which cwd it inherits.
LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GITLAB_DIR="$(cd -- "$LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd -- "$GITLAB_DIR/.." && pwd)"

ENV_FILE="$GITLAB_DIR/.env"
ENV_EXAMPLE="$GITLAB_DIR/.env.example"
COMPOSE_FILE="$GITLAB_DIR/docker-compose.yml"
TEMPLATES_DIR="$GITLAB_DIR/templates"

TEMP_DIR="$REPO_ROOT/temp"
TEMP_GITLAB="$TEMP_DIR/gitlab"
TEMP_GITLAB_ETC="$TEMP_GITLAB/etc"
TEMP_GITLAB_RUNNER="$TEMP_GITLAB/runner"
TEMP_DEPLOYMENT="$TEMP_DIR/deployment"
TEMP_DEPLOYMENT_NGINX="$TEMP_DEPLOYMENT/nginx"
CREDENTIALS_DIR="$TEMP_DIR/gitlab_credentials"
RENDERED_DIR="$TEMP_GITLAB/rendered"

GITLAB_SERVICE="gitlab"
RUNNER_SERVICE="gitlab-runner"

# Values that gitlab/.env has to define. GITLAB_EXTERNAL_HOST is missing on
# purpose: empty means "detect it".
REQUIRED_KEYS=(
  GITLAB_IMAGE_TAG
  GITLAB_RUNNER_IMAGE_TAG
  GITLAB_HTTP_PORT
  GITLAB_SSH_PORT
  COMPOSE_PROJECT_NAME
  GITLAB_ADMIN_USERNAME
  GITLAB_ADMIN_PASSWORD
  GITLAB_ADMIN_EMAIL
  GITLAB_OWNER_USERNAME
  GITLAB_OWNER_PASSWORD
  GITLAB_OWNER_EMAIL
  GITLAB_DEVELOPER_USERNAME
  GITLAB_DEVELOPER_PASSWORD
  GITLAB_DEVELOPER_EMAIL
  RUNNER_DESCRIPTION
  RUNNER_CONCURRENT
  RUNNER_EXECUTOR_IMAGE
)

# Any token minted for the tutorial gets an explicit expiry: GitLab applies a
# silent 365-day default otherwise, and non-expiring tokens are reserved for
# service accounts.
TOKEN_EXPIRY_YEARS=1


# ---------------------------------------------------------------- output
log()  { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }


# ---------------------------------------------------------------- environment
load_env() {
  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist; copy gitlab/.env.example to gitlab/.env and fill it in"
  # shellcheck disable=SC1090
  source "$ENV_FILE" || die "$ENV_FILE could not be read; it is sourced as shell, so it must be plain KEY=value lines"
}

require_key() {
  local key="$1"
  [ -n "${!key:-}" ] || MISSING_KEYS+=("$key")
}

check_port() {
  local key="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$key must be a number, got '$value'"
  (( value > 0 && value < 65536 )) || die "$key must be between 1 and 65535, got '$value'"
}

check_username() {
  local key="$1" value="$2"
  (( ${#value} >= 2 && ${#value} <= 255 )) || die "$key must be 2-255 characters, got '$value'"
  [[ "$value" =~ ^[a-zA-Z0-9._-]+$ ]] || die "$key must contain only letters, digits, '.', '_' or '-', got '$value'"
}

# The paths GitLab keeps for itself, which therefore cannot be a username or a
# top-level group. This mirrors Lib::Gitlab::PathRegex::TOP_LEVEL_ROUTES - see
# https://docs.gitlab.com/user/reserved_names/. Checking here is the difference
# between a message now and a 400 after the first boot has already configured
# PostgreSQL, Gitaly and the rest.
RESERVED_USERNAMES=(
  '-' '.well-known' 404.html 422.html 500.html 502.html 503.html admin api
  apple-touch-icon.png assets dashboard deploy.html explore favicon.ico
  favicon.png files groups health_check help import jwt login oauth profile
  projects public robots.txt s search sitemap sitemap.xml sitemap.xml.gz
  slash-command-logo.png snippets unsubscribes uploads users v2
)

check_username_not_reserved() {
  local key="$1" value="$2" reserved
  for reserved in "${RESERVED_USERNAMES[@]}"; do
    [[ "${value,,}" != "$reserved" ]] \
      || die "$key cannot be '$value'; GitLab reserves that name for a top-level path"
  done
}

check_email() {
  local key="$1" value="$2"
  [[ "$value" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "$key does not look like an email address, got '$value'"
}

# Mirrors the rules GitLab itself enforces, so a bad value fails here where the
# message can explain the problem instead of surfacing as a 422 later.
check_password() {
  local key="$1" username="$2" email="$3" password="$4"
  local length=${#password} lowered="${password,,}" local_part="${email%%@*}"

  (( length >= 8 )) || die "$key must be at least 8 characters, GitLab will reject it"
  (( length <= 128 )) || die "$key must be at most 128 characters, GitLab will reject it"
  [[ "$lowered" != *"${username,,}"* ]] || die "$key must not contain the username '$username'; GitLab rejects that"
  [[ "$lowered" != *"${local_part,,}"* ]] || die "$key must not contain the email name '$local_part'; GitLab rejects that"
  [[ "$lowered" != *gitlab* ]] || die "$key must not contain 'gitlab'; GitLab rejects predictable passwords"
  [[ "$lowered" != *devops* ]] || die "$key must not contain 'devops'; GitLab rejects predictable passwords"
}

validate_env() {
  MISSING_KEYS=()
  local key
  for key in "${REQUIRED_KEYS[@]}"; do
    require_key "$key"
  done
  [ ${#MISSING_KEYS[@]} -eq 0 ] || die "gitlab/.env has no value for: ${MISSING_KEYS[*]}"

  check_port GITLAB_HTTP_PORT "$GITLAB_HTTP_PORT"
  check_port GITLAB_SSH_PORT "$GITLAB_SSH_PORT"
  [ "$GITLAB_HTTP_PORT" != "$GITLAB_SSH_PORT" ] || die "GITLAB_HTTP_PORT and GITLAB_SSH_PORT cannot be the same port"
  [[ "$RUNNER_CONCURRENT" =~ ^[1-9][0-9]*$ ]] || die "RUNNER_CONCURRENT must be a positive number, got '$RUNNER_CONCURRENT'"

  check_username GITLAB_ADMIN_USERNAME "$GITLAB_ADMIN_USERNAME"
  check_username GITLAB_OWNER_USERNAME "$GITLAB_OWNER_USERNAME"
  check_username GITLAB_DEVELOPER_USERNAME "$GITLAB_DEVELOPER_USERNAME"
  check_username_not_reserved GITLAB_ADMIN_USERNAME "$GITLAB_ADMIN_USERNAME"
  check_username_not_reserved GITLAB_OWNER_USERNAME "$GITLAB_OWNER_USERNAME"
  check_username_not_reserved GITLAB_DEVELOPER_USERNAME "$GITLAB_DEVELOPER_USERNAME"
  check_email GITLAB_ADMIN_EMAIL "$GITLAB_ADMIN_EMAIL"
  check_email GITLAB_OWNER_EMAIL "$GITLAB_OWNER_EMAIL"
  check_email GITLAB_DEVELOPER_EMAIL "$GITLAB_DEVELOPER_EMAIL"
  check_password GITLAB_ADMIN_PASSWORD "$GITLAB_ADMIN_USERNAME" "$GITLAB_ADMIN_EMAIL" "$GITLAB_ADMIN_PASSWORD"
  check_password GITLAB_OWNER_PASSWORD "$GITLAB_OWNER_USERNAME" "$GITLAB_OWNER_EMAIL" "$GITLAB_OWNER_PASSWORD"
  check_password GITLAB_DEVELOPER_PASSWORD "$GITLAB_DEVELOPER_USERNAME" "$GITLAB_DEVELOPER_EMAIL" "$GITLAB_DEVELOPER_PASSWORD"

  # gitlab.rb is Ruby and embeds the admin password in a single-quoted literal.
  [[ "$GITLAB_ADMIN_PASSWORD" != *"'"* && "$GITLAB_ADMIN_PASSWORD" != *'\'* ]] \
    || die "GITLAB_ADMIN_PASSWORD must not contain a single quote or backslash; it is embedded in a Ruby string literal"
  # The runner description is embedded in a TOML double-quoted string.
  [[ "$RUNNER_DESCRIPTION" != *'"'* && "$RUNNER_DESCRIPTION" != *'\'* ]] \
    || die "RUNNER_DESCRIPTION must not contain a double quote or backslash; it is embedded in a TOML string literal"

  # These names end up in URLs, JSON bodies and Docker volume specs, none of which
  # can express a path containing a space or a colon.
  [[ "$REPO_ROOT" == /* ]] || die "the repository path '$REPO_ROOT' is not absolute; docker resolves bind mounts on the host and needs an absolute path"
  [[ "$REPO_ROOT" != *[[:space:]]* && "$REPO_ROOT" != *:* ]] \
    || die "the repository path '$REPO_ROOT' contains whitespace or a colon, which docker's mount and TOML syntax cannot express; move the repository somewhere simpler"
}

# The published address every consumer has to reach: this machine's shell, its
# browser, the runner manager container and the job containers. The docker
# bridge gateway is the one address that works for all four without a hosts file
# or extra_hosts.
resolve_external_host() {
  if [ -n "${GITLAB_EXTERNAL_HOST:-}" ]; then
    EXTERNAL_HOST="$GITLAB_EXTERNAL_HOST"
    return 0
  fi
  EXTERNAL_HOST="$(docker network inspect bridge --format '{{ (index .IPAM.Config 0).Gateway }}' 2>/dev/null || true)"
  [ -n "$EXTERNAL_HOST" ] \
    || die "could not detect the docker bridge gateway; is the daemon running? Set GITLAB_EXTERNAL_HOST in gitlab/.env to override"
}

gitlab_url() { printf 'http://%s:%s' "$EXTERNAL_HOST" "$GITLAB_HTTP_PORT"; }


# ---------------------------------------------------------------- docker
require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
  docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not available"
}

# Pins the compose file, the env file and the project name, so the scripts never
# depend on the invoking shell's cwd.
compose() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"
}

service_running() {
  compose ps --status running --quiet "$1" 2>/dev/null | grep -q .
}

port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

check_ports_available() {
  # Ports held by our own already-running container are not a conflict - that is
  # simply what a re-run looks like.
  service_running "$GITLAB_SERVICE" && return 0
  local port
  for port in "$GITLAB_HTTP_PORT" "$GITLAB_SSH_PORT"; do
    # An explicit if, not `port_in_use "$port" && die`: a free port makes that
    # predicate return non-zero, and as the last command of the loop it would
    # become the function's exit status and kill the caller under set -e.
    if port_in_use "$port"; then
      die "port $port is already in use; change the ports in gitlab/.env"
    fi
  done
}

check_disk() {
  local available_gb
  available_gb="$(df -Pk "$REPO_ROOT" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}')"
  [ -n "$available_gb" ] || { warn "could not determine free disk space"; return 0; }
  if (( available_gb < 20 )); then
    warn "only ${available_gb} GB free under $REPO_ROOT; GitLab's guidance for a constrained instance assumes about 20 GB, and images, the build cache and the database all land here"
  else
    log "disk           ${available_gb} GB free"
  fi
}

check_swap() {
  local total_mb
  total_mb="$(awk 'NR>1 {sum += $3} END {printf "%d", sum/1024}' /proc/swaps 2>/dev/null || printf '0')"
  if (( total_mb == 0 )); then
    warn "no swap is configured; GitLab's memory-constrained guidance expects at least 1 GB"
  else
    log "swap           ${total_mb} MB"
  fi
}


# ---------------------------------------------------------------- rendering
hash_of() { sha256sum "$1" | awk '{print $1}'; }

# render_template <template> <destination> NAME=value...
#
# Substitutes every __NAME__ placeholder. Substitution is done with bash's own
# expansion rather than sed so that values containing '/', '&' or '\' survive
# intact - passwords land here.
render_template() {
  local template="$1" destination="$2"
  shift 2
  local content pair name value
  content="$(<"$template")"
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    content="${content//__${name}__/$value}"
  done
  # A template that grows a placeholder but no matching argument would otherwise
  # ship literal __FOO__ into gitlab.rb, where Ruby would report the syntax error
  # several layers away from the cause.
  if [[ "$content" =~ __([A-Z_]+)__ ]]; then
    die "$(basename -- "$template") still contains __${BASH_REMATCH[1]}__ after rendering; the template and the render call have drifted apart"
  fi
  printf '%s' "$content" >"$destination"
}

# deliver_file <service> <source> <destination-inside-a-bind-mount>
#
# GitLab and the runner run as root or uid 999 inside their containers and own
# the directories they are given, so after the first reconfigure those paths are
# no longer writable by whoever runs this script. Write directly when that still
# works, and otherwise through a one-shot container, which writes as root on the
# other side of the same bind mount.
deliver_file() {
  local service="$1" source="$2" destination="$3" directory
  directory="$(dirname -- "$destination")"
  if { [ -e "$destination" ] && [ -w "$destination" ]; } \
    || { [ ! -e "$destination" ] && [ -w "$directory" ]; }; then
    cp -- "$source" "$destination"
    return 0
  fi
  compose run --rm --no-deps -T --entrypoint sh "$service" -c 'cat > "$1"' sh "$destination" <"$source" \
    || die "could not deliver $source to $destination, and it was not writable directly either"
}


# ---------------------------------------------------------------- GitLab API
# The token is read from API_TOKEN so that a caller can point a single request at
# a different account without disturbing anything global.
api() {
  local method="$1" path="$2" body="${3:-}" response status payload
  local args=(-sS -X "$method" -H "PRIVATE-TOKEN: ${API_TOKEN:-}" -w $'\n%{http_code}' --max-time 60)
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")

  response="$(curl "${args[@]}" "$(gitlab_url)/api/v4$path")" || return 1
  status="${response##*$'\n'}"
  payload="${response%$'\n'*}"
  printf '%s' "$payload"
  [[ "$status" =~ ^2 ]] && return 0

  # Callers routinely send stdout to /dev/null, and that is exactly when the
  # reason for the failure is worth having: GitLab's message is the only thing
  # that explains a 400. stderr keeps it out of captured bodies.
  warn "$method $path -> HTTP $status: $payload"
  return 1
}

# json_get <python-expression-on-d>   (reads JSON on stdin)
json_get() {
  python3 -c "
import sys, json
d = json.load(sys.stdin)
v = $1
print('' if v is None else v)
"
}

# Running code inside GitLab rather than against it. Needed exactly once: the
# first access token cannot be created through the API, because creating a token
# requires a token.
#
# gitlab-rails' subcommand is called `runner`, an unrelated homonym for the CI
# runner, so this wrapper is named after what it does instead.
rails_exec() {
  compose exec -T "$GITLAB_SERVICE" gitlab-rails runner "$1"
}

# Prints <field> of the instance runner whose description is RUNNER_DESCRIPTION,
# or nothing when there is no such runner. Both setup and the smoke test go by
# description: the id changes whenever the runner is replaced, and the token
# cannot be read back.
runner_field() {
  local field="$1" json="$2"
  printf '%s' "$json" | python3 -c "
import sys, json
runners = json.load(sys.stdin)
description, field = sys.argv[1], sys.argv[2]
match = next((r for r in runners if r.get('description') == description), None)
print('' if match is None else match.get(field, ''))
" "$RUNNER_DESCRIPTION" "$field"
}


# ---------------------------------------------------------------- waiting
wait_for_gitlab() {
  local timeout="$1" started=$SECONDS elapsed
  local url; url="$(gitlab_url)/-/readiness?all=1"

  while :; do
    if curl -fsS -o /dev/null --max-time 10 "$url"; then
      log "ready after $((SECONDS - started))s"
      return 0
    fi
    if ! service_running "$GITLAB_SERVICE"; then
      die "the gitlab container stopped while waiting; check 'docker compose -f gitlab/docker-compose.yml logs gitlab'"
    fi
    elapsed=$((SECONDS - started))
    (( elapsed < timeout )) || die "GitLab was not ready after ${timeout}s; first boot can take a while, so check 'docker compose -f gitlab/docker-compose.yml logs -f gitlab' and re-run"
    if (( elapsed % 60 == 0 )); then
      log "still waiting (${elapsed}s) - first boot configures PostgreSQL, Gitaly and the rest"
    fi
    sleep 5
  done
}
