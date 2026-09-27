#!/usr/bin/env bash
#
# Proves the runner works end to end. Creates a throwaway project, commits a
# two-job .gitlab-ci.yml, waits for the pipeline, prints the job traces and deletes
# the project again. The point of the jobs is to reach the host's Docker daemon
# through the socket the docker executor mounts into every job container - that
# one assumption is what the whole deploy design rests on.
#
# The project keeps a fixed name and is deleted on every exit path, which is what
# lets the next run create it again.
#
# Usage: gitlab/smoke-test.sh [--timeout SECONDS]

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PROJECT_NAME=smoke-test

# How long the pipeline may take in total, and how long it may take to appear at
# all. The former is generous: a cold run also has to pull the job image.
PIPELINE_TIMEOUT=600
PIPELINE_APPEAR_TIMEOUT=60

API_TOKEN=""
PROJECT_ID=""
PROJECT_PATH=""
DEFAULT_BRANCH=""
COMMIT_SHA=""
PIPELINE_ID=""
PIPELINE_STATUS=""
PIPELINE_URL=""
COMPOSE_STATUS=""


usage() {
  cat <<'EOF'
Prove the runner and the DooD socket work, using a throwaway project.

  --timeout N   how long to wait for the pipeline, in seconds (default 600)
  -h, --help    show this
EOF
}


# The proof job deliberately declares neither image: nor tags:, so it uses the
# docker executor's configured default image (RUNNER_EXECUTOR_IMAGE) and
# exercises run_untagged. The dump of the host's container list and the daemon's
# own name are the evidence that the socket reaches the host rather than a
# nested daemon.
#
# The compose probe is a job of its own, allowed to fail, so that a missing plugin
# is *reported* instead of failing the pipeline. Its status is also the only
# reliable way to ask: GitLab echoes every command into the trace, where a marker
# printed by the job and the command that prints it are indistinguishable.
ci_yaml() {
  cat <<YAML
# Committed by gitlab/smoke-test.sh into a throwaway project. The default CI
# configuration path is .gitlab-ci.yml at the repository root, so nothing has to
# be configured in the project for this to run.
#
# Every command is a single-quoted YAML scalar on purpose: a colon followed by a
# space ends a plain scalar, and these commands carry "daemon: name=..." inside
# them.
stages:
  - smoke

smoke:
  stage: smoke
  script:
    - 'echo "job container hostname: \$(hostname)"'
    - 'docker version'
    - 'docker info --format "daemon: name={{.Name}} os={{.OperatingSystem}} server={{.ServerVersion}}"'
    - 'docker ps --format "{{.Names}} -> {{.Image}}"'

compose:
  stage: smoke
  allow_failure: true
  script:
    - 'docker compose version'
YAML
}


# Deleting a project takes two calls on this GitLab. The first marks it for
# deletion, which is also what frees its name - GitLab renames the path to
# <path>-deletion_scheduled-<id> - and only the second removes it for good. The
# second call wants the *renamed* full path, so that is read back in between.
delete_project() {
  local id="$1" marked path
  api DELETE "/projects/$id" >/dev/null || return 1
  marked="$(api GET "/projects/$id" 2>/dev/null)" || return 1
  path="$(printf '%s' "$marked" | json_get "d['path_with_namespace']" 2>/dev/null)" || path=""
  [ -n "$path" ] || return 1
  api DELETE "/projects/$id?permanently_remove=true&full_path=${path//\//%2F}" >/dev/null
}

# Runs on every exit, success or failure, so a run never leaves the project - or
# its namespace path - behind.
cleanup() {
  local status=$? deleted=true
  if [ -n "$PROJECT_ID" ]; then
    step "Cleanup"
    # Only stdout is discarded: api explains a refused delete on stderr.
    if delete_project "$PROJECT_ID"; then
      log "deleted        $PROJECT_PATH"
    else
      deleted=false
      warn "could not delete $PROJECT_PATH; if it is still listed, remove it in Admin Area > Projects (filter 'Pending deletion')"
    fi
  fi
  [ "$deleted" = true ] || status=1
  exit "$status"
}
trap cleanup EXIT


phase_preflight() {
  step "Preflight"
  require_docker

  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist; run gitlab/setup.sh first"
  load_env
  validate_env
  resolve_external_host

  local token_file="$CREDENTIALS_DIR/admin.pat"
  [ -s "$token_file" ] || die "$token_file does not exist; run gitlab/setup.sh first"
  API_TOKEN="$(cat "$token_file")"
  api GET /user >/dev/null \
    || die "the token in $token_file is not accepted; re-run gitlab/setup.sh --force-pat"

  log "GitLab         $(gitlab_url)"
  log "project        $GITLAB_ADMIN_USERNAME/$PROJECT_NAME"
}


