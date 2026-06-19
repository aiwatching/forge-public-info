#!/usr/bin/env bash
#
# Forge Portal - simplified single-workspace install with portal as the
# landing page. Same admin image as install-personal.sh, but auto-bootstraps
# ONE workspace at first start so you go directly to /portal (Approve /
# Change pw / Logs buttons) without ever seeing the admin "create workspace"
# form.
#
# Use install-portal.sh if you want:
#   - Just one Forge sandbox on this Mac
#   - portal as the only UI you ever look at
#   - Buttons for Approve / Change pw / Restart / Logs out of the box
#
# Use install-personal.sh if you want:
#   - Multiple Forge workspaces (e.g. one per project / client)
#   - The admin management UI to add/remove workspaces over time
#   - Department / fleet aggregation
#
# Lives at: https://github.com/aiwatching/forge-public-info/blob/main/install-portal.sh
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-portal.sh \
#     | bash -s -- <PAT> [options]
#
# ASCII-only (curl|bash multi-byte safety).

set -euo pipefail

# --- Config (CLI flags or env, see -h) ---
IMAGE="${IMAGE:-ghcr.io/aiwatching/forge-personal-admin:latest}"
CONTAINER="${CONTAINER:-forge-portal}"
HOST_PORT="${HOST_PORT:-4100}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/forge-portal}"
SLUG="${SLUG:-$(whoami)}"
PROJECT_DIR="${PROJECT_DIR:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin}"
# Admin password is required to log in to /admin if you ever want to manage
# things. Auto-generated if not passed.
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
# Portal login password (the user-facing one). Auto-generated if not passed.
FORGE_PASSWORD="${FORGE_PASSWORD:-}"
DOCKER_LOGIN_USER="${DOCKER_LOGIN_USER:-forge-corp-user}"
FORGE_SUBNET="${FORGE_SUBNET:-}"

# --- CLI parsing ---
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)             SLUG="$2"; shift 2 ;;
    --project|--project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --admin-email)      ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password)   ADMIN_PASSWORD="$2"; shift 2 ;;
    --portal-password|--forge-password) FORGE_PASSWORD="$2"; shift 2 ;;
    --name|--container) CONTAINER="$2"; shift 2 ;;
    --data-dir|--host-data-dir) WORKSPACE_DIR="$2"; shift 2 ;;
    --port)             HOST_PORT="$2"; shift 2 ;;
    --pat)              ARGS+=("$2"); shift 2 ;;
    -h|--help)
      cat <<HELP
Usage: install-portal.sh <PAT> [options]

Options (all also overridable via env vars of the same name):
  --slug <name>             workspace + portal username (default: $(whoami))
  --project <path>          host path to bind-mount as /data/project
  --admin-email <email>     admin login email (default: admin)
  --admin-password <pw>     admin login password (auto-generated if omitted)
  --portal-password <pw>    portal login password (auto-generated if omitted)
  --name <name>             admin container name (default: forge-portal)
  --data-dir <path>         persistent data dir (default: ~/forge-portal)
  --port <num>              admin/portal host port (default: 4100)
  -h, --help                this help

Forge UI wizard fields (display name, email, GitLab token, Enterprise
key) are still entered in the portal after first login - Forge has no
env contract for those.

Example:
  install-portal.sh ghp_xxx --slug me --project ~/IdeaProjects/myapp
HELP
      exit 0
      ;;
    *)                  ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

# --- Pretty output ---
c_red() { printf '\033[31m%s\033[0m' "$*"; }
c_grn() { printf '\033[32m%s\033[0m' "$*"; }
c_dim() { printf '\033[2m%s\033[0m' "$*"; }
step()  { printf '\n%s %s\n' "$(c_grn '>')" "$*"; }
fail()  { printf '\n%s %s\n' "$(c_red 'x')" "$*" >&2; exit 1; }

# --- PAT ---
PAT="${1:-${GHCR_PAT:-}}"
if [ -z "$PAT" ]; then
  fail "Missing PAT. Usage: $0 <github-PAT> [options]   (or set GHCR_PAT env)"
fi

# --- Pre-flight ---
step "Checking Docker"
command -v docker >/dev/null 2>&1 \
  || fail "docker not found - install Docker Desktop first."
docker info >/dev/null 2>&1 \
  || fail "docker daemon not reachable - start Docker Desktop and retry."
printf '  - docker %s\n' "$(docker --version | awk '{print $3}' | tr -d ,)"

# --- Login to GHCR ---
step "Logging in to ghcr.io"
echo "$PAT" | docker login ghcr.io -u "$DOCKER_LOGIN_USER" --password-stdin >/dev/null 2>&1 \
  || fail "docker login failed - PAT might be invalid or expired."
printf '  - login succeeded\n'

# --- Pull admin + workspace images ---
step "Pulling $IMAGE"
docker pull "$IMAGE" || fail "admin image pull failed."
WORKSPACE_IMAGE="${WORKSPACE_IMAGE:-ghcr.io/aiwatching/forge-workspace:latest}"
step "Pulling $WORKSPACE_IMAGE  (linux/amd64, ~2GB - 2-3 min first time)"
docker pull --platform=linux/amd64 "$WORKSPACE_IMAGE" || fail "workspace image pull failed."

# --- Generate any missing passwords ---
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c16)
fi
if [ -z "$FORGE_PASSWORD" ]; then
  FORGE_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c12)
fi

