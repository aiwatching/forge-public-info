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

# tinyproxy: a host-side HTTP forward proxy bound to the docker bridge
# gateway. Workspace containers send their HTTP(S) traffic to it; the
# host process then takes the request out via the host's normal routing
# (including any FortiClient ZTNA tunnel), reaching corp-internal targets
# the container can't hit directly from docker NAT.
#
# Default: install + start on Linux when the operator hasn't said
# otherwise. Skip on Mac (FortiClient on Mac uses a different routing
# model that doesn't need this). Operator can pass --no-tinyproxy if
# they really don't want host-level changes, or --with-tinyproxy to
# force install on Mac.
TINYPROXY_MODE="${TINYPROXY_MODE:-auto}"

# --- Pretty output ---
c_red()  { printf '\033[31m%s\033[0m' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m' "$*"; }
step()   { printf '\n%s %s\n' "$(c_grn '>')" "$*"; }
fail()   { printf '\n%s %s\n' "$(c_red 'x')" "$*" >&2; exit 1; }

# --- 1. Args ---
# Positional PAT plus a couple of flags that flip tinyproxy behavior.
# Order doesn't matter: install-personal.sh ghp_xxx --no-tinyproxy
# works the same as --no-tinyproxy ghp_xxx.
PAT=""
for arg in "$@"; do
  case "$arg" in
    --no-tinyproxy)   TINYPROXY_MODE=no  ;;
    --with-tinyproxy) TINYPROXY_MODE=yes ;;
    -h|--help)
      cat <<HELP
Usage: install-personal.sh <PAT> [flags]

Flags:
  --no-tinyproxy     Don't install/configure host tinyproxy. Use when
                     you don't need workspace containers to reach corp-
                     internal targets (no ZTNA / not in corp network).
  --with-tinyproxy   Force install tinyproxy even on macOS (default is
                     to install on Linux only).
  -h, --help         Show this help.

Default behavior (no flag): install tinyproxy on Linux, skip on macOS.

Env var equivalents: TINYPROXY_MODE=auto|yes|no.
HELP
      exit 0 ;;
    *) [ -z "$PAT" ] && PAT="$arg" ;;
  esac
done
PAT="${PAT:-${GHCR_PAT:-}}"
if [ -z "$PAT" ]; then
  cat >&2 <<EOF
$(c_red 'x') Missing PAT.

Usage:
  $0 <github-PAT> [--no-tinyproxy|--with-tinyproxy]

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

# --- tinyproxy setup (host-side HTTP proxy for ZTNA bypass) ---
# Computed: install if (mode=yes) OR (mode=auto AND Linux). Sets the
# LOCAL_HTTP_PROXY var below which gets passed into admin's env, where
# ensureLocalServer() picks it up and writes it onto the local-server
# DB row. Workspace containers then inherit HTTP(S)_PROXY=<gateway:8888>
# via _regen-compose's httpProxyPrefix. Without this, corp-internal
# targets (e.g. dops-git106.fortinet-us.com) time out from inside the
# container even though host can reach them - host's process-level
# routing goes through ZTNA tunnel, docker bridge SNAT can't.
LOCAL_HTTP_PROXY=""

# Gateway IP is the .1 of the workspace subnet we picked above.
TINYPROXY_LISTEN=$(printf '%s' "$FORGE_SUBNET" | sed -E 's#\.0/16$#\.1#')
TINYPROXY_PORT="${TINYPROXY_PORT:-8888}"

want_tinyproxy=no
case "$TINYPROXY_MODE" in
  yes) want_tinyproxy=yes ;;
  no)  want_tinyproxy=no  ;;
  auto)
    # Default-on for Linux. On macOS, FortiClient ZTNA uses transparent
    # interception of host process traffic (utun + per-process routing),
    # and docker bridge traffic doesn't transit those interfaces - so
    # tinyproxy there wouldn't get on the ZTNA path either. We skip
    # Mac to avoid installing something that won't help.
    case "$(uname -s)" in
      Linux) want_tinyproxy=yes ;;
      *)     want_tinyproxy=no
             printf '  - %s (non-Linux host; pass --with-tinyproxy to override)\n' \
               "$(c_dim 'tinyproxy: skipping')" ;;
    esac ;;
  *) fail "TINYPROXY_MODE must be one of: auto, yes, no (got: $TINYPROXY_MODE)" ;;
esac

if [ "$want_tinyproxy" = yes ]; then
  step "Configuring host tinyproxy on $TINYPROXY_LISTEN:$TINYPROXY_PORT"

  # Pick the apt/dnf/pacman package manager that's actually present.
  PM=""
  for c in apt-get dnf pacman zypper; do
    if command -v "$c" >/dev/null 2>&1; then PM="$c"; break; fi
  done
  if [ -z "$PM" ]; then
    printf '  %s no known package manager found - skipping install. Set up tinyproxy manually if needed.\n' \
      "$(c_ylw '!')"
  else
    if command -v tinyproxy >/dev/null 2>&1; then
      printf '  - tinyproxy already installed\n'
    else
      printf '  - installing tinyproxy via %s (needs sudo)\n' "$PM"
      case "$PM" in
        apt-get) sudo apt-get update -qq && sudo apt-get install -y -qq tinyproxy ;;
        dnf)     sudo dnf install -y tinyproxy ;;
        pacman)  sudo pacman -S --noconfirm tinyproxy ;;
        zypper)  sudo zypper install -y tinyproxy ;;
      esac
    fi

    # Write a corp-friendly config: bound to docker bridge gateway, accepts
    # the RFC1918 docker bridge subnets, allows HTTPS CONNECT to 443 + SSH
    # CONNECT to 22 (git clone over SSH).
    sudo tee /etc/tinyproxy/tinyproxy.conf >/dev/null <<EOF
User tinyproxy
Group tinyproxy
Port $TINYPROXY_PORT
Listen $TINYPROXY_LISTEN
Timeout 600
Allow 172.16.0.0/12
Allow 192.168.0.0/16
Allow 10.0.0.0/8
ConnectPort 443
ConnectPort 22
LogLevel Info
EOF
    sudo systemctl enable tinyproxy >/dev/null 2>&1 || true
    sudo systemctl restart tinyproxy

    # Smoke check: is tinyproxy actually listening on the expected ip:port.
    if ss -lnt 2>/dev/null | grep -q "$TINYPROXY_LISTEN:$TINYPROXY_PORT"; then
      printf '  - tinyproxy listening on %s:%s\n' "$TINYPROXY_LISTEN" "$TINYPROXY_PORT"
      LOCAL_HTTP_PROXY="http://$TINYPROXY_LISTEN:$TINYPROXY_PORT"
    else
      printf '  %s tinyproxy installed but not listening on %s:%s yet; admin will start without proxy.\n' \
        "$(c_ylw '!')" "$TINYPROXY_LISTEN" "$TINYPROXY_PORT"
      printf '    Check:  sudo systemctl status tinyproxy\n'
    fi
  fi
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
  -e "LOCAL_HTTP_PROXY=$LOCAL_HTTP_PROXY" \
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