# A pipeline that never runs looks exactly like a slow one, so fail here with the
# reason instead of waiting for a timeout that reports the symptom.
phase_runner() {
  step "Runner"
  local runners status
  runners="$(api GET /runners/all)" || die "could not list the instance runners"
  status="$(runner_field status "$runners")"
  [ "$status" = online ] \
    || die "the instance runner '$RUNNER_DESCRIPTION' is '${status:-missing}', not online; run gitlab/setup.sh, or check 'docker compose -f gitlab/docker-compose.yml logs gitlab-runner'"

  log "online         $RUNNER_DESCRIPTION"
}


phase_create_project() {
  step "Throwaway project"
  local leftover="" created=""

  # A run killed before its trap fired leaves the project behind.
  leftover="$(api GET "/projects/${GITLAB_ADMIN_USERNAME}%2F${PROJECT_NAME}" 2>/dev/null)" || leftover=""
  if [ -n "$leftover" ]; then
    log "replacing      a leftover $PROJECT_NAME"
    delete_project "$(printf '%s' "$leftover" | json_get "d['id']")" \
      || die "a leftover $PROJECT_NAME could not be deleted; remove it in Admin Area > Projects first"
  fi

  # default_branch is not requested here: GitLab decides the initial branch name,
  # and reading it back is more robust than assuming it.
  created="$(api POST /projects "{\"name\": \"$PROJECT_NAME\", \"path\": \"$PROJECT_NAME\", \"visibility\": \"private\", \"initialize_with_readme\": true}")" \
    || die "could not create $PROJECT_NAME; if GitLab reports the name as taken, an earlier run left it pending deletion - remove it in Admin Area > Projects"

  PROJECT_ID="$(printf '%s' "$created" | json_get "d['id']")"
  PROJECT_PATH="$(printf '%s' "$created" | json_get "d['path_with_namespace']")"
  DEFAULT_BRANCH="$(printf '%s' "$created" | json_get "d['default_branch']")"
  [ -n "$PROJECT_ID" ] || die "GitLab created the project but returned no id; output was: $created"
  [ -n "$DEFAULT_BRANCH" ] || die "GitLab returned no default branch for $PROJECT_PATH"

  log "created        $PROJECT_PATH (default branch $DEFAULT_BRANCH)"
}


phase_commit_ci() {
  step "CI configuration"
  local body commits lint errors

  # json.dumps rather than string interpolation: the file content is YAML with
  # quotes and newlines in it.
  body="$(ci_yaml | python3 -c '
import json, sys
print(json.dumps({
    "branch": sys.argv[1],
    "commit_message": "smoke test: prove jobs reach the host docker daemon",
    "content": sys.stdin.read(),
}))
' "$DEFAULT_BRANCH")"

  # GitLab's own parser is the only authority on whether this file is usable, and
  # it answers before anything is committed - so a configuration mistake cannot
  # be mistaken for a runner that did not pick the job up.
  lint="$(api POST "/projects/$PROJECT_ID/ci/lint" "$body")" || die "could not lint the CI configuration"
  errors="$(printf '%s' "$lint" | json_get "' '.join(d.get('errors') or []) if not d.get('valid') else ''")"
  [ -z "$errors" ] || die "GitLab rejected the generated .gitlab-ci.yml: $errors"
  log "lint           valid"

  api POST "/projects/$PROJECT_ID/repository/files/.gitlab-ci.yml" "$body" >/dev/null \
    || die "could not commit .gitlab-ci.yml to $PROJECT_PATH"

  # A file write answers with file_path and branch only, so the commit the branch
  # now points at is what names the pipeline this run is waiting for.
  commits="$(api GET "/projects/$PROJECT_ID/repository/commits?ref_name=$DEFAULT_BRANCH&per_page=1")" \
    || die "could not read the commits on $DEFAULT_BRANCH"
  COMMIT_SHA="$(printf '%s' "$commits" | json_get "d[0]['id'] if d else ''")"
  [ -n "$COMMIT_SHA" ] || die "could not determine the commit on $DEFAULT_BRANCH; output was: $commits"

  log "committed      .gitlab-ci.yml to $DEFAULT_BRANCH (${COMMIT_SHA:0:8})"
}


