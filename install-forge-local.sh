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
    # Non-fatal: a failed optional install must not abort the whole script
    # (set -e) before Forge itself gets installed.
    if pkg_install "$pkg"; then
      c_green "  ✓ $display installed"
    else
      c_yellow "  ⚠ $display install failed — skipping (optional; install it manually later)"
    fi
  else
    c_yellow "  ⚠ Skipped $display — some Forge features won't work"
  fi
}

# ─── 1. Required ──────────────────────────────────────────────────────
log "Checking required dependencies…"

# Node 22.13+ (forge's undici uses markAsUncloneable, added in Node ~22.10;
# pnpm 10 also needs >= 22.13). Older Node installs but crashes at runtime.
NODE_MIN="22.13.0"
if have node; then
  NODE_VER="$(node -p 'process.versions.node')"
  if [ "$(printf '%s\n%s\n' "$NODE_MIN" "$NODE_VER" | sort -V | head -1)" = "$NODE_MIN" ]; then
    c_green "  ✓ node $(node -v) (≥ $NODE_MIN)"
  else
    c_red "  ✗ node $(node -v) — Forge needs ≥ $NODE_MIN (older crashes with 'markAsUncloneable is not a function')."
    echo "      nvm install 22 && nvm alias default 22 && nvm use 22"
    echo "      then re-run this installer so forge installs under the new Node."
    exit 1
  fi
else
  c_red "  ✗ node not installed. Install Node 22 first:"
  echo "      macOS:  brew install node          (or use nvm)"
  echo "      Linux:  use nvm — https://github.com/nvm-sh/nvm"
  echo "              then:  nvm install 22"
  exit 1
fi

# tmux
ensure_with_prompt tmux tmux "brew:tmux,apt:tmux,dnf:tmux,pacman:tmux,zypper:tmux"

# git
ensure_with_prompt git git "brew:git,apt:git,dnf:git,pacman:git,zypper:git"

# pnpm (via npm, not OS pkg). pnpm 10 needs Node >= 22.13; pin to 9 so it works
# on Node 20-22.x too.
if have pnpm && pnpm -v >/dev/null 2>&1; then
  c_green "  ✓ pnpm $(pnpm -v)"
elif have pnpm; then
  c_yellow "  ⚠ pnpm is installed but won't run — usually Node is too old (pnpm 10 needs Node >= 22.13)."
  c_yellow "     Fix with:  nvm install 22   (upgrade Node)   or   npm install -g pnpm@9"
else
  if confirm "Install pnpm via npm?"; then
    npm install -g pnpm@9 && c_green "  ✓ pnpm installed" || c_yellow "  ⚠ pnpm install failed — Forge build may fail"
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
  # glab is not in Debian/Ubuntu's default apt repos — omit apt so we print
  # "install manually" instead of a failing apt-get.
  ensure_with_prompt glab glab "brew:glab,dnf:glab,pacman:glab,zypper:glab"
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
