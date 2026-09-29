#!/usr/bin/env bash
#
# Registers the tutorial project in GitLab and refreshes the clone scenarios push
# branches from.
#
# Deliberately not idempotent. The point of the script is to restore the
# project's default state, so it deletes the project and the clone and builds
# both again: a scenario can then be run over and over without its branches,
# merge requests or deployed state leaking into the next run. Only the project and
# the clone are touched - GitLab's own state and the credentials in
# temp/gitlab_credentials/ are left alone.
#
# Usage: gitlab/setup_project.sh

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PROJECT_NAME="gitlab-tutorial-project"
MAIN_BRANCH="main"
CI_CONFIG_PATH="project/.gitlab-ci.yml"
DEV_COPY="$TEMP_REPO_COPIES/dev"

# A token is embedded in the clone's remote URL, so a rejected one has to fail
# rather than wait for a password prompt that will never come.
export GIT_TERMINAL_PROMPT=0

API_TOKEN=""
DEVELOPER_TOKEN=""
PROJECT_PATH=""
PROJECT_ID=""


usage() {
  cat <<'EOF'
Register (or reset) the tutorial project in GitLab and refresh the clone from
which scenario branches are pushed.

Destructive on purpose: an existing project at this path is deleted first, and
temp/repo_copies/dev is deleted and cloned again - so any branch or merge request
left over from an earlier scenario goes with them.

  -h, --help    show this
EOF
}


# ---------------------------------------------------------------- phases
phase_preflight() {
  step "Preflight"
  require_command git curl python3
  # Only the ci_config_path fallback needs docker: it goes through gitlab-rails.
  require_docker

  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist; run gitlab/setup_gitlab.sh first"
  load_env
  validate_env
  resolve_external_host

  local token_file="$CREDENTIALS_DIR/admin.pat"
  [ -s "$token_file" ] || die "$token_file does not exist; run gitlab/setup_gitlab.sh first"
  API_TOKEN="$(cat "$token_file")"
  api GET /user >/dev/null \
    || die "the token in $token_file is not accepted; re-run gitlab/setup_gitlab.sh --force-pat"

  token_file="$CREDENTIALS_DIR/developer.pat"
  [ -s "$token_file" ] || die "$token_file does not exist; run gitlab/setup_gitlab.sh first"
  DEVELOPER_TOKEN="$(cat "$token_file")"

  # The source of everything published is the local main *ref*, so it has to
  # exist - and it is the only branch that goes.
  git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$MAIN_BRANCH" >/dev/null \
    || die "$REPO_ROOT has no '$MAIN_BRANCH' branch to publish"

  PROJECT_PATH="$GITLAB_ADMIN_USERNAME/$PROJECT_NAME"

  log "GitLab         $(gitlab_url)"
  log "project        $PROJECT_PATH"
  log "source         $MAIN_BRANCH at $(git -C "$REPO_ROOT" log -1 --format='%h %s' "refs/heads/$MAIN_BRANCH")"
}

phase_delete() {
  step "Existing project"
  local existing

  existing="$(project_id_of "$PROJECT_PATH")"
  if [ -z "$existing" ]; then
    log "none           $PROJECT_PATH"
    return 0
  fi

  log "deleting       $PROJECT_PATH (id $existing)"
  delete_project "$existing" \
    || die "could not delete $PROJECT_PATH; if it is listed as pending deletion, remove it in Admin Area > Projects first"
}

phase_create() {
  step "Create project"
  local created="" attempt=0

  while :; do
    created="$(create_project "$PROJECT_NAME")" && break
    # A project deleted a moment ago can still hold its name, and this is the
    # symptom; any other refusal is fatal.
    if [[ "$created" == *"already been taken"* ]] && (( ++attempt < 5 )); then
      log "waiting        the name is not free yet (attempt $attempt)"
      sleep 3
      continue
    fi
    die "could not create $PROJECT_PATH: $created"
  done

  PROJECT_ID="$(printf '%s' "$created" | json_get "d['id']")"
  [ -n "$PROJECT_ID" ] || die "GitLab created the project but returned no id; output was: $created"
  log "created        $PROJECT_PATH (id $PROJECT_ID)"
}

phase_members() {
  step "Members"
  add_project_user "$GITLAB_OWNER_USERNAME" maintainer
  add_project_user "$GITLAB_DEVELOPER_USERNAME" developer
}

# The role is what makes the protection below mean something: only a maintainer
# can merge into main, and a developer can push every other branch.
add_project_user() {
  local username="$1" role="$2" user_id

  user_id="$(user_id_of "$username")"
  [ -n "$user_id" ] || die "there is no user named $username; run gitlab/setup_gitlab.sh"

  add_project_member "$PROJECT_ID" "$user_id" "$role" \
    || die "could not add $username to $PROJECT_PATH"
  log "member         $username ($role)"
}

