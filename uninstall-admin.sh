#!/usr/bin/env bash
#
# Forge Personal - full uninstaller. Removes:
#   - all running/stopped workspace containers (forge-workspace-*)
#   - the admin container (forge-personal)
#   - the docker network (forge-workspace-net)
#   - both images (admin + workspace) from local store
#   - the data directory $WORKSPACE_DIR (default: ~/forge-personal),
#     including root-owned files written by the workspace containers
#
# Re-installing afterwards: just run install-admin.sh again.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/uninstall-admin.sh | bash
#   curl -fsSL ...uninstall-admin.sh | bash -s -- --yes        # skip the prompt
#
# This file is ASCII-only on purpose (see install-admin.sh header).

set -euo pipefail

# --- Config (overridable via env) ---
CONTAINER="${CONTAINER:-forge-admin}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/forge-admin}"
ADMIN_IMAGE_REPO="${ADMIN_IMAGE_REPO:-ghcr.io/aiwatching/forge-personal-admin}"
WORKSPACE_IMAGE_REPO="${WORKSPACE_IMAGE_REPO:-ghcr.io/aiwatching/forge-workspace}"
NETWORK="${NETWORK:-forge-workspace-net}"

YES="no"
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES="yes" ;;
    -h|--help)
      sed -n '2,/^set/p' "$0" | sed -n 's/^# \?//p'
      exit 0
      ;;
  esac
done

