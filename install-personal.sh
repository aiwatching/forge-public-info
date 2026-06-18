#!/usr/bin/env bash
#
# Forge Personal - one-command installer.
#
# Lives at: https://github.com/aiwatching/forge-public-info/blob/main/install-personal.sh
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-personal.sh | bash -s -- <PAT>
#
# Or download + run:
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-personal.sh -o install-personal.sh
#   chmod +x install-personal.sh
#   ./install-personal.sh <PAT>
#
# Re-running is safe and idempotent - it upgrades the image and recreates
# the container while preserving every workspace under $WORKSPACE_DIR
# (default ~/forge-personal).
#
# This file is intentionally ASCII-only (no en/em-dashes, ellipses, arrows,
# box-drawing). When `bash -s -- <args>` reads the script from a curl pipe,
# multi-byte UTF-8 chars can split across read buffers and break parsing
# (e.g. an ellipsis right after $VAR makes bash see VAR<garbage> as the
# variable name and error with "unbound variable"). Stick to ASCII.

set -euo pipefail

# --- Config (overridable via env) ---
IMAGE="${IMAGE:-ghcr.io/aiwatching/forge-personal-admin:latest}"
CONTAINER="${CONTAINER:-forge-personal}"
HOST_PORT="${HOST_PORT:-4100}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/forge-personal}"
# Any non-empty value for -u works; GHCR validates the PAT scope, not the
# user. Keep a memorable shared identity so docker login log lines are
# distinguishable in corp audit trails.
DOCKER_LOGIN_USER="${DOCKER_LOGIN_USER:-forge-corp-user}"

# --- Pretty output ---
c_red()  { printf '\033[31m%s\033[0m' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m' "$*"; }
step()   { printf '\n%s %s\n' "$(c_grn '>')" "$*"; }
fail()   { printf '\n%s %s\n' "$(c_red 'x')" "$*" >&2; exit 1; }

# --- 1. Args ---
PAT="${1:-${GHCR_PAT:-}}"
if [ -z "$PAT" ]; then
  cat >&2 <<EOF
$(c_red 'x') Missing PAT.

Usage:
  $0 <github-PAT>

Or set env:
  GHCR_PAT=ghp_xxx $0

Ask your admin for the PAT (a string starting with ghp_).
EOF
  exit 1
fi

# --- 2. Pre-flight ---
step "Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
  fail "docker not found.

Install Docker Desktop first:
  https://www.docker.com/products/docker-desktop/

Launch it and wait until the menu-bar whale icon stops animating, then re-run this script."
fi
if ! docker info >/dev/null 2>&1; then
  fail "docker daemon not reachable.

Open Docker Desktop and wait until it says 'Docker Desktop is running', then re-run this script."
fi
printf '  - docker %s\n' "$(docker --version | awk '{print $3}' | tr -d ,)"

# --- 3. Login to GHCR ---
step "Logging in to ghcr.io"
if ! echo "$PAT" | docker login ghcr.io -u "$DOCKER_LOGIN_USER" --password-stdin >/dev/null 2>&1; then
  fail "docker login failed - PAT might be invalid or expired.

Double-check the PAT string (should start with ghp_ and end with no whitespace).
If the PAT was recently rotated, ask your admin for the latest one."
fi
printf '  - login succeeded\n'

# --- 4. Pull image ---
step "Pulling $IMAGE"
if ! docker pull "$IMAGE"; then
  fail "docker pull failed.

If you see 'denied' or 'unauthorized', your PAT does not have access to
the package. Ask your admin to add you to the package or rotate the PAT."
fi

# --- 5. Replace existing container if any ---
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  step "Removing previous $CONTAINER container (workspace data in $WORKSPACE_DIR is preserved)"
  docker rm -f "$CONTAINER" >/dev/null
fi

mkdir -p "$WORKSPACE_DIR"

# --- 6. Start the new container ---
step "Starting $CONTAINER on http://localhost:$HOST_PORT"
# Mount the host's docker auth so the CLI inside admin can hand the GHCR
# bearer token to the host daemon when it pulls the forge-workspace image.
# Without this, `docker compose up` from inside admin gets 401 on private
# ghcr.io tags. Read-only so admin can't mutate the host's credentials.
DOCKER_AUTH_MOUNT=""
if [ -f "$HOME/.docker/config.json" ]; then
  DOCKER_AUTH_MOUNT="-v $HOME/.docker/config.json:/root/.docker/config.json:ro"
fi
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  -p "${HOST_PORT}:4000" \
  -v "$WORKSPACE_DIR:$WORKSPACE_DIR" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  $DOCKER_AUTH_MOUNT \
  -e "WORKSPACE_DIR=$WORKSPACE_DIR" \
  "$IMAGE" >/dev/null

# Give the entrypoint a moment to land, then show its banner.
sleep 1
docker logs "$CONTAINER" 2>&1 | tail -8

# --- 7. Smoke check ---
# Probe localhost:HOST_PORT a few times - the admin takes ~3-5s to boot
# (sqlite open + extension load + listen). If it never answers, dump the
# full logs so the user has something actionable.
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS -o /dev/null -m 1 "http://localhost:$HOST_PORT/" 2>/dev/null; then
    ready=1; break
  fi
  sleep 1
done
if [ "$ready" -eq 0 ]; then
  printf '\n%s admin did not respond on http://localhost:%s within 10s.\n' "$(c_ylw '!')" "$HOST_PORT"
  echo '  Recent logs:'
  docker logs "$CONTAINER" 2>&1 | tail -30 | sed 's/^/    /'
  echo ''
  echo '  Try opening the URL in a browser anyway, or run:'
  echo "    docker logs -f $CONTAINER"
  exit 1
fi

# --- 8. Done ---
cat <<EOF

$(c_grn 'OK') Forge Personal is running.

  URL:        $(c_grn "http://localhost:$HOST_PORT")
  Data dir:   $WORKSPACE_DIR
  Image:      $IMAGE

First-time setup: the URL above will prompt you to create an admin
email + password - that is local to your own copy.

Day-to-day commands:
  docker logs -f $CONTAINER     # follow logs
  docker stop $CONTAINER        # pause
  docker start $CONTAINER       # resume
  $0 <PAT>                      # re-run to upgrade (data preserved)

EOF
