#!/usr/bin/env bash
#
# Forge in Docker - minimal single-container install.
#
# Lives at: https://github.com/aiwatching/forge-public-info/blob/main/install-forge.sh
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-forge.sh | bash -s -- <PAT>
#
# Or download + run:
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-forge.sh -o install-forge.sh
#   chmod +x install-forge.sh
#   ./install-forge.sh <PAT>
#
# What this does:
#   - Pulls ghcr.io/aiwatching/forge-workspace:latest (with auth via your PAT)
#   - Runs ONE forge container with sensible defaults
#   - Mounts ~/forge-data to /data so your settings/cookies survive upgrades
#   - Opens browser at http://localhost:18403
#
# What this is NOT:
#   - No "personal admin" web UI to spawn multiple workspaces
#   - No SSH / fleet aggregation
#   - One forge container per host. Run it again with different names + ports
#     for a second sandbox.
#
# ASCII-only on purpose - see install-personal.sh for the curl|bash multi-byte
# rationale.

set -euo pipefail

# --- Config (overridable via env) ---
#
# Doable via env / CLI flags (the only Forge container knobs that exist):
#   IMAGE                ghcr.io/aiwatching/forge-workspace:latest
#   CONTAINER            forge                (also used as container name)
#   HOST_DATA_DIR        $HOME/forge-data     (persisted across upgrades)
#   PROJECT_DIR          (unset)              host path bind-mounted to
#                                             /data/project; lets Forge see
#                                             a pre-existing project on disk
#                                             without having to copy it in
#   FORGE_PORT           18403                host port for Forge UI
#   NEKO_PORT            18080                host port for Neko (remote browser)
#   TERMINAL_PORT        18404                host port for Forge terminal WS
#   BRIDGE_PORT          18407                host port for Forge browser-bridge
#   UDP_LO/UDP_HI        59000/59099          Neko WebRTC UDP range
#   INIT_ADMIN_PASSWORD  admin                first-login admin password
#                                             (change it in the UI after)
#   FORGE_HTTP_PROXY     (unset)              corp HTTP(S) proxy URL, if any
#
# NOT doable via env (Forge wizard fields - you fill these in the UI on
# first login, then Forge stores them in /data/forge/settings.yaml):
#   display name, work email, project roots (the wizard offers them anyway,
#   but uses your PROJECT_DIR mount as an option), GitLab token, Enterprise
#   key. The Enterprise key is shared on the team channel.

IMAGE="${IMAGE:-ghcr.io/aiwatching/forge-workspace:latest}"
CONTAINER="${CONTAINER:-forge}"
HOST_DATA_DIR="${HOST_DATA_DIR:-$HOME/forge-data}"
PROJECT_DIR="${PROJECT_DIR:-}"
# Default ports. Forge's terminal + browser-bridge are reached via the
# main Forge UI port (same-origin WebSocket), so we ONLY publish 8403 +
# 8080 + the Neko UDP range. Matches what _regen-compose.sh emits for
# admin-mode workspaces - keeps behavior identical between install-forge
# and install-personal.
FORGE_PORT="${FORGE_PORT:-18403}"
NEKO_PORT="${NEKO_PORT:-18080}"
UDP_LO="${UDP_LO:-59000}"
UDP_HI="${UDP_HI:-59099}"
# Initial admin password. Forge prompts to change on first login.
INIT_ADMIN_PASSWORD="${INIT_ADMIN_PASSWORD:-admin}"
# GHCR login user - any non-empty string; GHCR validates the PAT scope, not
# this string. Keep a memorable shared identity for audit-log readability.
DOCKER_LOGIN_USER="${DOCKER_LOGIN_USER:-forge-corp-user}"

