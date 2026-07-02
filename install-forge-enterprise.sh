#!/usr/bin/env bash
#
# Forge Enterprise - one-command onboarding against a Foundry Hub.
#
# Instead of pasting an enterprise key by hand, a fresh forge enrolls with the
# Foundry Hub: you provide your identity + gitlab creds once, the Hub hands back
# an API key and the enterprise init config, and forge is configured against it.
#
# Usage (the Foundry console generates this line for you, with the token filled in):
#   curl -fsSL https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-forge-enterprise.sh | bash -s -- --token <ENROLL_TOKEN>
#
# Flags:
#   --token <t>              enrollment token (required first time; from the Foundry console)
#   --user-key <fk>          redeploy with an existing forge api key (zero prompts)
#   --foundry <url>          Foundry Hub base URL (default http://10.15.33.50:18503)
#   --backup-passphrase <s>  passphrase for encrypted backups (seeds auto-backup + used by --restore)
#   --restore                after config, restore the NEWEST Foundry backup (needs forge >= 0.13.0)
#   --restore-id <id>        restore a specific backup id (implies --restore)
#   --no-deps                only enroll + write config, don't install the forge CLI
#   -h, --help               this help
#
# You'll be prompted for: username, email (must be a fortinet.com address),
# gitlab PAT, gitlab name.
#
# Fresh-machine recovery example (restore everything from a Foundry backup):
#   curl -fsSL .../install-forge-enterprise.sh | bash -s -- \
#     --user-key <fk> --foundry <url> --restore --backup-passphrase <s>
#
# This file is intentionally ASCII-only: when `bash -s -- <args>` reads the
# script from a curl pipe, multi-byte UTF-8 can split across read buffers and
# break parsing.

set -euo pipefail

FOUNDRY_URL="http://10.15.33.50:18503"
ENROLL_TOKEN=""
USER_KEY=""
INSTALL_DEPS=1
RESTORE=0
RESTORE_ID=""
BACKUP_PASSPHRASE=""
LOCAL_INSTALLER="https://raw.githubusercontent.com/aiwatching/forge-public-info/main/install-forge-local.sh"

c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()   { printf '\033[33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
die()     { c_red "  x $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token)    ENROLL_TOKEN="${2:-}"; shift 2 ;;
    --user-key) USER_KEY="${2:-}"; shift 2 ;;
    --foundry)  FOUNDRY_URL="${2:-}"; shift 2 ;;
    --restore)  RESTORE=1; shift ;;                                  # restore newest backup after config
    --restore-id) RESTORE=1; RESTORE_ID="${2:-}"; shift 2 ;;         # restore a specific backup id
    --backup-passphrase) BACKUP_PASSPHRASE="${2:-}"; shift 2 ;;      # decrypts backups; also seeds auto-backup
    --no-deps)  INSTALL_DEPS=0; shift ;;
    -h|--help) sed -n '2,27p' "$0" 2>/dev/null || grep '^#' "$0" | head -27; exit 0 ;;
    *) die "Unknown flag: $1  (see --help)" ;;
  esac
done

# strip trailing slash
FOUNDRY_URL="${FOUNDRY_URL%/}"
[ -n "$ENROLL_TOKEN" ] || [ -n "$USER_KEY" ] || die "Missing --token (first enroll) or --user-key (redeploy). Copy a command from the Foundry console."

command -v curl >/dev/null 2>&1 || die "curl is required."

c_green "=================================================="
c_green " Forge Enterprise onboarding"
c_green "   Foundry Hub: $FOUNDRY_URL"
c_green "=================================================="

# --- collect identity -------------------------------------------------------
prompt() { # prompt VAR "label" [silent]
  local __var="$1" __label="$2" __silent="${3:-}" __val=""
  while [ -z "$__val" ]; do
    if [ -n "$__silent" ]; then printf '%s: ' "$__label" >&2; read -r -s __val < /dev/tty; printf '\n' >&2
    else printf '%s: ' "$__label" >&2; read -r __val < /dev/tty; fi
    [ -n "$__val" ] || c_ylw "  (required)" >&2
  done
  printf -v "$__var" '%s' "$__val"
}

optprompt() { # optprompt VAR "label" [silent] : blank allowed (no re-ask)
  local __var="$1" __label="$2" __silent="${3:-}" __val=""
  if [ -n "$__silent" ]; then printf '%s: ' "$__label" >&2; read -r -s __val < /dev/tty; printf '\n' >&2
  else printf '%s: ' "$__label" >&2; read -r __val < /dev/tty; fi
  printf -v "$__var" '%s' "$__val"
}

