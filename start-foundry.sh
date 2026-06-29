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

docker run -d --name "$NAME" --restart unless-stopped \
  -p "$PORT:$PORT" -v "$VOL:/data" \
  ${FOUNDRY_ADMIN_USERNAME:+-e FOUNDRY_ADMIN_USERNAME="$FOUNDRY_ADMIN_USERNAME"} \
  ${FOUNDRY_ADMIN_PASSWORD:+-e FOUNDRY_ADMIN_PASSWORD="$FOUNDRY_ADMIN_PASSWORD"} \
  "$IMAGE"

echo "✓ → http://localhost:$PORT/"
[ "$RESET" = 1 ] && echo "  login: admin / admin  (forced password change on first login)"
exit 0
