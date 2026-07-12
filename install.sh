#!/usr/bin/env bash
#
# monohost installer — the one-line bootstrap.
#
#   curl -fsSL https://monohost.org/install.sh | bash
#
# Runs as a normal admin user on a FRESH macOS (Apple Silicon) Mac mini. It installs prerequisites
# (Xcode CLT, Homebrew, git), collects only the inputs a script genuinely can't know (a LAN hostname,
# a GitHub deploy token, and — optionally — a domain for public exposure), clones the monohost
# software to a temp dir, and runs the phased installer under sudo. monohost is started by default.
#
# Non-interactive: set MH_HOSTNAME / MH_GITHUB_TOKEN / MH_DOMAIN in the environment to skip prompts.
# ----------------------------------------------------------------------------
set -euo pipefail

MONOHOST_REPO="${MONOHOST_REPO:-https://github.com/akcanuv/monohost}"

c_reset=$'\033[0m'; c_blue=$'\033[34m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_bold=$'\033[1m'
log()  { printf '%s[monohost]%s %s\n' "$c_blue"   "$c_reset" "$*"; }
ok()   { printf '%s   [ok]%s   %s\n'  "$c_green"  "$c_reset" "$*"; }
warn() { printf '%s [warn]%s   %s\n'  "$c_yellow" "$c_reset" "$*"; }
die()  { printf '%s [fail]%s   %s\n'  "$c_red"    "$c_reset" "$*" >&2; exit 1; }

# stdin is the curl pipe, so interactive reads must come from the controlling terminal.
TTY=""; [ -r /dev/tty ] && TTY=/dev/tty
ask()      { local p="$1" d="${2:-}" a; [ -n "$TTY" ] || { echo "$d"; return; }; printf '%s' "$p" >"$TTY"; read -r a <"$TTY" || a=""; echo "${a:-$d}"; }
ask_secret(){ local p="$1" a; [ -n "$TTY" ] || { echo ""; return; }; printf '%s' "$p" >"$TTY"; read -rs a <"$TTY" || a=""; printf '\n' >"$TTY"; echo "$a"; }
confirm()  { local p="$1" a; [ -n "$TTY" ] || return 1; printf '%s' "$p" >"$TTY"; read -r a <"$TTY" || a=""; case "$a" in [Yy]*) return 0;; *) return 1;; esac; }

# ---- preflight --------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "monohost targets macOS"
[ "$(id -u)" -ne 0 ] || die "run as a normal admin user (not root) — it will use sudo where needed"
[ "$(uname -m)" = "arm64" ] || warn "expected Apple Silicon (arm64), got '$(uname -m)' — continuing"

printf '\n%smonohost%s — single-host deploy plane installer\n\n' "$c_bold" "$c_reset"

# ---- prerequisites ----------------------------------------------------------
# Xcode Command Line Tools (provides git). Homebrew's installer also handles this, but trigger it
# explicitly so we have git to clone with.
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  log "installing Xcode Command Line Tools (a dialog may appear — accept it)…"
  /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  tries=0
  until /usr/bin/xcode-select -p >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 240 ] && die "Command Line Tools still not installed after ~20 min. On a headless/SSH Mac the install dialog can't be accepted remotely — run 'xcode-select --install' from a logged-in session (or install CLT manually), then re-run this installer."
    [ $((tries % 12)) -eq 0 ] && log "still waiting for Command Line Tools… (accept the dialog on the Mac's screen if shown)"
    sleep 5
  done
  ok "Command Line Tools present"
fi

if [ ! -x /opt/homebrew/bin/brew ]; then
  log "installing Homebrew (you'll be asked for your macOS password)…"
  if [ -n "$TTY" ]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" <"$TTY"
  else
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  [ -x /opt/homebrew/bin/brew ] || die "Homebrew install failed"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
ok "Homebrew present"

command -v git >/dev/null 2>&1 || die "git not found after Command Line Tools install"

# ---- collect the genuinely-required inputs ----------------------------------
printf '\n%sA few quick questions — everything else is automated.%s\n\n' "$c_bold" "$c_reset"