# --- JSON helpers (no jq/python dependency) ---------------------------------
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
json_get() { # json_get '<json>' <key>  -> first string value
  printf '%s' "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/\"$2\":\"(.*)\"/\1/"
}

if [ -n "$USER_KEY" ]; then
  # Zero-prompt redeploy: pull this identity's whole config by its own API key.
  c_green ""
  c_green "Fetching config from the Foundry Hub (user key)..."
  HTTP_BODY=$(mktemp)
  CODE=$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
    "$FOUNDRY_URL/enroll/config" -H "X-API-Key: $USER_KEY" || echo "000")
  RESP=$(cat "$HTTP_BODY"); rm -f "$HTTP_BODY"
  if [ "$CODE" != "200" ]; then
    c_red "  x config fetch failed (HTTP $CODE): $RESP"
    [ "$CODE" = "401" ] && c_ylw "     -> bad user key. Get a fresh one in Foundry (Forges -> Issue deploy key)."
    [ "$CODE" = "000" ] && c_ylw "     -> could not reach $FOUNDRY_URL. On the internal network?"
    exit 1
  fi
  # The deploy token is single-use; the Hub hands back a durable key in the
  # bundle for forge's ongoing calls. Fall back to the token for older Hubs.
  APIKEY=$(json_get "$RESP" apikey); [ -n "$APIKEY" ] || APIKEY="$USER_KEY"
else
  # First enroll: identity + gitlab, gated by the shared enroll token.
  USERNAME=""; EMAIL=""; GITLAB_PAT=""; GITLAB_NAME=""
  prompt USERNAME "Username"
  while :; do
    prompt EMAIL "Email (must be a fortinet.com address)"
    case "$EMAIL" in
      *@fortinet.com|*@*.fortinet.com) break ;;
      *) c_ylw "  Not a fortinet.com address, try again." ;;
    esac
  done
  # gitlab: blank on a re-enroll reuses what Foundry already stored for this user.
  optprompt GITLAB_NAME "GitLab name (blank = reuse Foundry's saved value)"
  optprompt GITLAB_PAT  "GitLab PAT (blank = reuse)" silent

  c_green ""
  c_green "Enroll as:  username=$USERNAME  email=$EMAIL  gitlab-name=${GITLAB_NAME:-<reuse saved>}"
  printf 'Continue? [y/N] ' >&2
  read -r _confirm < /dev/tty
  case "$_confirm" in [yY]*) ;; *) die "aborted - re-run to re-enter" ;; esac

  BODY=$(printf '{"username":"%s","email":"%s","gitlab_pat":"%s","gitlab_name":"%s"}' \
    "$(json_escape "$USERNAME")" "$(json_escape "$EMAIL")" \
    "$(json_escape "$GITLAB_PAT")" "$(json_escape "$GITLAB_NAME")")

  c_green ""
  c_green "Enrolling with the Foundry Hub..."
  HTTP_BODY=$(mktemp)
  CODE=$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
    -X POST "$FOUNDRY_URL/enroll/register" \
    -H "X-Enroll-Token: $ENROLL_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$BODY" || echo "000")
  RESP=$(cat "$HTTP_BODY"); rm -f "$HTTP_BODY"
  if [ "$CODE" != "200" ]; then
    c_red "  x enroll failed (HTTP $CODE): $RESP"
    case "$CODE" in
      401) c_ylw "     -> bad/expired token. Re-copy the command from the Foundry console." ;;
      400) c_ylw "     -> check the email is a fortinet.com address." ;;
      503) c_ylw "     -> the Hub has no enroll token set (admin: Settings -> Keys -> enroll_token)." ;;
      000) c_ylw "     -> could not reach $FOUNDRY_URL. On the internal network?" ;;
    esac
    exit 1
  fi
  APIKEY=$(json_get "$RESP" apikey)
  [ -n "$APIKEY" ] || die "enroll succeeded but no api key in response: $RESP"
fi