# --- Parse CLI flags (PAT is positional; the rest mirror the env names) ---
# Accept either positional <PAT> or --pat <PAT> for ergonomic curl|bash:
#   curl ... | bash -s -- ghp_xxx --project ~/myproj --port 18503
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project|--project-dir)         PROJECT_DIR="$2"; shift 2 ;;
    --name|--container)              CONTAINER="$2"; shift 2 ;;
    --data-dir|--host-data-dir)      HOST_DATA_DIR="$2"; shift 2 ;;
    --port|--forge-port)             FORGE_PORT="$2"; shift 2 ;;
    --neko-port)                     NEKO_PORT="$2"; shift 2 ;;
    --terminal-port)                 TERMINAL_PORT="$2"; shift 2 ;;
    --bridge-port)                   BRIDGE_PORT="$2"; shift 2 ;;
    --admin-password)                INIT_ADMIN_PASSWORD="$2"; shift 2 ;;
    --http-proxy)                    FORGE_HTTP_PROXY="$2"; shift 2 ;;
    --pat)                           ARGS+=("$2"); shift 2 ;;
    -h|--help)
      cat <<HELP
Usage: install-forge.sh <PAT> [options]

Options (all also overridable via env vars of the same name):
  --project, --project-dir <path>   host path to mount at /data/project
                                    (so Forge sees your existing project)
  --name, --container <name>        container name (default: forge)
  --data-dir <path>                 persistent data dir (default: ~/forge-data)
  --port <num>                      Forge UI host port (default: 18403)
  --neko-port <num>                 Neko host port (default: 18080)
  --terminal-port <num>             Forge terminal host port (default: 18404)
  --bridge-port <num>               browser-bridge host port (default: 18407)
  --admin-password <pw>             first-login admin password (default: admin)
  --http-proxy <url>                outbound HTTP(S) proxy URL (corp ZTNA)
  -h, --help                        show this help

Forge UI wizard fields (display name, email, GitLab token, Enterprise key)
are entered AFTER first login in the Forge UI. They live in /data/forge/.

Examples:
  install-forge.sh ghp_xxx
  install-forge.sh ghp_xxx --project ~/IdeaProjects/myapp
  install-forge.sh ghp_xxx --name forge-projectB --port 18503 --neko-port 18180
HELP
      exit 0
      ;;
    *)                               ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

# --- Pretty output ---
c_red() { printf '\033[31m%s\033[0m' "$*"; }
c_grn() { printf '\033[32m%s\033[0m' "$*"; }
c_dim() { printf '\033[2m%s\033[0m' "$*"; }
step()  { printf '\n%s %s\n' "$(c_grn '>')" "$*"; }
fail()  { printf '\n%s %s\n' "$(c_red 'x')" "$*" >&2; exit 1; }

# --- 1. Args ---
PAT="${1:-${GHCR_PAT:-}}"
if [ -z "$PAT" ]; then
  cat >&2 <<EOF
$(c_red 'x') Missing PAT.

Usage:
  $0 <github-PAT>

Or set env:
  GHCR_PAT=ghp_xxx $0

Ask your admin for the PAT (starts with ghp_).
EOF
  exit 1
fi

# --- 2. Pre-flight ---
step "Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
  fail "docker not found.

Install Docker Desktop first: https://www.docker.com/products/docker-desktop/
Launch it, wait for the menu-bar whale icon to stop animating, then re-run."
fi
if ! docker info >/dev/null 2>&1; then
  fail "docker daemon not reachable. Open Docker Desktop and wait for the
'Docker Desktop is running' message, then re-run this script."
fi
printf '  - docker %s\n' "$(docker --version | awk '{print $3}' | tr -d ,)"

# --- 3. Login to GHCR ---
step "Logging in to ghcr.io"
if ! echo "$PAT" | docker login ghcr.io -u "$DOCKER_LOGIN_USER" --password-stdin >/dev/null 2>&1; then
  fail "docker login failed - PAT might be invalid or expired.

Double-check the PAT (starts with ghp_, no whitespace). If recently rotated,
ask your admin for the latest one."
fi
printf '  - login succeeded\n'