phase_push() {
  step "Push $MAIN_BRANCH"

  # The source is the local main *ref*, written out in full so the result does
  # not depend on which branch is checked out or on `push.default`. Neither the
  # index nor the working tree takes part, so uncommitted work is never published
  # and an accidental checkout of another branch changes nothing. The credential
  # helper is cleared so one configured on the host cannot answer in the token's
  # place.
  git -C "$REPO_ROOT" -c credential.helper= push \
    "$(git_auth_url "$GITLAB_ADMIN_USERNAME" "$API_TOKEN" "$PROJECT_PATH")" \
    "refs/heads/$MAIN_BRANCH:refs/heads/$MAIN_BRANCH" \
    || die "could not push $MAIN_BRANCH to $PROJECT_PATH"

  log "pushed         $MAIN_BRANCH to $(git_http_url "$PROJECT_PATH")"
}

phase_default_branch() {
  step "Default branch"
  local current

  current="$(api GET "/projects/$PROJECT_ID" | json_get "d.get('default_branch') or ''")"

  if [ "$current" = "$MAIN_BRANCH" ]; then
    log "default        $MAIN_BRANCH"
    return 0
  fi

  # Only reachable when the instance's default initial branch name is something
  # else, which would otherwise leave the project pointing at a branch that the
  # protection below does not cover.
  log "setting        default branch '$current' -> $MAIN_BRANCH"
  api PUT "/projects/$PROJECT_ID" "{\"default_branch\": \"$MAIN_BRANCH\"}" >/dev/null \
    || die "could not make $MAIN_BRANCH the default branch"

  current="$(api GET "/projects/$PROJECT_ID" | json_get "d.get('default_branch') or ''")"
  [ "$current" = "$MAIN_BRANCH" ] || die "GitLab still reports '$current' as the default branch"
  log "default        $MAIN_BRANCH"
}

phase_protect() {
  step "Branch protection"
  protect_branch "$PROJECT_ID" "$MAIN_BRANCH" none maintainer \
    || die "could not protect $MAIN_BRANCH"
  log "protected      $MAIN_BRANCH: no one may push, maintainers may merge"
}

# Runs after the push on purpose: main is published before ci_config_path exists,
# so setup itself starts no pipeline - the first one belongs to a scenario.
phase_ci() {
  step "CI configuration"

  set_ci_config_path "$PROJECT_ID" "$CI_CONFIG_PATH"
  log "ci path        $CI_CONFIG_PATH"

  update_project "$PROJECT_ID" '{"only_allow_merge_if_pipeline_succeeds": true}' \
    || die "could not require a successful pipeline before merging"

  local gate
  gate="$(project_field "$PROJECT_ID" "str(d.get('only_allow_merge_if_pipeline_succeeds')).lower()")"
  [ "$gate" = "true" ] \
    || die "GitLab reports only_allow_merge_if_pipeline_succeeds=$gate"
  log "merge gate     a green pipeline is required to merge into $MAIN_BRANCH"
}

phase_dev_copy() {
  step "Developer clone"

  # Ours and host-owned, so wiping it is safe - and it is what keeps one
  # scenario's branches and commits out of the next one.
  rm -rf -- "$DEV_COPY"
  mkdir -p -- "$TEMP_REPO_COPIES"
  git clone --quiet "$(git_auth_url "$GITLAB_DEVELOPER_USERNAME" "$DEVELOPER_TOKEN" "$PROJECT_PATH")" "$DEV_COPY" \
    || die "could not clone $PROJECT_PATH into $DEV_COPY"

  # Commits made here are the developer's, and this host may have no global git
  # identity for them to fall back on.
  git -C "$DEV_COPY" config user.name "$GITLAB_DEVELOPER_USERNAME"
  git -C "$DEV_COPY" config user.email "$GITLAB_DEVELOPER_EMAIL"

  log "cloned         $DEV_COPY at $(git -C "$DEV_COPY" rev-parse --short HEAD)"
}

phase_report() {
  step "Ready"
  log "project        $(gitlab_url)/$PROJECT_PATH"
  log "members        $GITLAB_OWNER_USERNAME (maintainer), $GITLAB_DEVELOPER_USERNAME (developer)"
  log "clone          temp/repo_copies/dev, origin only, pushing as $GITLAB_DEVELOPER_USERNAME"
  log "ci             $CI_CONFIG_PATH; merging into $MAIN_BRANCH needs a green pipeline"
  log "branches       only $MAIN_BRANCH is published; push a scenario branch from the clone when one is needed"
  log "restore        re-run this script to delete and rebuild both"
}


main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      *) die "unknown option '$1'; try --help" ;;
    esac
    shift
  done

  phase_preflight
  phase_delete
  phase_create
  phase_members
  phase_push
  phase_default_branch
  phase_protect
  phase_ci
  phase_dev_copy
  phase_report
}

main "$@"
