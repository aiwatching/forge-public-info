#!/usr/bin/env bash
#
# Forge dependency installer — macOS + Linux.
#
# Installs everything Forge needs:
#   Required: node ≥ 20, pnpm, tmux, git, claude code CLI
#   Optional: jq, glab, gh   (used by some pipelines)
# Finally installs/upgrades @aion0/forge globally and starts the server.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-forge-local.sh | bash
#   # or
#   bash scripts/install-forge-local.sh             # interactive (prompts before brew/apt)
#   bash scripts/install-forge-local.sh --yes       # non-interactive
#   bash scripts/install-forge-local.sh --skip-optional
#

set -euo pipefail

# ─── Flags ────────────────────────────────────────────────────────────
ASSUME_YES=0
SKIP_OPTIONAL=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --skip-optional) SKIP_OPTIONAL=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
log()     { printf '\033[36m[forge-install]\033[0m %s\n' "$*"; }
have()    { command -v "$1" >/dev/null 2>&1; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  read -r -p "$1 [y/N] " reply
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ─── Detect OS / package manager ──────────────────────────────────────
OS="$(uname -s)"
PM=""     # brew | apt | dnf | pacman | zypper

case "$OS" in
  Darwin)
    if ! have brew; then
      c_red "Homebrew not installed — install from https://brew.sh first."
      exit 1
    fi
    PM=brew
    ;;
  Linux)
    if have apt-get; then PM=apt
    elif have dnf;     then PM=dnf
    elif have pacman;  then PM=pacman
    elif have zypper;  then PM=zypper
    else
      c_red "No supported package manager found (apt/dnf/pacman/zypper)."
      exit 1
    fi
    ;;
  *)
    c_red "Unsupported OS: $OS  (need Darwin or Linux)"
    exit 1
    ;;
esac

log "Detected: $OS via $PM"

# ─── pkg helper ───────────────────────────────────────────────────────
pkg_install() {
  local pkgs=("$@")
  case "$PM" in
    brew)   brew install "${pkgs[@]}" ;;
    apt)    sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}" ;;
    dnf)    sudo dnf install -y "${pkgs[@]}" ;;
    pacman) sudo pacman -S --noconfirm "${pkgs[@]}" ;;
    zypper) sudo zypper install -y "${pkgs[@]}" ;;
  esac
}

ensure_with_prompt() {
  # ensure_with_prompt <binary> <display-name> <pkg-name-by-pm:...>
  # mapping format:  pm:name,pm:name  (e.g. "brew:gh,apt:gh,dnf:gh")
  local bin="$1" display="$2" mapping="$3"
  if have "$bin"; then
    c_green "  ✓ $display already installed"
    return 0
  fi
  local pkg
  pkg="$(echo "$mapping" | tr ',' '\n' | awk -F: -v pm="$PM" '$1==pm{print $2}')"
  if [ -z "$pkg" ]; then
    c_yellow "  ⚠ $display: no automatic install recipe for $PM — install manually"
    return 0
  fi
  if confirm "Install $display ($PM install $pkg)?"; then
    pkg_install "$pkg"
    c_green "  ✓ $display installed"
  else
    c_yellow "  ⚠ Skipped $display — some Forge features won't work"
  fi
}

# ─── 1. Required ──────────────────────────────────────────────────────
log "Checking required dependencies…"

# Node 20+
if have node; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$NODE_MAJOR" -ge 20 ]; then
    c_green "  ✓ node $(node -v) (≥ 20)"
  else
    c_red "  ✗ node $(node -v) — Forge needs ≥ 20. Install nvm or upgrade your Node."
    exit 1
  fi
else
  c_red "  ✗ node not installed. Install Node 20+ first:"
  echo "      macOS:  brew install node          (or use nvm)"
  echo "      Linux:  use nvm — https://github.com/nvm-sh/nvm"
  echo "              then:  nvm install 20"
  exit 1
fi

# tmux
ensure_with_prompt tmux tmux "brew:tmux,apt:tmux,dnf:tmux,pacman:tmux,zypper:tmux"

# git
ensure_with_prompt git git "brew:git,apt:git,dnf:git,pacman:git,zypper:git"

# pnpm (via npm, not OS pkg)
if have pnpm; then
  c_green "  ✓ pnpm $(pnpm -v)"
else
  if confirm "Install pnpm via npm?"; then
    npm install -g pnpm
    c_green "  ✓ pnpm installed"
  else
    c_yellow "  ⚠ pnpm skipped — Forge build may fail"
  fi
fi

# Claude Code CLI (or codex / aider — at least one needed for tasks)
if have claude || have codex || have aider; then
  c_green "  ✓ Agent CLI found ($(have claude && echo claude)$(have codex && echo ' codex')$(have aider && echo ' aider'))"
else
  c_yellow "  ⚠ No agent CLI installed (claude / codex / aider)"
  if confirm "Install Claude Code via npm?"; then
    npm install -g @anthropic-ai/claude-code
    c_green "  ✓ Claude Code installed"
  else
    c_yellow "  ⚠ Tasks won't run without an agent CLI."
    echo "    Manual install:"
    echo "      npm install -g @anthropic-ai/claude-code"
    echo "      or codex: https://github.com/openai/codex"
  fi
fi

# ─── 2. Optional ──────────────────────────────────────────────────────
if [ "$SKIP_OPTIONAL" = 0 ]; then
  echo ""
  log "Checking optional dependencies (used by some pipelines)…"
  ensure_with_prompt jq   jq   "brew:jq,apt:jq,dnf:jq,pacman:jq,zypper:jq"
  ensure_with_prompt glab glab "brew:glab,apt:glab,dnf:glab,pacman:glab,zypper:glab"
  ensure_with_prompt gh   "GitHub CLI" "brew:gh,apt:gh,dnf:gh,pacman:github-cli,zypper:gh"
fi

# ─── 3. Install / upgrade Forge ───────────────────────────────────────
echo ""
log "Installing / upgrading @aion0/forge…"
if have forge; then
  c_green "  ✓ Forge already installed: $(forge --version 2>/dev/null || echo '?')"
  if confirm "Upgrade to latest?"; then
    npm install -g @aion0/forge
  fi
else
  if confirm "npm install -g @aion0/forge ?"; then
    npm install -g @aion0/forge
  fi
fi

echo ""
c_green "──────────────────────────────────────────────────"
c_green " Forge dependencies ready."
c_green "──────────────────────────────────────────────────"
echo ""
echo "Next steps:"
echo "  1. Start Forge:        forge server start"
echo "  2. Open in browser:    http://localhost:8403"
echo "  3. Set admin password on first visit"
echo "  4. Settings → API Profiles → add your LLM key"
echo "  5. Marketplace → Sync → install connectors / pipelines"
echo ""
echo "Cloudflared (for tunnel) is auto-downloaded to ~/.forge/bin/ on first 'forge tcode' — no manual install."
echo "Browser-runner connectors (mantis / teams / pmdb / etc) need forge-browser-extension — see README."
