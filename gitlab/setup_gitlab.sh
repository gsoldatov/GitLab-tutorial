#!/usr/bin/env bash
#
# Brings up the local GitLab instance and registers its containerized runner.
#
# Idempotent: re-running re-renders the configuration, restarts whatever has to
# restart to pick it up, and leaves existing accounts and the runner registration
# alone. Only --force-pat throws credentials away.
#
# Usage: gitlab/setup_gitlab.sh [--force-pat] [--skip-wait]

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FORCE_PAT=false
SKIP_WAIT=false
WAIT_TIMEOUT=900
GITLAB_CONFIG_CHANGED=false
API_TOKEN=""
EXTERNAL_HOST=""

TOKEN_EXPIRY="$(date -d "+$TOKEN_EXPIRY_YEARS year" +%F)"


usage() {
  cat <<'EOF'
Bring up the local GitLab instance and register its containerized runner.

  --force-pat   re-mint every access token and recreate the instance runner
                instead of reusing what is in temp/gitlab_credentials/
  --skip-wait   do not wait for GitLab to become ready; for repeated runs
                while debugging
  -h, --help    show this
EOF
}


# ---------------------------------------------------------------- phases
phase_preflight() {
  step "Preflight"
  require_docker

  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    warn "your user is not in the 'docker' group, so docker commands may need sudo"
  fi

  if [ ! -f "$ENV_FILE" ]; then
    cp -- "$ENV_EXAMPLE" "$ENV_FILE"
    die "gitlab/.env did not exist, so it was created from gitlab/.env.example; review it, then re-run"
  fi

  load_env
  validate_env
  resolve_external_host
  check_ports_available
  check_disk
  check_swap

  log "repository     $REPO_ROOT"
  log "GitLab         $(gitlab_url)"
  log "runner image   gitlab/gitlab-runner:$GITLAB_RUNNER_IMAGE_TAG"
}

phase_render() {
  step "Rendering configuration"
  mkdir -p -- "$TEMP_GITLAB_ETC" "$TEMP_GITLAB/opt" "$TEMP_GITLAB/log" \
    "$TEMP_GITLAB_RUNNER" "$TEMP_DEPLOYMENT" "$TEMP_DEPLOYMENT_NGINX" \
    "$CREDENTIALS_DIR" "$RENDERED_DIR"

  render_template "$TEMPLATES_DIR/gitlab.rb.tmpl" "$RENDERED_DIR/gitlab.rb" \
    "EXTERNAL_HOST=$EXTERNAL_HOST" \
    "HTTP_PORT=$GITLAB_HTTP_PORT" \
    "SSH_PORT=$GITLAB_SSH_PORT" \
    "ADMIN_PASSWORD=$GITLAB_ADMIN_PASSWORD"

  # The runner's token is not needed to render its config: the file refers to
  # $RUNNER_TOKEN and compose supplies the value from the credentials directory.
  render_template "$TEMPLATES_DIR/runner-config.toml.tmpl" "$RENDERED_DIR/runner-config.toml" \
    "RUNNER_CONCURRENT=$RUNNER_CONCURRENT" \
    "RUNNER_DESCRIPTION=$RUNNER_DESCRIPTION" \
    "EXTERNAL_HOST=$EXTERNAL_HOST" \
    "HTTP_PORT=$GITLAB_HTTP_PORT" \
    "RUNNER_EXECUTOR_IMAGE=$RUNNER_EXECUTOR_IMAGE" \
    "REPO_ROOT=$REPO_ROOT"

  # Compared against the hash of the configuration that was last confirmed
  # applied, so an unrelated re-run does not restart GitLab.
  if [ "$(hash_of "$RENDERED_DIR/gitlab.rb")" != "$(cat "$RENDERED_DIR/.gitlab.rb.applied" 2>/dev/null || true)" ]; then
    GITLAB_CONFIG_CHANGED=true
  fi

  deliver_file "$GITLAB_SERVICE" "$RENDERED_DIR/gitlab.rb" "$TEMP_GITLAB_ETC/gitlab.rb"
  deliver_file "$RUNNER_SERVICE" "$RENDERED_DIR/runner-config.toml" "$TEMP_GITLAB_RUNNER/config.toml"

  log "rendered       gitlab.rb, runner-config.toml"
  if [ "$GITLAB_CONFIG_CHANGED" = true ]; then
    log "changed        GitLab will reconfigure to pick this up"
  fi
}

phase_up() {
  step "Starting GitLab"
  local image="gitlab/gitlab-ce:${GITLAB_IMAGE_TAG}"

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "pulling $image - this is a few hundred MB the first time"
    compose pull "$GITLAB_SERVICE"
  fi

  if [ "$GITLAB_CONFIG_CHANGED" = true ] && service_running "$GITLAB_SERVICE"; then
    # A restart is what makes omnibus re-run reconfigure, which is the only way
    # gitlab.rb changes take effect.
    log "restarting     gitlab"
    compose restart "$GITLAB_SERVICE"
  else
    compose up -d "$GITLAB_SERVICE"
    log "started        gitlab"
  fi
}

