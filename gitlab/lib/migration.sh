#!/usr/bin/env sh
#
# Runs one Alembic direction for the production database, from the image of the
# target commit so the revision tree matches the deployed code.
#
# Read by the `migrate` job as `sh -c "$(cat gitlab/lib/migration.sh)"`, for the
# same reason gitlab/lib/deployment.sh is: the checkout below rewrites the tree.
#
# Inputs: TARGET_REF, DIRECTION and REVISION (job variables), DEPLOY_DIR (runner).

set -eu

case "$DIRECTION" in
  upgrade|downgrade) ;;
  *) echo "DIRECTION must be 'upgrade' or 'downgrade' (got '$DIRECTION')"; exit 1 ;;
esac
if [ "$DIRECTION" = downgrade ]; then
  case "$REVISION" in
    ""|head|-*) echo "downgrade needs an explicit revision, not 'head' or a relative '-N'"; exit 1 ;;
  esac
fi

: "${DEPLOY_DIR:?DEPLOY_DIR is not set - re-run gitlab/setup_gitlab.sh to apply the runner environment}"
ENV_FILE="$DEPLOY_DIR/.production.env"
[ -f "$ENV_FILE" ] || { echo "$ENV_FILE is missing - run gitlab/setup_project.sh"; exit 1; }

git config --global --add safe.directory "$CI_PROJECT_DIR"
TARGET_REF="${TARGET_REF:-$CI_COMMIT_SHA}"
git fetch --quiet origin
SHA="$(git rev-parse --verify --quiet "$TARGET_REF^{commit}" \
  || git rev-parse --verify --quiet "origin/$TARGET_REF^{commit}")"
[ -n "$SHA" ] || { echo "cannot resolve TARGET_REF='$TARGET_REF'"; exit 1; }
echo "$DIRECTION to $REVISION from $TARGET_REF at $SHA"

git checkout --quiet --detach "$SHA"
APP_IMAGE="gitlab-tutorial-api:$SHA"
export APP_IMAGE

echo "building $APP_IMAGE"
docker build --file project/Dockerfile.prod --tag "$APP_IMAGE" project/

# An explicit revision has to exist in this image's migration tree.
case "$REVISION" in
  head|base) ;;
  *)
    history="$(docker run --rm --env-file "$ENV_FILE" "$APP_IMAGE" \
      alembic -c src/db/alembic/alembic.ini history)"
    printf '%s\n' "$history" | grep -qw -e "$REVISION" \
      || { echo "unknown revision '$REVISION'"; exit 1; }
    ;;
esac

compose() {
  docker compose --file project/docker-compose.prod.yml --env-file "$ENV_FILE" "$@"
}

# The one-shot service bootstraps the role and database, then migrates. "$1" and
# "$2" are DIRECTION and REVISION, passed as arguments rather than interpolated.
compose run --rm migrate sh -c \
  'python -m src.db.scripts.app_db && alembic -c src/db/alembic/alembic.ini "$1" "$2"' \
  _ "$DIRECTION" "$REVISION"
