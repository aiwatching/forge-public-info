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
# Subnet for the workspace docker network. Default 172.20.0.0/16 collides
# on Macs that already run docker-compose stacks in that range
# (extremely common). Auto-detect a free /16 below and use it unless the
# operator explicitly set FORGE_SUBNET.
FORGE_SUBNET="${FORGE_SUBNET:-}"

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

# --- 4. Pull images (admin AND workspace) ---
step "Pulling $IMAGE"
if ! docker pull "$IMAGE"; then
  fail "docker pull failed.

If you see 'denied' or 'unauthorized', your PAT does not have access to
the package. Ask your admin to add you to the package or rotate the PAT."
fi

# Pre-pull the workspace image too, BEFORE admin starts spawning provision
# attempts. The workspace image is ~2GB; on first provision, docker compose
# up -d would synchronously pull it inside admin's SSE stream, but with
# zero progress visible to the operator - so a slow pull would manifest
# as "Compose override: ... make: Error 1" with no useful detail, the
# operator would retry, the second attempt found the image cached and
# "worked". Pre-pulling here makes the first provision identical to the
# second and surfaces pull failures right where they belong: at install
# time, with a progress bar.
WORKSPACE_IMAGE="${WORKSPACE_IMAGE:-ghcr.io/aiwatching/forge-workspace:latest}"
step "Pulling $WORKSPACE_IMAGE  (linux/amd64, ~2GB - takes 2-3 min)"
# --platform=linux/amd64 because the workspace image is published amd64-only
# (Chromium under Neko needs native amd64; Apple Silicon runs it via Rosetta).
# Without the explicit platform, docker compose on arm64 hosts would error
# on first up with "no matching manifest for linux/arm64/v8".
if ! docker pull --platform=linux/amd64 "$WORKSPACE_IMAGE"; then
  fail "workspace image pull failed.

Same fix as the admin pull above (PAT scope / rotation). If admin pulled
fine but this one didn't, the workspace image might be a separate package
in GHCR that your PAT doesn't cover - ask your admin to add the package."
fi

# --- 5. Replace existing container if any ---
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  step "Removing previous $CONTAINER container (workspace data in $WORKSPACE_DIR is preserved)"
  docker rm -f "$CONTAINER" >/dev/null
fi

mkdir -p "$WORKSPACE_DIR"

# --- 6. Start the new container ---
# Pick a workspace subnet. If the operator passed FORGE_SUBNET, trust it.
# Otherwise scan the other docker networks' subnets and pick the lowest
# free /16 in 172.20-172.99 (sticking with the documented 172.x bridge
# space). Done before admin starts so the value is in admin's env from
# the very first provision attempt.
if [ -z "$FORGE_SUBNET" ]; then
  step "Picking a free /16 for the workspace docker network"
  used=$(docker network ls --format '{{.ID}}' | while read id; do
    docker network inspect "$id" --format '{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}' 2>/dev/null
  done | grep -oE '^172\.[0-9]+' | sort -u)
  for n in $(seq 20 99); do
    candidate="172.$n.0.0/16"
    if ! printf '%s\n' "$used" | grep -qx "172.$n"; then
      FORGE_SUBNET="$candidate"
      break
    fi
  done
  if [ -z "$FORGE_SUBNET" ]; then
    fail "no free /16 found in 172.20-172.99 - pass FORGE_SUBNET=<subnet> explicitly."
  fi
  printf '  - using %s (auto-picked, free)\n' "$FORGE_SUBNET"
else
  printf '  - using %s (FORGE_SUBNET env override)\n' "$FORGE_SUBNET"
fi

step "Starting $CONTAINER on http://localhost:$HOST_PORT"
# Resolve the docker daemon socket on the host. Docker Desktop on Mac/Windows
# always exposes a user-level socket at ~/.docker/run/docker.sock and that
# one is what `docker` on the CLI normally uses. Some setups ALSO expose
# /var/run/docker.sock - but on Mac it's often a SYMLINK to a path INSIDE
# the Docker Desktop VM, which becomes useless once bind-mounted from the
# Mac filesystem side. Prefer the user-level one; only fall back to the
# system path if the user one isn't there. We always mount it INTO the
# container at /var/run/docker.sock so the entrypoint check sees it at
# the standard location.
if [ -S "$HOME/.docker/run/docker.sock" ]; then
  SOCK_HOST="$HOME/.docker/run/docker.sock"
elif [ -S "/var/run/docker.sock" ]; then
  SOCK_HOST="/var/run/docker.sock"
else
  fail "no docker socket found at $HOME/.docker/run/docker.sock or /var/run/docker.sock.

Open Docker Desktop -> Settings -> Advanced and enable
\"Allow the default Docker socket to be used\", then re-run this script."
fi
# Print what we picked + ls -la so the user can see the real file/symlink
# state if the daemon still isn't reachable from the container.
printf '  - docker socket: %s\n' "$SOCK_HOST"
ls -la "$SOCK_HOST" 2>&1 | sed 's/^/      /'

# Sanity-pre-flight from the OUTSIDE: try the chosen socket with a throw-
# away container BEFORE starting the admin. If even this can't talk to the
# host daemon, the bind itself is broken and admin would just crash-loop.
if ! docker run --rm -v "$SOCK_HOST:/var/run/docker.sock" \
       docker:28-cli version >/dev/null 2>&1; then
  fail "the chosen socket ($SOCK_HOST) is present but a sibling container
cannot talk to the docker daemon through it. This usually means it is a
symlink to a path inside the Docker Desktop VM that bind-mounts can't
reach.

Open Docker Desktop -> Settings -> Advanced and enable
\"Allow the default Docker socket to be used\", then re-run this script.
If you have multiple docker contexts (\`docker context ls\`), switch to
\"desktop-linux\" with \`docker context use desktop-linux\` first."
fi
printf '  - sibling container can reach daemon via this socket\n'

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
  -v "$SOCK_HOST:/var/run/docker.sock" \
  $DOCKER_AUTH_MOUNT \
  -e "WORKSPACE_DIR=$WORKSPACE_DIR" \
  -e "FORGE_SUBNET=$FORGE_SUBNET" \
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