phase_watch() {
  step "Pipeline"
  local started=$SECONDS pipelines elapsed last_log=0

  while :; do
    pipelines="$(api GET "/projects/$PROJECT_ID/pipelines?sha=$COMMIT_SHA")" \
      || die "could not list pipelines for $COMMIT_SHA"
    PIPELINE_ID="$(printf '%s' "$pipelines" | json_get "d[0]['id'] if d else ''")"
    [ -n "$PIPELINE_ID" ] && break
    (( SECONDS - started < PIPELINE_APPEAR_TIMEOUT )) \
      || die "no pipeline appeared for $COMMIT_SHA within ${PIPELINE_APPEAR_TIMEOUT}s; does the runner pick untagged jobs up?"
    sleep 2
  done

  PIPELINE_URL="$(gitlab_url)/$PROJECT_PATH/-/pipelines/$PIPELINE_ID"
  log "pipeline       $PIPELINE_URL"

  started=$SECONDS
  while :; do
    PIPELINE_STATUS="$(api GET "/projects/$PROJECT_ID/pipelines/$PIPELINE_ID" | json_get "d['status']")" \
      || die "could not read the pipeline status"
    case "$PIPELINE_STATUS" in
      success|failed|canceled|skipped|manual) break ;;
    esac

    elapsed=$((SECONDS - started))
    (( elapsed < PIPELINE_TIMEOUT )) \
      || die "the pipeline was still '$PIPELINE_STATUS' after ${PIPELINE_TIMEOUT}s; see $PIPELINE_URL"
    if (( elapsed - last_log >= 30 )); then
      log "status         $PIPELINE_STATUS (${elapsed}s)"
      last_log=$elapsed
    fi
    if [ "$PIPELINE_STATUS" = pending ] && (( elapsed >= 60 )); then
      warn "the pipeline has been pending for ${elapsed}s; the runner is online, so the job is waiting rather than being picked up"
    fi
    sleep 5
  done

  log "status         $PIPELINE_STATUS (after $((SECONDS - started))s)"
}


# Prints <field> of the job named <name>, or nothing when there is no such job.
# Same shape as runner_field in lib/common.sh, for the same reason: the values go
# into a python expression, so they are passed as arguments rather than inlined.
job_field() {
  local name="$1" field="$2" json="$3"
  printf '%s' "$json" | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
name, field = sys.argv[1], sys.argv[2]
match = next((j for j in jobs if j.get('name') == name), None)
print('' if match is None else match.get(field, ''))
" "$name" "$field"
}

print_trace() {
  local trace
  trace="$(api GET "/projects/$PROJECT_ID/jobs/$1/trace" 2>/dev/null)" || trace=""
  if [ -z "$trace" ]; then
    warn "job $1 produced no trace; see $PIPELINE_URL"
    return 0
  fi
  # Strip the colour codes the runner wraps its trace in.
  printf '\n%s\n' "$trace" | sed -e 's/\x1b\[[0-9;]*[mGKHF]//g' -e 's/\r$//'
}


phase_trace() {
  step "Job trace"
  local jobs smoke_id

  jobs="$(api GET "/projects/$PROJECT_ID/pipelines/$PIPELINE_ID/jobs")" \
    || die "could not list the pipeline's jobs"
  smoke_id="$(job_field smoke id "$jobs")"
  [ -n "$smoke_id" ] || die "the pipeline has no 'smoke' job; see $PIPELINE_URL"

  log "job            smoke: $(job_field smoke status "$jobs")"
  print_trace "$smoke_id"

  # An absent job means the configuration never defined one, which is worth
  # saying differently from a probe that ran and failed.
  COMPOSE_STATUS="$(job_field compose status "$jobs")"
  if [ -z "$COMPOSE_STATUS" ]; then
    COMPOSE_STATUS=missing
    return 0
  fi
  log "job            compose: $COMPOSE_STATUS"
  # Its trace only matters when the probe actually failed, and it is one line.
  [ "$COMPOSE_STATUS" = success ] || print_trace "$(job_field compose id "$jobs")"
}


main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) shift; PIPELINE_TIMEOUT="${1:-}" ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown option '$1'; try --help" ;;
    esac
    shift
  done
  [[ "$PIPELINE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout needs a positive number of seconds"

  phase_preflight
  phase_runner
  phase_create_project
  phase_commit_ci
  phase_watch
  phase_trace

  step "Result"
  case "$COMPOSE_STATUS" in
    success) log "compose        available inside the job image" ;;
    failed) warn "the job image has no docker compose plugin; the deploy job will need an image that has one, or an install step" ;;
    *) warn "the compose probe did not report; read the trace above" ;;
  esac

  [ "$PIPELINE_STATUS" = success ] \
    || die "the smoke pipeline ended '$PIPELINE_STATUS'; see $PIPELINE_URL"

  log "pass           jobs run, and reach the host's docker daemon"
  printf '\n  %s has been deleted again.\n' "$PROJECT_PATH"
}

main "$@"