# --- 4. Pull image ---
# --platform=linux/amd64 because the workspace image is amd64-only (Chromium
# under Neko needs native amd64; Apple Silicon hosts use Rosetta translation).
step "Pulling $IMAGE (linux/amd64, ~2GB - 2-3 min first time)"
if ! docker pull --platform=linux/amd64 "$IMAGE"; then
  fail "image pull failed.

If you see 'denied' or 'unauthorized', your PAT does not have access to the
package. Ask your admin to add you or rotate the PAT."
fi

# --- 5. Replace existing container if any ---
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  step "Removing previous $CONTAINER container (data in $HOST_DATA_DIR is preserved)"
  docker rm -f "$CONTAINER" >/dev/null
fi

mkdir -p "$HOST_DATA_DIR"

# --- 6. Start the container ---
# Expand a leading ~ in PROJECT_DIR (bash doesn't expand it inside quoted
# args at run time) and verify the host path exists.
if [ -n "$PROJECT_DIR" ]; then
  case "$PROJECT_DIR" in
    "~")   PROJECT_DIR="$HOME" ;;
    "~/"*) PROJECT_DIR="$HOME/${PROJECT_DIR#~/}" ;;
  esac
  if [ ! -d "$PROJECT_DIR" ]; then
    fail "PROJECT_DIR ($PROJECT_DIR) does not exist on the host.

Pass a host path that already exists, or omit --project to use the empty
default at \$HOST_DATA_DIR/forge/project."
  fi
  PROJECT_MOUNT="-v $PROJECT_DIR:/data/project"
  printf '  - mounting project: %s -> /data/project\n' "$PROJECT_DIR"
else
  PROJECT_MOUNT=""
fi

step "Starting $CONTAINER on http://localhost:$FORGE_PORT"
# Env contract this mirrors what _regen-compose.sh emits for a workspace
# service in admin mode, minus everything admin-specific. Each Neko knob is
# explained in scripts/_regen-compose.sh; the short version:
#   NEKO_MEMBER_*          - v3 multiuser auth (admin/admin + user/<container_name>)
#   NEKO_*_PROFILE / LOCKED - view-only mode (input lockdown prevents the
#                             Rosetta+CGo death we hit when real clicks reach
#                             chromium; Forge drives chromium via CDP/bridge
#                             instead, so this loses no functionality).
#   NEKO_SESSION_IMPLICIT_HOSTING - auto-host on connect (single-tenant default).
#   NEKO_SESSION_MERCIFUL_RECONNECT=false - clean teardown on disconnect (the
#                             amd64-Neko-under-Rosetta combo leaks sessions
#                             otherwise).
#   NEKO_WEBRTC_EPR        - UDP port range that has to match the host ports.
#   NEKO_WEBRTC_NAT1TO1    - IP Neko advertises in ICE candidates; localhost
#                             is correct for personal mode (browser on the
#                             same host).
#   NODE_USE_ENV_PROXY=1 + HTTP(S)_PROXY="" - go DIRECT (no corp tinyproxy on
#                             a Mac); leave NODE_USE_ENV_PROXY on so corp
#                             colleagues who DO want a proxy just set
#                             FORGE_HTTP_PROXY=... before running this script.
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --platform linux/amd64 \
  --shm-size 2gb \
  --init \
  -p "${FORGE_PORT}:8403" \
  -p "${NEKO_PORT}:8080" \
  -p "${UDP_LO}-${UDP_HI}:${UDP_LO}-${UDP_HI}/udp" \
  -v "$HOST_DATA_DIR:/data" \
  $PROJECT_MOUNT \
  -e NEKO_MEMBER_PROVIDER=multiuser \
  -e NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD=admin \
  -e NEKO_MEMBER_MULTIUSER_USER_PASSWORD=forge \
  -e 'NEKO_MEMBER_MULTIUSER_USER_PROFILE={"can_host":false,"can_share_media":false,"can_access_clipboard":false}' \
  -e 'NEKO_MEMBER_MULTIUSER_ADMIN_PROFILE={"can_host":false,"can_share_media":false,"can_access_clipboard":false}' \
  -e NEKO_SESSION_LOCKED_CONTROLS=true \
  -e NEKO_SESSION_IMPLICIT_HOSTING=true \
  -e NEKO_SESSION_MERCIFUL_RECONNECT=false \
  -e NEKO_SERVER_PPROF=true \
  -e NEKO_SERVER_BIND=:8080 \
  -e "NEKO_WEBRTC_EPR=${UDP_LO}-${UDP_HI}" \
  -e NEKO_WEBRTC_ICELITE=true \
  -e NEKO_WEBRTC_NAT1TO1=127.0.0.1 \
  -e FORGE_DATA_DIR=/data/forge \
  -e "FORGE_ADMIN_PASSWORD=${INIT_ADMIN_PASSWORD}" \
  -e FORGE_AUTO_UPGRADE=false \
  -e NODE_USE_ENV_PROXY=1 \
  -e "HTTP_PROXY=${FORGE_HTTP_PROXY:-}" \
  -e "HTTPS_PROXY=${FORGE_HTTP_PROXY:-}" \
  -e "http_proxy=${FORGE_HTTP_PROXY:-}" \
  -e "https_proxy=${FORGE_HTTP_PROXY:-}" \
  -e "NO_PROXY=${FORGE_NO_PROXY:-localhost,127.0.0.1,::1}" \
  -e "no_proxy=${FORGE_NO_PROXY:-localhost,127.0.0.1,::1}" \
  "$IMAGE" >/dev/null