# 1) LAN hostname (the dashboard lives at <name>.local). Default: the Mac's current name.
cur_host="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
if [ -z "${MH_HOSTNAME:-}" ]; then
  want="$(ask "LAN hostname for monohost [$cur_host]: " "")"
  if [ -n "$want" ] && [ "$want" != "$cur_host" ]; then
    echo "$want" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$' || die "invalid hostname '$want'"
    MH_HOSTNAME="$want"
  fi
fi
export MH_HOSTNAME="${MH_HOSTNAME:-}"

# 2) GitHub deploy token (PAT). Validated against the API; skippable (public repos still deploy).
if [ -z "${MH_GITHUB_TOKEN:-}" ] && [ -n "$TTY" ]; then
  while :; do
    tok="$(ask_secret 'GitHub deploy token (fine-grained PAT, hidden — Enter to skip): ')"
    [ -z "$tok" ] && { warn "no token — the repo picker will be empty; private deploys won't work"; break; }
    login="$(curl -fsS -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
              https://api.github.com/user 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("login",""))' 2>/dev/null || true)"
    if [ -n "$login" ]; then
      ok "authenticated as $login"
      MH_GITHUB_TOKEN="$tok"; break
    fi
    warn "that token didn't authenticate (GitHub /user failed) — try again or press Enter to skip"
  done
fi
export MH_GITHUB_TOKEN="${MH_GITHUB_TOKEN:-}"

# 3) Public exposure (optional). Ask for one Cloudflare-managed domain.
if [ -z "${MH_DOMAIN:-}" ] && confirm 'Set up public exposure via Cloudflare now? [y/N]: '; then
  while :; do
    dom="$(ask 'Your Cloudflare-managed domain (e.g. example.com): ' '')"
    [ -z "$dom" ] && { warn "skipping public exposure"; break; }
    dom="$(echo "$dom" | tr '[:upper:]' '[:lower:]')"
    if echo "$dom" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
      MH_DOMAIN="$dom"; break
    fi
    warn "that doesn't look like a domain — try again or press Enter to skip"
  done
fi
export MH_DOMAIN="${MH_DOMAIN:-}"

# 4) Self-update (optional). When on, the dashboard tracks the monohost repo and redeploys itself via
#    the normal autodeploy loop on each release. Off (default): pinned; update with `monohost update`.
if [ -z "${MH_SELF_UPDATE:-}" ] && confirm 'Auto-update monohost (the dashboard tracks the monohost repo and redeploys on each release)? [y/N]: '; then
  MH_SELF_UPDATE=1
fi
export MH_SELF_UPDATE="${MH_SELF_UPDATE:-}"

# ---- fetch the software + run the phased installer --------------------------
tmp="$(mktemp -d /tmp/monohost.XXXXXX)" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
log "fetching monohost from $MONOHOST_REPO"
git clone --depth 1 "$MONOHOST_REPO" "$tmp/src" >/dev/null 2>&1 || die "git clone failed ($MONOHOST_REPO)"
[ -f "$tmp/src/setup.sh" ] || die "cloned repo has no setup.sh"

printf '\n'
log "running the installer (you may be asked for your password, and to authorize Cloudflare in a browser)"
# Hand the collected inputs to setup.sh in a 600 env-file argument: sudoers-independent (no reliance
# on sudo preserving env), and the token never lands on the process argv (ps-visible). The temp dir
# is removed on exit by the trap above.
envf="$tmp/install.env"
( umask 077
  printf 'MH_HOSTNAME=%s\n'     "$MH_HOSTNAME"
  printf 'MH_DOMAIN=%s\n'       "$MH_DOMAIN"
  printf 'MH_GITHUB_TOKEN=%s\n' "$MH_GITHUB_TOKEN"
  printf 'MH_SELF_UPDATE=%s\n'  "$MH_SELF_UPDATE"
) > "$envf"
if [ -n "$TTY" ]; then
  sudo bash "$tmp/src/setup.sh" all "$envf" <"$TTY"
else
  sudo bash "$tmp/src/setup.sh" all "$envf"
fi
