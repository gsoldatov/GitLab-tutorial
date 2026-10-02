#!/usr/bin/env sh
#
# Deploys one commit to one colour of the production stack.
#
# The deploy job runs it as `sh -c "$(cat gitlab/lib/deployment.sh)"` on purpose:
# the checkout below rewrites the working tree, and a shell reading this file
# from disk could then execute changed content.
#
# Inputs: TARGET_REF, DEPLOY_COLOR and NGINX_PORT (job variables), DEPLOY_DIR
# (runner environment).

set -eu

case "$DEPLOY_COLOR" in
  blue|green) ;;
  *) echo "DEPLOY_COLOR must be 'blue' or 'green' (got '$DEPLOY_COLOR')"; exit 1 ;;
esac

: "${DEPLOY_DIR:?DEPLOY_DIR is not set - re-run gitlab/setup_gitlab.sh to apply the runner environment}"
ENV_FILE="$DEPLOY_DIR/.production.env"
[ -f "$ENV_FILE" ] || { echo "$ENV_FILE is missing - run gitlab/setup_project.sh"; exit 1; }
mkdir -p "$DEPLOY_DIR/nginx"

git config --global --add safe.directory "$CI_PROJECT_DIR"
TARGET_REF="${TARGET_REF:-$CI_COMMIT_SHA}"
git fetch --quiet origin
SHA="$(git rev-parse --verify --quiet "$TARGET_REF^{commit}" \
  || git rev-parse --verify --quiet "origin/$TARGET_REF^{commit}")"
[ -n "$SHA" ] || { echo "cannot resolve TARGET_REF='$TARGET_REF'"; exit 1; }
echo "deploying $DEPLOY_COLOR from $TARGET_REF at $SHA"

git checkout --quiet --detach "$SHA"
APP_IMAGE="gitlab-tutorial-api:$SHA"
export APP_IMAGE

compose() {
  docker compose --file project/docker-compose.prod.yml --env-file "$ENV_FILE" "$@"
}

# Refuse the live colour; recreating the serving container defeats the switch.
CONF="$DEPLOY_DIR/nginx/default.conf"
live=""
if [ -f "$CONF" ]; then
  if grep -q 'server app-blue:8000' "$CONF"; then live=blue; fi
  if grep -q 'server app-green:8000' "$CONF"; then live=green; fi
fi
if [ "$live" = "$DEPLOY_COLOR" ]; then
  echo "app-$DEPLOY_COLOR is already the live colour; deploy to the other one"
  exit 1
fi

echo "building $APP_IMAGE"
docker build --file project/Dockerfile.prod --tag "$APP_IMAGE" project/

compose up --detach "app-$DEPLOY_COLOR"  # its db dependency brings the database up first
container="$(compose ps --quiet "app-$DEPLOY_COLOR")"
[ -n "$container" ] || { echo "app-$DEPLOY_COLOR did not start"; exit 1; }

status=""
i=0
while [ "$i" -lt 60 ]; do
  status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo unknown)"
  case "$status" in healthy|unhealthy) break ;; esac
  i=$((i + 1))
  sleep 2
done
if [ "$status" != healthy ]; then
  echo "app-$DEPLOY_COLOR is not healthy (status=$status)"
  docker logs "$container" || true
  exit 1
fi

# Reload before stopping the old colour: a failed reload must not strand nginx.
sed "s|__UPSTREAM__|app-$DEPLOY_COLOR:8000|" project/nginx/default.conf.tmpl > "$DEPLOY_DIR/nginx/default.conf"
compose up --detach nginx
reloaded=false
i=0
while [ "$i" -lt 15 ]; do
  if compose exec -T nginx nginx -s reload 2>/dev/null; then reloaded=true; break; fi
  i=$((i + 1))
  sleep 1
done
[ "$reloaded" = true ] || { echo "could not reload nginx"; exit 1; }

case "$DEPLOY_COLOR" in blue) other=green ;; green) other=blue ;; esac
compose stop "app-$other" || true
echo "nginx is serving app-$DEPLOY_COLOR"