# --- 7. Wait for forge to come up ---
# First boot needs ~60s for forge's npm install + initial build. Probe the
# api/version endpoint with a 90s budget before giving up. If we time out,
# the operator can still hit the URL in a browser - we just won't print the
# "OK" message.
step "Waiting for forge to come up (first boot: 1-2 min for npm install)"
ready=0
for i in $(seq 1 45); do
  if curl -fsS -o /dev/null -m 2 "http://localhost:$FORGE_PORT/api/version" 2>/dev/null; then
    ready=1; break
  fi
  printf '  ... %ds\r' "$((i*2))"
  sleep 2
done
echo ""

if [ "$ready" -eq 1 ]; then
  cat <<EOF

$(c_grn 'OK') Forge is running.

  Forge UI:    $(c_grn "http://localhost:$FORGE_PORT")
  Neko viewer: http://localhost:$NEKO_PORT  (login: admin / admin or forge / forge)
  Data dir:    $HOST_DATA_DIR

First-time login: user $(c_grn 'admin'), password $(c_grn "$INIT_ADMIN_PASSWORD")
(Change this in Forge UI Settings after signing in.)

After signing in, the Forge wizard asks for:
  - Enterprise key  (paste the fortinet key shared on the team channel)
  - Display name + email   (email must be @fortinet.com)
  - Project roots          (point at /data/project if you used --project,
                            otherwise pick any path under /data)
  - GitLab token           (api + read_api scope, <= 200d expiry)

Day-to-day:
  docker logs -f $CONTAINER     # follow logs
  docker stop $CONTAINER        # pause
  docker start $CONTAINER       # resume
  $0 <PAT>                      # re-run to upgrade (data preserved)
  docker rm -f $CONTAINER       # remove (keeps $HOST_DATA_DIR)
EOF
else
  cat <<EOF

$(c_red '!') Forge didn't respond on http://localhost:$FORGE_PORT within 90s.

This usually means npm install is still running. Tail the logs:
  docker logs -f $CONTAINER

If you see 'Installing dependencies...' the container is still warming up
(2-3 min is normal on first boot). If you see errors, paste them along
with 'docker ps --filter name=$CONTAINER --format {{.Status}}'.
EOF
  exit 1
fi