# --- Pretty output ---
c_red()  { printf '\033[31m%s\033[0m' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m' "$*"; }
step()   { printf '\n%s %s\n' "$(c_grn '>')" "$*"; }
warn()   { printf '%s %s\n' "$(c_ylw '!')" "$*"; }

# --- Pre-flight ---
if ! command -v docker >/dev/null 2>&1; then
  echo "$(c_red 'x') docker not found. Nothing to do." >&2
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "$(c_red 'x') docker daemon not reachable. Start Docker Desktop and retry." >&2
  exit 1
fi

# --- Preview what we're about to nuke ---
echo "Forge Personal uninstaller will remove:"
echo ""
echo "  Containers:"
docker ps -a --format '    - {{.Names}}  ({{.Status}})' \
  --filter "name=^${CONTAINER}$" \
  --filter "name=^forge-workspace-" 2>/dev/null | sort -u || true
docker ps -a --format '{{.Names}}' --filter "name=^${CONTAINER}$" --filter "name=^forge-workspace-" \
  2>/dev/null | grep -q . || echo "    (none running or stopped)"
echo ""
echo "  Docker network:"
docker network ls --format '    - {{.Name}}  ({{.Driver}})' --filter "name=^${NETWORK}$" 2>/dev/null | head -1
docker network ls --format '{{.Name}}' --filter "name=^${NETWORK}$" 2>/dev/null | grep -q . || echo "    (none)"
echo ""
echo "  Images:"
docker images --format '    - {{.Repository}}:{{.Tag}}  ({{.Size}})' \
  --filter "reference=${ADMIN_IMAGE_REPO}*" \
  --filter "reference=${WORKSPACE_IMAGE_REPO}*" 2>/dev/null | sort -u
docker images --format '{{.Repository}}' \
  --filter "reference=${ADMIN_IMAGE_REPO}*" --filter "reference=${WORKSPACE_IMAGE_REPO}*" \
  2>/dev/null | grep -q . || echo "    (none)"
echo ""
echo "  Data directory:"
if [ -d "$WORKSPACE_DIR" ]; then
  du -sh "$WORKSPACE_DIR" 2>/dev/null | awk '{printf "    - %s  (%s)\n", $2, $1}'
else
  echo "    (does not exist)"
fi
echo ""

# --- Confirm ---
if [ "$YES" != "yes" ]; then
  printf "%s This is destructive. Type %s to proceed, anything else aborts: " \
    "$(c_ylw '!')" "$(c_red 'yes')"
  read -r reply
  if [ "$reply" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# --- Tear down ---
step "Removing containers"
# admin + all workspace-* containers in one shot. `|| true` so an empty list
# doesn't trip set -e.
to_remove=$(docker ps -aq \
  --filter "name=^${CONTAINER}$" \
  --filter "name=^forge-workspace-" 2>/dev/null | tr '\n' ' ')
if [ -n "$to_remove" ]; then
  docker rm -f $to_remove >/dev/null
  printf '  - removed: %s\n' "$to_remove"
else
  printf '  - (no containers found)\n'
fi

step "Removing docker network"
if docker network ls --format '{{.Name}}' --filter "name=^${NETWORK}$" 2>/dev/null | grep -q .; then
  docker network rm "$NETWORK" >/dev/null
  printf '  - removed: %s\n' "$NETWORK"
else
  printf '  - (network not present)\n'
fi

step "Removing images"
# Match by EXACT repository name only - "reference=<repo>" without a trailing
# wildcard, then iterate every tag. Earlier versions used
#   --filter "reference=<repo>*"
# which is a glob match and could sweep in unrelated repos that happened to
# share the prefix (e.g. ghcr.io/aiwatching/forge-workspace-other).
#
# Critically: NO `docker image prune -f` after this. prune removes ALL
# dangling images on the host - including completely unrelated build-cache
# layers from other projects. That was the bug that nuked your other work.
remove_tags_for_repo() {
  local repo="$1"
  # docker images <repo> --format '{{.Repository}}:{{.Tag}}' lists EXACT
  # tags for that repo only. <none>:<none> entries (dangling) are not
  # produced when a repo is specified, so we won't accidentally hit
  # unrelated dangling layers.
  local tags
  tags=$(docker images "$repo" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
         | grep -v '<none>' | sort -u | tr '\n' ' ')
  if [ -n "$tags" ]; then
    # shellcheck disable=SC2086
    docker rmi -f $tags >/dev/null 2>&1 || true
    printf '  - removed: %s\n' "$tags"
  fi
}
remove_tags_for_repo "$ADMIN_IMAGE_REPO"
remove_tags_for_repo "$WORKSPACE_IMAGE_REPO"
# If nothing was reported above, the repos weren't on the host.
docker images "$ADMIN_IMAGE_REPO" -q 2>/dev/null | grep -q . || \
  docker images "$WORKSPACE_IMAGE_REPO" -q 2>/dev/null | grep -q . || \
  printf '  - (no forge images present)\n'

step "Removing data directory $WORKSPACE_DIR"
if [ -d "$WORKSPACE_DIR" ]; then
  # Workspace containers run as a non-host UID and the data dir ends up
  # owned by that UID. Plain `rm -rf` on the host fails with "permission
  # denied" for those files. Use docker itself (always root inside) to
  # wipe the contents, then rmdir the empty shell on the host side.
  if ! rm -rf "$WORKSPACE_DIR" 2>/dev/null; then
    warn "files are container-owned; wiping via docker (no sudo needed)"
    docker run --rm -v "$WORKSPACE_DIR":/wipe alpine sh -c \
      'rm -rf /wipe/* /wipe/.[!.]* /wipe/..?* 2>/dev/null || true' >/dev/null 2>&1
    rmdir "$WORKSPACE_DIR" 2>/dev/null \
      || rm -rf "$WORKSPACE_DIR" 2>/dev/null \
      || warn "could not remove $WORKSPACE_DIR shell; contents wiped"
  fi
  if [ ! -d "$WORKSPACE_DIR" ]; then
    printf '  - removed: %s\n' "$WORKSPACE_DIR"
  fi
else
  printf '  - (directory not present)\n'
fi

# --- Done ---
cat <<EOF

$(c_grn 'OK') Forge Personal uninstalled.

  $(c_dim 'GHCR login is left in place')   ($HOME/.docker/config.json)
  $(c_dim 'Run \`docker logout ghcr.io\` if you want to drop the credentials too.')

  Re-install anytime by running install-admin.sh again.
EOF
