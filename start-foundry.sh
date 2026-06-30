#!/bin/bash
# Pull + (re)start the Foundry Hub on a lab machine.
#
#   ./foundry.sh                 # update & restart
#   ./foundry.sh --reset-users   # also wipe users.json + jwt.key →
#                                #   next start re-bootstraps admin/admin (forced change)
#
# Optional: set a custom bootstrap admin (only takes effect on an empty user
# store, e.g. together with --reset-users):
#   FOUNDRY_ADMIN_PASSWORD='strong-pass' ./foundry.sh --reset-users
set -e

IMAGE="${IMAGE:-ghcr.io/aiwatching/foundry-hub:latest}"
NAME="${NAME:-foundry-hub}"
PORT="${PORT:-18503}"
VOL="${VOL:-foundry-data}"
WIKI_PORT="${WIKI_PORT:-18504}"   # the wiki container the Hub starts from the console
SOCK="${SOCK:-/var/run/docker.sock}"

RESET=0
for a in "$@"; do
  case "$a" in
    --reset-users) RESET=1 ;;
    -h|--help) echo "usage: $0 [--reset-users]"; exit 0 ;;
    *) echo "unknown arg: $a"; echo "usage: $0 [--reset-users]"; exit 1 ;;
  esac
done

docker pull "$IMAGE"
docker rm -f "$NAME" 2>/dev/null || true
docker ps -aq --filter "publish=$PORT" | xargs -r docker rm -f   # free the port

if [ "$RESET" = 1 ]; then
  echo "↻ resetting users (clearing users.json + jwt.key)…"
  docker run --rm -v "$VOL:/data" --entrypoint sh "$IMAGE" -c 'rm -f /data/users.json /data/jwt.key'
fi

# Mount the docker socket so the Hub can start/stop the wiki container (forge-kb
# local mode) from the console. Skip with NO_DOCKER=1 (wiki control disabled).
DOCKER_MOUNT=""
if [ -z "${NO_DOCKER:-}" ] && [ -S "$SOCK" ]; then
  DOCKER_MOUNT="-v $SOCK:/var/run/docker.sock -e FOUNDRY_WIKI_PORT=$WIKI_PORT"
  # Give the Hub this host's registry login so it can pull private images itself
  # (so console Start/Update really pulls, no manual `docker pull`). Read-only.
  # NB: if your docker login uses a credStore/credHelpers, the mounted config
  # references a helper binary absent in the Hub → pull falls back to cache;
  # in that case `docker login ghcr.io -u <user> -p <token>` writes plain creds.
  DCFG="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  if [ -f "$DCFG" ]; then
    DOCKER_MOUNT="$DOCKER_MOUNT -v $DCFG:/root/.docker/config.json:ro"
  fi
fi

docker run -d --name "$NAME" --restart unless-stopped \
  -p "$PORT:$PORT" -v "$VOL:/data" $DOCKER_MOUNT \
  ${FOUNDRY_ADMIN_USERNAME:+-e FOUNDRY_ADMIN_USERNAME="$FOUNDRY_ADMIN_USERNAME"} \
  ${FOUNDRY_ADMIN_PASSWORD:+-e FOUNDRY_ADMIN_PASSWORD="$FOUNDRY_ADMIN_PASSWORD"} \
  "$IMAGE"

echo "✓ → http://localhost:$PORT/   (console → Wiki → Start launches the wiki on :$WIKI_PORT)"
[ "$RESET" = 1 ] && echo "  login: admin / admin  (forced password change on first login)"
exit 0
