#!/usr/bin/env bash
#
# FortiNAC KB Tools - one-command installer.
#
# Lives at: https://github.com/aiwatching/forge-public-info/blob/main/install-fortinac-kb.sh
#
# Usage (default install location ~/IdeaProjects/Fortinac-pd):
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-fortinac-kb.sh | bash
#
# Custom clone location:
#   curl -fsSL .../install-fortinac-kb.sh | KB_DIR=~/work/fortinac-pd bash
#
# Pass installer flags through (e.g. skip MCP registration):
#   curl -fsSL .../install-fortinac-kb.sh | bash -s -- --skip-mcp
#
# Prereqs the user already has:
#   - git, python3
#   - SSH key registered with Fortinet internal GitLab (this script clones via SSH)
#   - VPN / on-network if dops-git106 isn't directly routable
#
# What this script does:
#   1. Clones (or fast-forwards) fortinac-pd at the fortinac-kb-branch
#   2. Invokes the in-repo installer .kb-hooks/install.sh, which sets up:
#        - kb CLI on PATH               (~/.local/bin/kb)
#        - fortinac-kb Claude Code skill (~/.claude/skills/fortinac-kb)
#        - FORGE_KB_REPO env var         (appended to ~/.zshrc, idempotent)
#        - MCP forge-kb server (user)    (if `claude` CLI is present)
#
# Re-running is safe and idempotent.
#
# ASCII-only by convention (see install-personal.sh for why).

set -euo pipefail

# --- Config (overridable via env) ---
KB_REPO="${KB_REPO:-git@dops-git106.fortinet-us.com:fortinac/fortinac-pd.git}"
KB_BRANCH="${KB_BRANCH:-fortinac-kb-branch}"
KB_DIR="${KB_DIR:-$HOME/IdeaProjects/Fortinac-pd}"

echo "FortiNAC KB Tools bootstrap"
echo "  repo:    $KB_REPO"
echo "  branch:  $KB_BRANCH"
echo "  to:      $KB_DIR"
echo ""

# --- Sanity: required commands ---
for cmd in git python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[FAIL] '$cmd' not on PATH. Install it first." >&2
    exit 1
  fi
done

# --- Sanity: SSH access to the GitLab host (auth_methods returns 1 on auth, 0 on success in our case) ---
SSH_HOST=$(echo "$KB_REPO" | sed -E 's|^[^@]+@([^:]+):.*|\1|')
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "git@$SSH_HOST" -T >/dev/null 2>&1; then
  RC=$?
  # GitLab returns 1 even on a successful auth ('Welcome to GitLab'). Treat
  # ANY response other than connection refused / timeout as success.
  if [ "$RC" -ge 255 ]; then
    echo "[FAIL] Cannot reach $SSH_HOST over SSH. Are you on VPN?" >&2
    exit 1
  fi
fi

# --- Clone or refresh ---
if [ -d "$KB_DIR/.git" ]; then
  echo "[1/2] Refreshing existing clone..."
  git -C "$KB_DIR" fetch origin "$KB_BRANCH"
  CURRENT_BRANCH=$(git -C "$KB_DIR" rev-parse --abbrev-ref HEAD)
  if [ "$CURRENT_BRANCH" != "$KB_BRANCH" ]; then
    echo "  switching from $CURRENT_BRANCH to $KB_BRANCH"
    git -C "$KB_DIR" checkout "$KB_BRANCH"
  fi
  git -C "$KB_DIR" pull --ff-only
else
  echo "[1/2] Cloning..."
  mkdir -p "$(dirname "$KB_DIR")"
  git clone --branch "$KB_BRANCH" "$KB_REPO" "$KB_DIR"
fi

# --- Verify the in-repo installer is present ---
if [ ! -f "$KB_DIR/.kb-hooks/install.sh" ]; then
  echo "[FAIL] $KB_DIR/.kb-hooks/install.sh not found." >&2
  echo "       Is the branch correct? (expected: $KB_BRANCH)" >&2
  exit 1
fi

# --- Run in-repo installer with any passthrough args ---
echo ""
echo "[2/2] Running in-repo installer..."
echo ""
bash "$KB_DIR/.kb-hooks/install.sh" "$@"
