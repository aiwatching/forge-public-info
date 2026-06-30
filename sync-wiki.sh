#!/bin/bash
# Push a built wiki site (forge-kb /site) to a Foundry Hub via the relay image.
#
# One-shot (default):
#   HUB=http://10.15.33.50:18503 SITE=/path/to/site ENTERPRISE=fortinet DEPARTMENT=eng \
#     ./sync-wiki.sh
#
# Watch (poll forge-kb /_kb/status, push on commit change):
#   HUB=http://10.15.33.50:18503 SITE=/path/to/site ENTERPRISE=fortinet DEPARTMENT=eng \
#     KB_STATUS=http://localhost:18800/_kb/status ./sync-wiki.sh --watch
#
# SITE may be a host path or a named docker volume (e.g. forge-kb's `site`).
# If the Hub/kb-control are on THIS host, set NETWORK=host (Linux) or use
# host.docker.internal in the URLs (Docker Desktop).
set -e

IMAGE="${IMAGE:-ghcr.io/aiwatching/foundry-relay:latest}"
HUB="${HUB:?set HUB, e.g. http://10.15.33.50:18503}"
SITE="${SITE:?set SITE = path (or volume) of the built /site}"
ENTERPRISE="${ENTERPRISE:?set ENTERPRISE, e.g. fortinet}"
DEPARTMENT="${DEPARTMENT:-}"
ROUTE="${ROUTE:-project-wiki}"
COMMIT="${COMMIT:-manual}"
KB_STATUS="${KB_STATUS:-}"
INTERVAL="${INTERVAL:-30s}"
STALE_AFTER="${STALE_AFTER:-86400}"
NETWORK="${NETWORK:-}"
NAME="${NAME:-foundry-relay-$ENTERPRISE-$ROUTE}"

WATCH=0
for a in "$@"; do
  case "$a" in
    --watch) WATCH=1 ;;
    -h|--help) echo "usage: HUB=.. SITE=.. ENTERPRISE=.. [DEPARTMENT=.. ROUTE=.. COMMIT=.. KB_STATUS=.. INTERVAL=.. NETWORK=host] $0 [--watch]"; exit 0 ;;
    *) echo "unknown arg: $a"; exit 1 ;;
  esac
done

docker pull "$IMAGE"
NETARG=""; [ -n "$NETWORK" ] && NETARG="--network $NETWORK"

if [ "$WATCH" = 1 ]; then
  [ -n "$KB_STATUS" ] || { echo "watch mode needs KB_STATUS=http://<kb-control>:18800/_kb/status"; exit 1; }
  docker rm -f "$NAME" 2>/dev/null || true
  docker run -d --name "$NAME" --restart unless-stopped $NETARG \
    -v "$SITE":/site:ro "$IMAGE" \
    -hub "$HUB" -prebuilt /site -kb-status "$KB_STATUS" -poll "$INTERVAL" \
    -enterprise "$ENTERPRISE" -department "$DEPARTMENT" -route "$ROUTE" -stale-after "$STALE_AFTER"
  echo "✓ watching $KB_STATUS — pushing $ROUTE ($ENTERPRISE/$DEPARTMENT) to $HUB on commit change"
  echo "  logs: docker logs -f $NAME"
else
  docker run --rm $NETARG -v "$SITE":/site:ro "$IMAGE" \
    -hub "$HUB" -prebuilt /site -commit "$COMMIT" \
    -enterprise "$ENTERPRISE" -department "$DEPARTMENT" -route "$ROUTE" -stale-after "$STALE_AFTER"
  echo "✓ pushed $ROUTE ($ENTERPRISE/$DEPARTMENT) to $HUB"
fi