# --- parse the config bundle (same shape for both paths) --------------------
USERNAME=$(json_get "$RESP" username)
EMAIL=$(json_get "$RESP" email)
# enterprise_config is a multi-line config.env blob, JSON-escaped (\n, \"); decode it.
ENTERPRISE_CONFIG=$(json_get "$RESP" enterprise_config | awk '{ gsub(/\\n/,"\n"); gsub(/\\"/,"\""); print }')
ENTERPRISE_AGENT_KEY=$(json_get "$RESP" enterprise_agent_key)
TEMPER_URL=$(json_get "$RESP" temper_url)
TEMPER_KEY=$(json_get "$RESP" temper_key)
GITLAB_BASE_URL=$(json_get "$RESP" gitlab_base_url)
GITLAB_PAT=$(json_get "$RESP" gitlab_pat)
GITLAB_NAME=$(json_get "$RESP" gitlab_name)
# foundry_sync is a bool (not a quoted string) - grep it directly.
FOUNDRY_SYNC=$(printf '%s' "$RESP" | grep -oE '"foundry_sync":(true|false)' | head -1 | sed 's/.*://')
[ -n "$FOUNDRY_SYNC" ] || FOUNDRY_SYNC=false

# --- write forge enterprise config ------------------------------------------
FORGE_DIR="$HOME/.forge"
mkdir -p "$FORGE_DIR"
CFG="$FORGE_DIR/enterprise.json"
umask 077
cat > "$CFG" <<EOF
{
  "foundry_url": "$(json_escape "$FOUNDRY_URL")",
  "username": "$(json_escape "$USERNAME")",
  "email": "$(json_escape "$EMAIL")",
  "apikey": "$(json_escape "$APIKEY")",
  "gitlab_name": "$(json_escape "$GITLAB_NAME")",
  "gitlab_pat": "$(json_escape "$GITLAB_PAT")",
  "foundry_sync": $FOUNDRY_SYNC
}
EOF
chmod 600 "$CFG"
c_green "  + enrolled as $USERNAME ($EMAIL)"
c_green "  + wrote $CFG (foundry url + api key)"

# Provision the enterprise init config.env where the prelude skill's sync.sh
# reads it (its fallback location) -- no manual key paste.
if [ -n "$ENTERPRISE_CONFIG" ]; then
  mkdir -p "$FORGE_DIR/enterprise"
  printf '%s\n' "$ENTERPRISE_CONFIG" > "$FORGE_DIR/enterprise/config.env"
  chmod 600 "$FORGE_DIR/enterprise/config.env"
  c_green "  + wrote $FORGE_DIR/enterprise/config.env (init config from the Hub)"
else
  c_ylw "  ! Hub returned no enterprise config (admin: Foundry -> Settings -> Enterprise init config)"
fi

# --- install the forge CLI (must be before `forge onboard`) ------------------
if [ "$INSTALL_DEPS" = 1 ]; then
  c_green ""
  c_green "Installing the forge CLI..."
  curl -fsSL "$LOCAL_INSTALLER" | bash -s -- --yes
fi

# --- configure forge ---------------------------------------------------------
# Prefer `forge onboard` (>= 0.11.20): it runs the real wizard logic - enterprise
# key + connector sync + apply company/dept/connector template + identity +
# temper + gitlab + onboardingCompleted. Older forge has no such command, so
# fall back to writing forge's native files directly.
FORGE_BIN="$(command -v forge || true)"
[ -z "$FORGE_BIN" ] && [ -x "$(npm bin -g 2>/dev/null)/forge" ] && FORGE_BIN="$(npm bin -g 2>/dev/null)/forge"
FVER="$("$FORGE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
ONBOARD_MIN="0.11.20"
FOUNDRY_MIN="0.13.0"   # forge Enterprise Center (foundry connection + backup/restore)
has_onboard=0
has_foundry=0
if [ -n "$FORGE_BIN" ] && [ -n "$FVER" ]; then
  [ "$(printf '%s\n%s\n' "$ONBOARD_MIN" "$FVER" | sort -V | head -1)" = "$ONBOARD_MIN" ] && has_onboard=1
  [ "$(printf '%s\n%s\n' "$FOUNDRY_MIN" "$FVER" | sort -V | head -1)" = "$FOUNDRY_MIN" ] && has_foundry=1
fi