# --- Compute bcrypt hash of admin password (using node inside the image) ---
# Admin's seedFromEnv reads SEED_ADMIN_PASSWORD_HASH directly. Do the
# bcrypt round here so the plain password never lives in the container env.
step "Generating admin password hash"
ADMIN_PASSWORD_HASH=$(docker run --rm --entrypoint node "$IMAGE" -e "
  const bcrypt = require('/opt/admin/node_modules/bcryptjs');
  process.stdout.write(bcrypt.hashSync(process.argv[1], 10));
" "$ADMIN_PASSWORD")
[ -n "$ADMIN_PASSWORD_HASH" ] || fail "bcrypt hash failed (admin image issue)."

# --- Replace existing container if any ---
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  step "Removing previous $CONTAINER container (workspace data in $WORKSPACE_DIR is preserved)"
  docker rm -f "$CONTAINER" >/dev/null
fi

mkdir -p "$WORKSPACE_DIR"

# --- Detect docker socket + auth mount (same as install-personal.sh) ---
if [ -S "$HOME/.docker/run/docker.sock" ]; then
  SOCK_HOST="$HOME/.docker/run/docker.sock"
elif [ -S "/var/run/docker.sock" ]; then
  SOCK_HOST="/var/run/docker.sock"
else
  fail "no docker socket found. Open Docker Desktop -> Settings -> Advanced
and enable 'Allow the default Docker socket to be used'."
fi
printf '  - docker socket: %s\n' "$SOCK_HOST"

DOCKER_AUTH_MOUNT=""
[ -f "$HOME/.docker/config.json" ] \
  && DOCKER_AUTH_MOUNT="-v $HOME/.docker/config.json:/root/.docker/config.json:ro"

# Auto-pick a free /16 if no override
if [ -z "$FORGE_SUBNET" ]; then
  used=$(docker network ls --format '{{.ID}}' | while read id; do
    docker network inspect "$id" --format '{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}' 2>/dev/null
  done | grep -oE '^172\.[0-9]+' | sort -u)
  for n in $(seq 20 99); do
    if ! printf '%s\n' "$used" | grep -qx "172.$n"; then
      FORGE_SUBNET="172.$n.0.0/16"; break
    fi
  done
  [ -n "$FORGE_SUBNET" ] || fail "no free /16 found - pass FORGE_SUBNET=<subnet>."
fi

# Validate / expand PROJECT_DIR
if [ -n "$PROJECT_DIR" ]; then
  case "$PROJECT_DIR" in
    "~")   PROJECT_DIR="$HOME" ;;
    "~/"*) PROJECT_DIR="$HOME/${PROJECT_DIR#~/}" ;;
  esac
  [ -d "$PROJECT_DIR" ] \
    || fail "PROJECT_DIR ($PROJECT_DIR) does not exist on the host."
fi

# --- Start admin container with BOOTSTRAP_* env ---
step "Starting $CONTAINER on http://localhost:$HOST_PORT"
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  -p "${HOST_PORT}:4000" \
  -v "$WORKSPACE_DIR:$WORKSPACE_DIR" \
  -v "$SOCK_HOST:/var/run/docker.sock" \
  $DOCKER_AUTH_MOUNT \
  -e "WORKSPACE_DIR=$WORKSPACE_DIR" \
  -e "FORGE_SUBNET=$FORGE_SUBNET" \
  -e "SEED_ADMIN_EMAIL=$ADMIN_EMAIL" \
  -e "SEED_ADMIN_PASSWORD_HASH=$ADMIN_PASSWORD_HASH" \
  -e "BOOTSTRAP_SLUG=$SLUG" \
  -e "BOOTSTRAP_FORGE_PASSWORD=$FORGE_PASSWORD" \
  -e "BOOTSTRAP_PROJECT_DIR=$PROJECT_DIR" \
  "$IMAGE" >/dev/null

# --- Wait for admin to come up ---
step "Waiting for admin to start"
admin_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if curl -fsS -o /dev/null -m 2 "http://localhost:$HOST_PORT/" 2>/dev/null; then
    admin_ready=1; break
  fi
  sleep 1
done
[ "$admin_ready" -eq 1 ] || fail "admin didn't respond - check 'docker logs $CONTAINER'."
printf '  - admin up\n'

step "Provisioning workspace '$SLUG' (background - takes ~1-2 min)"
echo "  Tail with:  docker logs -f $CONTAINER"

# --- Print summary ---
cat <<EOF

$(c_grn 'OK') Forge Portal is starting.

  Portal:        $(c_grn "http://localhost:$HOST_PORT/portal")
  Login:         $(c_grn "$SLUG") / $(c_grn "$FORGE_PASSWORD")

  Admin (if needed for management):
  URL:           http://localhost:$HOST_PORT/
  Email:         $ADMIN_EMAIL
  Password:      $ADMIN_PASSWORD

  Data dir:      $WORKSPACE_DIR
$([ -n "$PROJECT_DIR" ] && echo "  Project mount: $PROJECT_DIR -> /data/project")

Workspace boot takes ~1-2 min on the first run (npm install + warm-up).
Open the Portal URL above - if it still shows 'provisioning', refresh in
a minute.

Day-to-day:
  docker logs -f $CONTAINER     # follow logs
  docker stop $CONTAINER        # pause
  docker start $CONTAINER       # resume
  $0 <PAT>                      # re-run to upgrade (data preserved)
EOF
