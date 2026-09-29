#!/usr/bin/env bash
#
# Removes everything this repository started: the GitLab instance and its runner,
# the local dev database, the networks they created, the job containers and cache
# volumes the runner left behind, and everything under temp/.
#
# Images are kept, so a rebuild after this starts from what is already pulled.
#
# This is a full wipe, not a reset. temp/gitlab/ holds GitLab's database, secrets
# and repositories, and temp/gitlab_credentials/ the PATs and the runner token, so
# the next gitlab/setup_gitlab.sh is a *first boot* that mints the admin token
# again. To reset only the tutorial project between scenarios, re-run
# gitlab/setup_project.sh instead - that is the one that leaves GitLab, its
# accounts and the runner registration alone.
#
# Nothing here goes through a compose file. Every resource is found by
# com.docker.compose.project, or by the runner's own label, so a half-deleted
# state, a missing gitlab/.env or a compose file that does not exist yet cannot
# stop the teardown - and other projects on the same daemon are never candidates.
#
# Usage: gitlab/cleanup.sh

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Compose project names, as docker records them in container, volume and network
# labels. Each is pinned by `name:` in its compose file, which is the source of
# truth: docker records the label at creation time and nothing here reads a
# compose file back, so these constants have to match it by hand.
GITLAB_PROJECT="gitlab-tutorial"
DEV_PROJECT="tutorial-dev"
# project/docker-compose.prod.yml does not exist yet. When it lands it must
# declare `name: tutorial-prod`; until then this entry matches nothing and the
# sweep is a no-op.
PROD_PROJECT="tutorial-prod"

# The runner labels everything it creates through the host daemon, and it cannot
# return a token twice, so a discarded registration leaves its job containers and
# cache volumes behind with nothing left to collect them. The label is what makes
# them findable after the GitLab project they came from is gone.
RUNNER_LABEL="com.gitlab.gitlab-runner.managed=true"

# Used to delete temp/gitlab/{etc,opt,log}, which GitLab and the runner create as
# root and uid 999 and which a normal user therefore cannot remove.
# RUNNER_EXECUTOR_IMAGE from gitlab/.env replaces this; the default matches the
# pinned value in gitlab/.env.example.
WIPE_IMAGE="docker:24.0.5-cli"

FAILED=0


usage() {
  cat <<'EOF'
Remove every container, volume and network this repository created, and empty
temp/ - GitLab's own state and the credentials included. Images are kept.

To reset only the tutorial project between scenarios, re-run
gitlab/setup_project.sh instead. To come back after this, run
gitlab/setup_gitlab.sh (a first boot again) followed by gitlab/setup_project.sh.

  -h, --help    show this
EOF
}


# ---------------------------------------------------------------- phases
# A missing gitlab/.env is not an error: a teardown has to work from whatever
# state has been left behind, and the labels below - not the env file - are what
# find the resources.
phase_preflight() {
  step "Preflight"
  require_docker

  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || warn "$ENV_FILE could not be read; the temp/ wipe will use the default image"
    WIPE_IMAGE="${RUNNER_EXECUTOR_IMAGE:-$WIPE_IMAGE}"
  else
    warn "$ENV_FILE is missing; the project names are pinned in the compose files, so the sweep is unaffected"
  fi

  # The helper runs off the host daemon, so this is the same image jobs use and
  # it is normally already present; pulling it is only for a first run.
  if ! docker image inspect "$WIPE_IMAGE" >/dev/null 2>&1; then
    log "pulling        $WIPE_IMAGE (needed to delete root-owned files under temp/)"
    docker pull "$WIPE_IMAGE" >/dev/null \
      || die "could not pull $WIPE_IMAGE; without it the root-owned directories under temp/ cannot be removed"
  fi

  log "projects       $GITLAB_PROJECT, $DEV_PROJECT, $PROD_PROJECT"
  log "temp           $TEMP_DIR (all of it)"
}

# remove_resources <container|volume|network> <docker --filter expression> <what>
#
# Docker's own filter does the scoping: only resources carrying that label come
# back, so nothing else on the daemon can be matched by accident. A failure is
# reported and counted rather than fatal, so one stuck volume does not stop the
# rest of the teardown.
remove_resources() {
  local kind="$1" filter="$2" what="$3" ids count

  case "$kind" in
    container) ids="$(docker container ls -aq --filter "$filter" 2>/dev/null || true)" ;;
    volume)    ids="$(docker volume ls -q --filter "$filter" 2>/dev/null || true)" ;;
    network)   ids="$(docker network ls -q --filter "$filter" 2>/dev/null || true)" ;;
  esac
  [ -n "$ids" ] || return 0

  count="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
  # shellcheck disable=SC2086
  if [ "$kind" = network ]; then
    docker network rm $ids >/dev/null 2>&1 || { warn "could not remove $count $what"; FAILED=1; return 0; }
  else
    docker "$kind" rm -f $ids >/dev/null 2>&1 || { warn "could not remove $count $what"; FAILED=1; return 0; }
  fi
  log "removed        $count $what"
}

phase_resources() {
  step "Containers, volumes and networks"

  # Containers first, then volumes, then networks: a volume cannot be removed
  # while a container holds it, and a compose network goes once its containers
  # have.
  local project
  for project in "$GITLAB_PROJECT" "$DEV_PROJECT" "$PROD_PROJECT"; do
    remove_resources container "label=com.docker.compose.project=$project" "$project containers"
    remove_resources volume    "label=com.docker.compose.project=$project" "$project volumes"
    remove_resources network   "label=com.docker.compose.project=$project" "$project networks"
  done

  # What the runner leaves carries no compose project label, because the executor
  # created it through the daemon rather than compose.
  remove_resources container "label=$RUNNER_LABEL" "leftover runner job containers"
  remove_resources volume    "label=$RUNNER_LABEL" "runner cache volumes"
}

phase_temp() {
  step "temp/"

  # Created rather than assumed: docker creates a missing bind source itself, and
  # it would come back root-owned - after which setup_gitlab.sh could no longer
  # mkdir anything under it.
  mkdir -p -- "$TEMP_DIR"

  # rm -rf as root on the other side of the daemon. The mount point is temp/
  # itself, so only its contents go and temp/ keeps the ownership of whoever ran
  # this. The three patterns are what `*` alone misses: dotfiles, and the
  # `.[!.]`/`..?` names it would otherwise sweep in.
  docker run --rm --entrypoint sh -v "$TEMP_DIR:/wipe" "$WIPE_IMAGE" \
    -c 'rm -rf /wipe/..?* /wipe/.[!.]* /wipe/*' \
    || { warn "could not empty $TEMP_DIR"; FAILED=1; return 0; }

  log "emptied        $TEMP_DIR"
}

phase_report() {
  step "Result"

  if [ "$FAILED" -ne 0 ]; then
    warn "something could not be removed; re-run, or inspect with 'docker ps -a', 'docker volume ls' and 'docker network ls'"
    exit 1
  fi

  log "images         kept, so a rebuild skips pulling and building them again"
  log "gone           $GITLAB_PROJECT, $DEV_PROJECT, $PROD_PROJECT, runner leftovers and temp/"
  log "to come back   gitlab/setup_gitlab.sh    # a first boot again, so allow minutes"
  log "               gitlab/setup_project.sh   # project, protection, clone"
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
  phase_resources
  phase_temp
  phase_report
}

main "$@"