if [ "$has_onboard" = 1 ] && [ -n "$ENTERPRISE_AGENT_KEY" ]; then
  c_green ""
  c_green "Configuring forge (forge onboard)..."
  set -- onboard --non-interactive --name "$USERNAME" --email "$EMAIL" \
    --enterprise-key "$ENTERPRISE_AGENT_KEY" --yes
  [ -n "$GITLAB_PAT" ] && set -- "$@" --gitlab-token "$GITLAB_PAT"
  [ -n "$GITLAB_NAME" ] && set -- "$@" --gitlab-name "$GITLAB_NAME"
  [ -n "$GITLAB_BASE_URL" ] && set -- "$@" --gitlab-base-url "$GITLAB_BASE_URL"
  [ -n "$TEMPER_URL" ] && set -- "$@" --temper-url "$TEMPER_URL"
  [ -n "$TEMPER_KEY" ] && set -- "$@" --temper-key "$TEMPER_KEY"
  # Enterprise Center: connect this forge to Foundry so it can auto-back-up (>= 0.13.0).
  if [ "$has_foundry" = 1 ]; then
    set -- "$@" --foundry-url "$FOUNDRY_URL" --foundry-key "$APIKEY"
    [ -n "$BACKUP_PASSPHRASE" ] && set -- "$@" --foundry-backup-passphrase "$BACKUP_PASSPHRASE"
  fi
  if "$FORGE_BIN" "$@"; then
    c_green "  + forge onboarded (identity + enterprise template + temper + gitlab)"
    [ "$has_foundry" = 1 ] && c_green "  + connected to Foundry Enterprise Center (auto-backup on)"
  else
    c_red "  x forge onboard failed (exit $?) - finish in forge Settings"
  fi
else
  # Fallback: forge < 0.12.0 (no onboard). Write native files; merge into
  # settings.yaml (never clobber existing fields). No company/dept/connectors.
  [ "$has_onboard" = 0 ] && c_ylw "  ! forge ${FVER:-?} has no 'onboard' (need >= $ONBOARD_MIN) - writing config directly"
  mkdir -p "$FORGE_DIR/data"
  if [ -n "$ENTERPRISE_AGENT_KEY" ]; then
    printf '{\n  "v": 1,\n  "keys": ["%s"]\n}\n' "$(json_escape "$ENTERPRISE_AGENT_KEY")" > "$FORGE_DIR/data/.enterprise-keys.json"
    chmod 600 "$FORGE_DIR/data/.enterprise-keys.json"
    c_green "  + wrote .enterprise-keys.json"
  fi
  SETTINGS="$FORGE_DIR/data/settings.yaml"; touch "$SETTINGS"
  MEM_BACKEND="auto"; [ -n "$TEMPER_KEY" ] && MEM_BACKEND="temper"
  set_yaml() { # set_yaml <key> <value> : replace the top-level line or append
    awk -v k="$1" -v line="$1: $2" \
      '$0 ~ "^" k ":" { print line; found=1; next } { print } END { if(!found) print line }' \
      "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  }
  set_yaml displayName "\"$(json_escape "$USERNAME")\""
  set_yaml displayEmail "\"$(json_escape "$EMAIL")\""
  set_yaml temperUrl "\"$(json_escape "$TEMPER_URL")\""
  set_yaml temperKey "\"$(json_escape "$TEMPER_KEY")\""
  set_yaml memoryBackend "\"$MEM_BACKEND\""
  set_yaml onboardingCompleted "true"
  chmod 600 "$SETTINGS"
  c_green "  + merged identity + temper into settings.yaml (wizard skipped)"
fi

# --- restore from a Foundry backup (fresh-machine recovery) ------------------
if [ "$RESTORE" = 1 ]; then
  if [ "$has_foundry" != 1 ]; then
    c_ylw "  ! --restore needs forge >= $FOUNDRY_MIN (have ${FVER:-none}) - skipping restore"
  else
    c_green ""
    c_green "Restoring from Foundry backup..."
    set -- restore --from-foundry
    [ -n "$RESTORE_ID" ] && set -- "$@" --id "$RESTORE_ID"
    [ -n "$BACKUP_PASSPHRASE" ] && set -- "$@" --backup-passphrase "$BACKUP_PASSPHRASE"
    if "$FORGE_BIN" "$@"; then
      c_green "  + restored ${RESTORE_ID:-newest} backup"
    else
      c_red "  x restore failed (exit $?)"
      c_ylw "    list backups:  forge restore --from-foundry --list"
      c_ylw "    then:          forge restore --from-foundry --id <id> --backup-passphrase <s>"
    fi
  fi
fi

c_green ""
c_green "=================================================="
c_green " Forge Enterprise ready."
c_green "   config: $CFG"
c_green "   start:  forge server start"
c_green "=================================================="