phase_wait() {
  step "Waiting for GitLab"
  if [ "$SKIP_WAIT" = true ]; then
    log "skipped        (--skip-wait)"
    return 0
  fi
  log "first boot configures PostgreSQL, Gitaly and the rest; this can take several minutes"
  wait_for_gitlab "$WAIT_TIMEOUT"
  hash_of "$RENDERED_DIR/gitlab.rb" >"$RENDERED_DIR/.gitlab.rb.apply"
  mv -- "$RENDERED_DIR/.gitlab.rb.apply" "$RENDERED_DIR/.gitlab.rb.applied"
}

phase_admin_token() {
  step "Admin access token"
  local token_file="$CREDENTIALS_DIR/admin.pat"

  if [ "$FORCE_PAT" = false ] && [ -s "$token_file" ]; then
    API_TOKEN="$(cat "$token_file")"
    if api GET /user >/dev/null 2>&1; then
      log "reusing        $(basename -- "$token_file")"
      return 0
    fi
    warn "the token in $token_file is no longer accepted, minting a new one"
  fi

  API_TOKEN="$(bootstrap_admin_token)"
  api GET /user >/dev/null || die "the token GitLab produced is not accepted yet"
  write_credential "$token_file" "$API_TOKEN"
  log "minted         $(basename -- "$token_file")"
}

# Prints the token and nothing else, so the caller can capture it; progress goes
# to stderr to keep that contract.
bootstrap_admin_token() {
  local output token scopes
  printf '  %s\n' "asking GitLab for one - this boots Rails inside the container and takes a minute" >&2

  # There is no way to obtain the very first token through the API, because
  # creating a token requires a token. The console is the documented way past
  # that, and this is the only step that runs inside GitLab rather than against it.
  #
  # create_runner is the scope POST /user/runners documents, but a GitLab whose
  # model does not register it rejects the whole token, and that would surface
  # only after the long first boot. Fall back to plain api, which an
  # administrator already holds, and report which one was granted.
  output="$(rails_exec "
user = User.find_by_username('$GITLAB_ADMIN_USERNAME') || User.find_by_id(1)
raise 'no admin account found' if user.nil?
expires_at = $TOKEN_EXPIRY_YEARS.year.from_now
begin
  scopes = [:api, :create_runner]
  token = user.personal_access_tokens.create!(scopes: scopes, name: 'gitlab-tutorial-setup', expires_at: expires_at)
rescue ActiveRecord::RecordInvalid
  scopes = [:api]
  token = user.personal_access_tokens.create!(scopes: scopes, name: 'gitlab-tutorial-setup', expires_at: expires_at)
end
puts \"SETUP_TOKEN=#{token.token}\"
puts \"SETUP_SCOPES=#{scopes.join(',')}\"
")" || die "gitlab-rails runner failed"

  token="$(printf '%s\n' "$output" | sed -n 's/^SETUP_TOKEN=//p' | tail -1)"
  [ -n "$token" ] || die "GitLab ran the console but printed no token; output was: $output"
  scopes="$(printf '%s\n' "$output" | sed -n 's/^SETUP_SCOPES=//p' | tail -1)"
  [ "$scopes" = 'api,create_runner' ] \
    || warn "GitLab granted the setup token '$scopes' only, so registering the instance runner over the API may be refused"
  printf '%s' "$token"
}

phase_accounts() {
  step "Accounts"
  local admin username email
  admin="$(api GET /users/1)" || die "could not read the root account"

  username="$(printf '%s' "$admin" | json_get "d['username']")"
  email="$(printf '%s' "$admin" | json_get "d['email']")"

  if [ "$username" != "$GITLAB_ADMIN_USERNAME" ]; then
    log "renaming       root -> $GITLAB_ADMIN_USERNAME"
    api PUT /users/1 "{\"username\": \"$GITLAB_ADMIN_USERNAME\"}" >/dev/null \
      || die "could not rename the root account to $GITLAB_ADMIN_USERNAME"
  else
    log "admin          $GITLAB_ADMIN_USERNAME"
  fi

  # GITLAB_ADMIN_EMAIL is deliberately not applied. Changing an address marks it
  # unconfirmed, and with no SMTP configured nothing can confirm it again - which
  # would lock the account out of the web UI it exists to log into.
  if [ -n "$GITLAB_ADMIN_EMAIL" ] && [ "$GITLAB_ADMIN_EMAIL" != "$email" ]; then
    log "note           admin email stays $email; see GITLAB_ADMIN_EMAIL in gitlab/.env"
  fi

  ensure_user "$GITLAB_OWNER_USERNAME" "Tutorial Owner" \
    "$GITLAB_OWNER_EMAIL" "$GITLAB_OWNER_PASSWORD" "$CREDENTIALS_DIR/owner.pat"
  ensure_user "$GITLAB_DEVELOPER_USERNAME" "Tutorial Developer" \
    "$GITLAB_DEVELOPER_EMAIL" "$GITLAB_DEVELOPER_PASSWORD" "$CREDENTIALS_DIR/developer.pat"
}

ensure_user() {
  local username="$1" name="$2" email="$3" password="$4" token_file="$5"
  local found id response token

  found="$(api GET "/users?username=$username")" || die "could not look up user $username"
  id="$(printf '%s' "$found" | json_get "d[0]['id'] if d else ''")"

  if [ -z "$id" ]; then
    log "creating       $username"
    response="$(api POST /users "{\"username\": \"$username\", \"name\": \"$name\", \"email\": \"$email\", \"password\": \"$password\", \"skip_confirmation\": true}")" \
      || die "could not create $username; with no SMTP configured the account only works because of skip_confirmation"
    id="$(printf '%s' "$response" | json_get "d['id']")"
  else
    log "exists         $username"
  fi

  if [ "$FORCE_PAT" = true ] || [ ! -s "$token_file" ]; then
    response="$(api POST "/users/$id/personal_access_tokens" "{\"name\": \"gitlab-tutorial-$username\", \"scopes\": [\"api\", \"write_repository\"], \"expires_at\": \"$TOKEN_EXPIRY\"}")" \
      || die "could not mint an access token for $username"
    token="$(printf '%s' "$response" | json_get "d['token']")"
    [ -n "$token" ] || die "GitLab returned no token for $username"
    write_credential "$token_file" "$token"
    log "token          $(basename -- "$token_file")"
  else
    log "token kept     $(basename -- "$token_file")"
  fi
}

phase_runner() {
  step "Runner"
  local runner_env="$CREDENTIALS_DIR/runner.env"
  local runners runner_id token=""

  runners="$(api GET /runners/all)" || die "could not list the instance runners"
  runner_id="$(runner_field id "$runners")"
  [ -s "$runner_env" ] && token="$(sed -n 's/^RUNNER_TOKEN=//p' "$runner_env" | tail -1)"

  if [ "$FORCE_PAT" = true ] || [ -z "$token" ] || [ -z "$runner_id" ]; then
    if [ -n "$runner_id" ]; then
      # A token cannot be read back after creation, so a runner we no longer hold
      # the token for is replaced rather than reused.
      log "replacing      instance runner $runner_id"
      api DELETE "/runners/$runner_id" >/dev/null || die "could not delete instance runner $runner_id"
    fi
    token="$(create_runner)"
    write_credential "$runner_env" "RUNNER_TOKEN=$token"
    log "registered     $RUNNER_DESCRIPTION"
  else
    log "reusing        instance runner $runner_id"
  fi

  compose up -d "$RUNNER_SERVICE"
  wait_for_runner
}

create_runner() {
  local response token
  response="$(api POST /user/runners "{\"runner_type\": \"instance_type\", \"description\": \"$RUNNER_DESCRIPTION\", \"run_untagged\": true, \"locked\": false, \"tag_list\": []}")" \
    || die "could not create the instance runner; that needs an administrator token with the create_runner scope"
  token="$(printf '%s' "$response" | json_get "d['token']")"
  [ -n "$token" ] || die "GitLab created the runner but returned no token; output was: $response"
  printf '%s' "$token"
}

wait_for_runner() {
  local started=$SECONDS runners status
  while :; do
    runners="$(api GET /runners/all)" || die "could not list the instance runners while waiting for the runner"
    status="$(runner_field status "$runners")"
    if [ "$status" = online ]; then
      log "online         after $((SECONDS - started))s"
      return 0
    fi
    (( SECONDS - started < 180 )) \
      || die "the runner did not come online within 180s; check 'docker compose -f gitlab/docker-compose.yml logs gitlab-runner'"
    sleep 5
  done
}

write_credential() {
  local file="$1" content="$2"
  mkdir -p -- "$(dirname -- "$file")"
  (umask 077; printf '%s\n' "$content" >"$file")
}

phase_report() {
  step "Ready"
  log "GitLab         $(gitlab_url)"
  log "sign in as     $GITLAB_ADMIN_USERNAME with the password in gitlab/.env"
  log "runner         $RUNNER_DESCRIPTION, instance-scoped, online"
  log "credentials    temp/gitlab_credentials/"
}


main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --force-pat) FORCE_PAT=true ;;
      --skip-wait) SKIP_WAIT=true ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown option '$1'; try --help" ;;
    esac
    shift
  done

  phase_preflight
  phase_render
  phase_up
  phase_wait
  phase_admin_token
  phase_accounts
  phase_runner
  phase_report
}

main "$@"
