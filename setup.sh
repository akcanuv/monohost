#!/usr/bin/env bash
#
# monohost — single-host GitOps deploy system installer
# ----------------------------------------------------------------------------
# Target:   a FRESH macOS (Apple Silicon) Mac mini.
# Goal:     stand up the entire monohost system from nothing, declaratively, for ANY domain.
# Property: IDEMPOTENT — safe to re-run; every phase checks state before acting.
#
# Usage:
#   sudo bash setup.sh [phase]
#     phase = preflight | users | layout | runtime | gitops | routing | dashboard | cloudflare | all
#             (default: all)
#
# This is the phased installer. The curl-served bootstrap (install.sh) installs prerequisites,
# collects the few genuinely-required inputs, and runs this. Inputs arrive via the environment so
# `monohost update` can re-apply non-interactively:
#     MH_HOSTNAME       optional LAN hostname to set (-> <name>.local)
#     MH_GITHUB_TOKEN   GitHub deploy PAT (written to secrets/github.token)
#     MH_DOMAIN         Cloudflare-managed base domain (enables public exposure)
#     MH_NONINTERACTIVE 1 to never prompt / never open a browser (used by `monohost update`)
# Nothing in this file assumes a specific domain, GitHub account, hostname, or app repo.
# ----------------------------------------------------------------------------

set -euo pipefail

############################ configuration ###################################
ADMIN_USER="mh-admin";       ADMIN_UID=600;  ADMIN_FULLNAME="Monohost Admin"
DEPLOYER_USER="mh-deployer"; DEPLOYER_UID=601; DEPLOYER_FULLNAME="Monohost Deployer"

# Login shell during build. Hardened to /usr/bin/false at the lockdown phase (M8).
LOGIN_SHELL="/bin/zsh"

# Root-only record of generated service-account passwords (accounts never log in
# interactively; this is purely for the record / break-glass).
SECRETS_RECORD="/var/root/monohost-bootstrap-secrets.txt"

# Directory of this script (used to install bin/* into the control plane).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Canonical monohost SOFTWARE repo (overridable) — distinct from the user's own app repos. The
# dashboard is bundled in this repo (run from its dashboard/ subdir), so it is the dashboard's source
# too: with MH_SELF_UPDATE=1 the dashboard tracks this repo via the normal GitOps loop.
MONOHOST_REPO="${MONOHOST_REPO:-https://github.com/akcanuv/monohost}"
DASHBOARD_BRANCH="${MH_DASHBOARD_BRANCH:-main}"

############################ logging helpers #################################
c_reset=$'\033[0m'; c_blue=$'\033[34m'; c_green=$'\033[32m'
c_yellow=$'\033[33m'; c_red=$'\033[31m'
log()  { printf '%s[monohost]%s %s\n' "$c_blue"   "$c_reset" "$*"; }
ok()   { printf '%s   [ok]%s   %s\n'  "$c_green"  "$c_reset" "$*"; }
warn() { printf '%s [warn]%s   %s\n'  "$c_yellow" "$c_reset" "$*"; }
die()  { printf '%s [fail]%s   %s\n'  "$c_red"    "$c_reset" "$*" >&2; exit 1; }

############################ guards ##########################################
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root:  sudo bash $0 ${*:-all}"
}

# Optionally set the Mac's LAN hostname (so the dashboard is reachable at <name>.local). Idempotent;
# only acts when MH_HOSTNAME is provided. The dashboard derives the host at runtime, so nothing is
# hardcoded — this just renames the box if the operator asked.
configure_hostname() {
  local want="${MH_HOSTNAME:-}"
  [[ -n "$want" ]] || return 0
  [[ "$want" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "invalid hostname '$want' (^[A-Za-z0-9][A-Za-z0-9-]{0,62}$)"
  local cur; cur="$(scutil --get LocalHostName 2>/dev/null || true)"
  if [[ "$cur" == "$want" ]]; then ok "LAN hostname already '$want.local'"; return 0; fi
  scutil --set LocalHostName "$want"
  scutil --set ComputerName  "$want" 2>/dev/null || true
  scutil --set HostName      "$want.local" 2>/dev/null || true
  ok "LAN hostname set to '$want.local'"
}

phase_preflight() {
  log "Phase 0 — preflight"
  [[ "$(uname -s)" == "Darwin" ]] || die "this script targets macOS"
  configure_hostname              # macOS-only (scutil); must run AFTER the Darwin guard
  local arch ver
  arch="$(uname -m)"; ver="$(sw_vers -productVersion 2>/dev/null || echo '?')"
  [[ "$arch" == "arm64" ]] || warn "expected arm64 (Apple Silicon), got '$arch'"
  for tool in sysadminctl dscl dsmemberutil openssl scutil; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
  done
  log "macOS $ver on $arch — tooling present"
  ok  "preflight passed"
}

############################ phase 1: service accounts #######################

# create_service_user <name> <uid> <fullname>
create_service_user() {
  local name="$1" uid="$2" fullname="$3"

  if id "$name" >/dev/null 2>&1; then
    ok "user '$name' already exists (uid=$(id -u "$name")) — not modifying"
  else
    log "creating non-admin service account '$name' (uid=$uid)"
    local pw; pw="$(openssl rand -base64 24)"
    sysadminctl -addUser "$name" \
      -fullName "$fullname" \
      -UID "$uid" \
      -shell "$LOGIN_SHELL" \
      -home "/Users/$name" \
      -password "$pw" 2>&1 | sed 's/^/      /' \
      || die "sysadminctl -addUser failed for '$name'"

    ( umask 077; printf '%s\t%s\n' "$name" "$pw" >> "$SECRETS_RECORD" )
    chmod 600 "$SECRETS_RECORD"
    ok "created '$name'; generated password recorded in $SECRETS_RECORD"
  fi

  if [[ ! -d "/Users/$name" ]]; then
    createhomedir -c -u "$name" >/dev/null 2>&1 || die "createhomedir failed for '$name'"
    ok "materialised home /Users/$name"
  fi
  chmod 700 "/Users/$name"
  dscl . -create "/Users/$name" IsHidden 1
  ok "'$name' marked hidden, home private (700)"
}

verify_service_user() {
  local name="$1" want_uid="$2" uid home
  id "$name" >/dev/null 2>&1 || die "$name does not exist"
  uid="$(id -u "$name")"
  [[ "$uid" == "$want_uid" ]] || warn "$name uid=$uid (expected $want_uid)"
  if dsmemberutil checkmembership -U "$name" -G admin 2>/dev/null | grep -qi 'is not a member'; then
    home="$(dscl . -read "/Users/$name" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [[ -d "$home" ]] || warn "$name home '$home' missing"
    ok "$name verified: uid=$uid, non-admin, home=$home"
  else
    die "$name IS a member of 'admin' — must be non-admin. Aborting."
  fi
}

phase_users() {
  log "Phase 1 — service accounts"
  create_service_user "$ADMIN_USER"    "$ADMIN_UID"    "$ADMIN_FULLNAME"
  create_service_user "$DEPLOYER_USER" "$DEPLOYER_UID" "$DEPLOYER_FULLNAME"
  verify_service_user "$ADMIN_USER"    "$ADMIN_UID"
  verify_service_user "$DEPLOYER_USER" "$DEPLOYER_UID"
  ok "Phase 1 complete — both accounts exist, hidden, non-admin"
}

############################ phase 2: directory layout #######################
MH_ROOT="/opt/monohost"

phase_layout() {
  log "Phase 2 — directory layout & trust boundary ($MH_ROOT)"

  mkdir -p "$MH_ROOT"
  chown root:wheel "$MH_ROOT"; chmod 755 "$MH_ROOT"

  # Control plane — owned by mh-admin; read/exec but NOT writable by mh-deployer.
  mkdir -p "$MH_ROOT"/{bin,templates,keys,caddy,registry}
  mkdir -p "$MH_ROOT"/caddy/{public,public-dev,public-dev-host}     # admin-owned public route blocks
  chown "$ADMIN_USER":staff "$MH_ROOT"/{bin,templates,keys,caddy,registry}
  chown "$ADMIN_USER":staff "$MH_ROOT"/caddy/{public,public-dev,public-dev-host}
  chmod 755 "$MH_ROOT"/{bin,templates,caddy,registry}
  chmod 755 "$MH_ROOT"/caddy/{public,public-dev,public-dev-host}
  chmod 700 "$MH_ROOT/keys"          # age private key lives here — deployer cannot enter

  # Data plane — owned by mh-deployer; writable (incl. caddy/apps for rendered LAN fragments).
  mkdir -p "$MH_ROOT"/{apps,secrets,logs,caddy/apps}
  chown "$DEPLOYER_USER":staff "$MH_ROOT"/{apps,secrets,logs} "$MH_ROOT/caddy/apps"
  chmod 755 "$MH_ROOT"/{apps,logs} "$MH_ROOT/caddy/apps"
  chmod 700 "$MH_ROOT/secrets"       # deploy token + dashboard admin token live here

  ok "layout created"
  verify_layout
}

verify_layout() {
  if sudo -u "$DEPLOYER_USER" test -r "$MH_ROOT/keys"; then
    die "trust boundary BROKEN: $DEPLOYER_USER can read $MH_ROOT/keys"
  fi
  if sudo -u "$DEPLOYER_USER" sh -c "touch '$MH_ROOT/bin/.w' 2>/dev/null"; then
    rm -f "$MH_ROOT/bin/.w"
    die "trust boundary BROKEN: $DEPLOYER_USER can write $MH_ROOT/bin"
  fi
  if ! sudo -u "$DEPLOYER_USER" sh -c "touch '$MH_ROOT/apps/.w' 2>/dev/null"; then
    die "$DEPLOYER_USER cannot write $MH_ROOT/apps (expected writable)"
  fi
  rm -f "$MH_ROOT/apps/.w"
  ok "trust boundary verified (deployer: keys unreadable, bin read-only, apps writable)"
}

############################ phase 3: runtime tools ##########################
BREW="/opt/homebrew/bin/brew"
UV="/opt/homebrew/bin/uv"
CADDY_DIR="$MH_ROOT/caddy"
CLOUDFLARED="/opt/homebrew/bin/cloudflared"

brew_user() { echo "${SUDO_USER:-$(stat -f '%Su' /opt/homebrew 2>/dev/null || echo root)}"; }

runtime_install_tools() {
  local bu; bu="$(brew_user)"
  local f
  for f in caddy uv; do
    if [[ -x "/opt/homebrew/bin/$f" ]]; then
      ok "$f already installed"
    else
      log "installing $f via Homebrew (as $bu)"
      sudo -u "$bu" "$BREW" install "$f" || die "brew install $f failed"
    fi
  done
}

# (re)install + load a system LaunchDaemon (plist must already exist, root:wheel, not group-writable).
bootstrap_daemon() {
  local label="$1" plist="/Library/LaunchDaemons/$1.plist" i
  [[ -f "$plist" ]] || die "missing plist: $plist"
  chown root:wheel "$plist"; chmod 644 "$plist"
  if launchctl print "system/$label" >/dev/null 2>&1; then
    launchctl bootout "system/$label" 2>/dev/null || true
    for i in $(seq 1 20); do
      launchctl print "system/$label" >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
  for i in 1 2 3 4 5; do
    if launchctl bootstrap system "$plist" 2>/dev/null; then
      ok "daemon $label (re)bootstrapped"
      return 0
    fi
    sleep 1
  done
  die "launchctl bootstrap failed for $label"
}

phase_runtime() {
  log "Phase 3 — runtime tools (caddy, uv)"
  runtime_install_tools
}

############################ phase 4 (G1): LAN GitOps autodeploy ##############

gitops_install_scripts() {
  local s
  for s in gh-credential-helper.sh deployd.sh; do
    [ -f "$SCRIPT_DIR/bin/$s" ] || die "missing $SCRIPT_DIR/bin/$s (run setup.sh from the repo checkout)"
    install -o "$ADMIN_USER" -g staff -m 755 "$SCRIPT_DIR/bin/$s" "$MH_ROOT/bin/$s"
    ok "installed $MH_ROOT/bin/$s (mh-admin, 755)"
  done
  for s in onboard.sh offboard.sh expose.sh unexpose.sh; do
    [ -f "$SCRIPT_DIR/bin/$s" ] || die "missing $SCRIPT_DIR/bin/$s"
    install -o root -g wheel -m 755 "$SCRIPT_DIR/bin/$s" "$MH_ROOT/bin/$s"
    ok "installed $MH_ROOT/bin/$s (root, 755 — sudo target)"
  done
  # shared helper lib, SOURCED by expose/unexpose/setup as root — must be root-owned like the
  # sudo targets (mode 644: it is sourced, never executed).
  [ -f "$SCRIPT_DIR/bin/mh-lib.sh" ] || die "missing $SCRIPT_DIR/bin/mh-lib.sh"
  install -o root -g wheel -m 644 "$SCRIPT_DIR/bin/mh-lib.sh" "$MH_ROOT/bin/mh-lib.sh"
  ok "installed $MH_ROOT/bin/mh-lib.sh (root, 644 — sourced by the sudo targets)"
}

# Migrate existing app run wrappers to the process-group-kill template (idempotent). Wrappers are
# only written at onboard time, so apps onboarded before the fix keep the old direct-child-kill
# trap: a redeploy of an app whose `run` spawns a tree (npm → node) orphans the real server,
# leaving the port bound and the respawn crash-looping. Regenerates each wrapper from the app's
# own monohost.json + the PORT already baked into the old wrapper. Takes effect on the app's
# next respawn (deploy or restart) — running processes are not touched.
gitops_migrate_run_wrappers() {
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/bin/mh-lib.sh"
  local wrapper appdir name run dir rundir port
  for wrapper in "$MH_ROOT"/apps/*/.monohost-run.sh; do
    [ -f "$wrapper" ] || continue
    appdir="${wrapper%/.monohost-run.sh}"
    name="${appdir##*/}"
    [ "$name" = "dashboard" ] && continue          # phase_dashboard regenerates its own wrapper
    grep -q '^set -m$' "$wrapper" && continue      # already on the new template
    [ -f "$appdir/monohost.json" ] || { warn "wrapper migration: $name has no monohost.json — skipped"; continue; }
    run="$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('run',''))" "$appdir/monohost.json" 2>/dev/null)"
    [ -n "$run" ] || { warn "wrapper migration: $name has no run command — skipped"; continue; }
    dir="$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('dir',''))" "$appdir/monohost.json" 2>/dev/null)"
    case "$dir" in *..*|/*) dir="" ;; esac
    rundir="$appdir"; [ -n "$dir" ] && [ -d "$appdir/$dir" ] && rundir="$appdir/$dir"
    port="$(sed -n 's/^export PORT=\([0-9][0-9]*\)$/\1/p' "$wrapper" | head -1)"
    [ -n "$port" ] || { warn "wrapper migration: no PORT in $name's wrapper — skipped"; continue; }
    DEPLOYER="$DEPLOYER_USER" write_run_wrapper "$wrapper" "$name" "$port" "$rundir" "$appdir/.env.local" "$run" \
      || { warn "wrapper migration: could not rewrite $name's wrapper"; continue; }
    ok "migrated run wrapper for $name (process-group kill; applies on next respawn)"
  done
}

# Install the `monohost` lifecycle CLI onto PATH.
install_cli() {
  [ -f "$SCRIPT_DIR/bin/monohost" ] || die "missing $SCRIPT_DIR/bin/monohost"
  mkdir -p /usr/local/bin
  install -o root -g wheel -m 755 "$SCRIPT_DIR/bin/monohost" /usr/local/bin/monohost
  ok "installed /usr/local/bin/monohost"
}

gitops_install_sudoers() {
  local src="$SCRIPT_DIR/etc/sudoers.d-monohost"
  [ -f "$src" ] || die "missing $src"
  install -o root -g wheel -m 440 "$src" /etc/sudoers.d/monohost
  if ! visudo -cf /etc/sudoers.d/monohost >/dev/null 2>&1; then
    rm -f /etc/sudoers.d/monohost
    die "sudoers validation failed — removed /etc/sudoers.d/monohost"
  fi
  ok "installed /etc/sudoers.d/monohost (validated)"
}

# Write the GitHub deploy token from MH_GITHUB_TOKEN (the genuinely-required input). Private-repo
# clones and the dashboard repo picker need it; public repos work without it.
gitops_write_token() {
  local tf="$MH_ROOT/secrets/github.token"
  if [[ -n "${MH_GITHUB_TOKEN:-}" ]]; then
    ( umask 077; printf '%s' "$MH_GITHUB_TOKEN" > "$tf" )
    chown "$DEPLOYER_USER":staff "$tf"; chmod 600 "$tf"
    ok "wrote deploy token to $tf (600 $DEPLOYER_USER)"
  elif [[ -r "$tf" ]]; then
    ok "deploy token already present"
  else
    warn "no GitHub deploy token (MH_GITHUB_TOKEN unset). Private-repo deploys + the repo picker need it; add it later and re-run."
  fi
}

gitops_install_deployd_daemon() {
  cat > /Library/LaunchDaemons/com.monohost.deployd.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.monohost.deployd</string>
    <key>UserName</key><string>$DEPLOYER_USER</string>
    <key>ProgramArguments</key><array><string>$MH_ROOT/bin/deployd.sh</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>/Users/$DEPLOYER_USER</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>$MH_ROOT/logs/deployd.log</string>
    <key>StandardErrorPath</key><string>$MH_ROOT/logs/deployd.log</string>
</dict>
</plist>
EOF
  bootstrap_daemon com.monohost.deployd
}

phase_gitops() {
  log "Phase 4 (G1) — LAN GitOps autodeploy infra"
  gitops_install_scripts
  gitops_migrate_run_wrappers
  install_cli
  gitops_install_sudoers
  gitops_write_token
  gitops_install_deployd_daemon
}

############################ phase 5 (G2): LAN name routing ###################
# Caddy on :80 as ROOT path-routes <this-mac>.local/<name>. The master Caddyfile is DOMAIN-AGNOSTIC
# (no literal domain); public host blocks are generated at expose time from zones.env.

routing_install_caddyfile() {
  [ -f "$SCRIPT_DIR/caddy/Caddyfile" ] || die "missing $SCRIPT_DIR/caddy/Caddyfile (run from the repo)"
  install -o "$ADMIN_USER" -g staff -m 644 "$SCRIPT_DIR/caddy/Caddyfile" "$CADDY_DIR/Caddyfile"
  /opt/homebrew/bin/caddy validate --config "$CADDY_DIR/Caddyfile" --adapter caddyfile \
    || die "caddy config invalid"
  ok "installed + validated $CADDY_DIR/Caddyfile"
}

# Migrate pre-existing app route fragments to the trailing-slash-tolerant form (idempotent).
# onboard.sh/expose.sh now emit a `redir /<name> /<name>/ 308` line so bare /<name> redirects
# instead of falling through to the catch-all 404; fragments written before that fix lack it.
# Covers LAN fragments (caddy/apps), per-domain dev fragments (caddy/public-dev/<domain>/), and
# the legacy flat dev layout (caddy/public-dev/) on boxes that predate the multi-domain migration.
routing_migrate_fragment_redirects() {
  local f name
  for f in "$MH_ROOT"/caddy/apps/*.caddy "$MH_ROOT"/caddy/public-dev/*.caddy "$MH_ROOT"/caddy/public-dev/*/*.caddy; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .caddy)"
    grep -q "^redir /$name " "$f" 2>/dev/null && continue
    { printf 'redir /%s /%s/ 308\n' "$name" "$name"; cat "$f"; } > "$f.tmp"
    cat "$f.tmp" > "$f"   # truncate-in-place keeps the fragment's owner and mode
    rm -f "$f.tmp"
    ok "added trailing-slash redirect to ${f#"$MH_ROOT"/caddy/}"
  done
}

routing_install_caddy_daemon() {
  cat > /Library/LaunchDaemons/com.monohost.caddy.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.monohost.caddy</string>
    <!-- no UserName => runs as root, required to bind :80. Apps stay non-root. -->
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/caddy</string><string>run</string>
        <string>--config</string><string>$CADDY_DIR/Caddyfile</string>
        <string>--adapter</string><string>caddyfile</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>/var/root</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$MH_ROOT/logs/caddy.out.log</string>
    <key>StandardErrorPath</key><string>$MH_ROOT/logs/caddy.err.log</string>
</dict>
</plist>
EOF
  bootstrap_daemon com.monohost.caddy
}

phase_routing() {
  log "Phase 5 (G2) — LAN name routing (Caddy :80, path-based)"
  routing_migrate_fragment_redirects   # before install: the validate below covers migrated fragments
  routing_install_caddyfile
  routing_install_caddy_daemon
}

############################ phase 6 (G3): control-plane dashboard ############
# The dashboard is bundled in the monohost repo and served at /dashboard/. apps/dashboard is a
# checkout of the monohost repo; the app runs from its dashboard/ subdir (dir in the root
# monohost.json). It runs via the SAME run-wrapper mechanism as any app, so when MH_SELF_UPDATE=1 it
# can ride the normal GitOps loop (deployd fetch+build+SIGTERM-the-wrapper) and update itself on every
# push to the monohost repo. Off (default), it's pinned: deployd skips it and only `monohost update`
# (re-running setup) refreshes it. A per-install admin token gates its mutations.
DASHBOARD_PORT=8010

dashboard_admin_token() {
  local tf="$MH_ROOT/secrets/dashboard.token"
  if [[ ! -s "$tf" ]]; then
    ( umask 077; openssl rand -hex 24 > "$tf" )
    chown "$DEPLOYER_USER":staff "$tf"; chmod 600 "$tf"
    DASHBOARD_TOKEN_FRESH=1
  fi
}

phase_dashboard() {
  log "Phase 6 (G3) — control-plane dashboard (/dashboard/)"
  local appdir="$MH_ROOT/apps/dashboard" rundir="$MH_ROOT/apps/dashboard/dashboard"
  local wrapper="$appdir/.monohost-run.sh"

  git_dash() {
    sudo -H -u "$DEPLOYER_USER" env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \
      git -c credential.helper= -c credential.helper="$MH_ROOT/bin/gh-credential-helper.sh" "$@"
  }
  # Discard an existing checkout that points at a different repo (e.g. an old pre-bundle
  # monohost-dashboard checkout, or a changed MONOHOST_REPO) so we re-clone the right source.
  if [ -d "$appdir/.git" ]; then
    local cur_origin; cur_origin="$(git_dash -C "$appdir" config --get remote.origin.url 2>/dev/null || true)"
    if [ "$cur_origin" != "$MONOHOST_REPO" ]; then
      warn "dashboard checkout origin '$cur_origin' != $MONOHOST_REPO — re-cloning"
      rm -rf "$appdir"
    fi
  fi
  # apps/dashboard = a checkout of the monohost repo (so it can self-update like any app).
  if [ -d "$appdir/.git" ]; then
    if git_dash -C "$appdir" fetch --depth 1 origin "$DASHBOARD_BRANCH" 2>/dev/null \
       && git_dash -C "$appdir" reset --hard FETCH_HEAD 2>/dev/null; then
      ok "dashboard refreshed from $MONOHOST_REPO ($DASHBOARD_BRANCH)"
    else
      warn "dashboard refresh failed — keeping current checkout"
    fi
  elif git_dash clone --depth 1 --branch "$DASHBOARD_BRANCH" "$MONOHOST_REPO" "$appdir" 2>/dev/null; then
    ok "cloned the monohost repo for the dashboard ($MONOHOST_REPO $DASHBOARD_BRANCH)"
  elif [ -d "$SCRIPT_DIR/dashboard" ]; then
    warn "clone failed — installing the dashboard from the local checkout (pinned, no self-update)"
    install -d -o "$DEPLOYER_USER" -g staff "$appdir"
    rsync -a --exclude '.git' --exclude '.venv' --exclude '__pycache__' --exclude '.pytest_cache' \
      "$SCRIPT_DIR/." "$appdir/"
    chown -R "$DEPLOYER_USER":staff "$appdir"
  else
    die "could not obtain the dashboard (clone $MONOHOST_REPO failed and no local checkout)"
  fi

  [ -d "$rundir" ] || die "bundled dashboard not found at $rundir — is dashboard/ committed to the monohost repo?"

  sudo -H -u "$DEPLOYER_USER" "$UV" sync --no-build --project "$rundir" || die "dashboard uv sync failed"

  dashboard_admin_token

  # run wrapper (deployer-owned) — launchd runs THIS so deployd's self-update restart (pkill of this
  # exact path) works the same as for any app. Shared process-group-kill template from mh-lib.sh;
  # cd into the bundled dashboard/ subdir.
  local run
  run="$(/usr/bin/python3 -c "import json;print(json.load(open('$appdir/monohost.json')).get('run',''))" 2>/dev/null)"
  [ -n "$run" ] || run='uvicorn main:app --host 127.0.0.1 --port ${PORT}'
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/bin/mh-lib.sh"
  DEPLOYER="$DEPLOYER_USER" write_run_wrapper "$wrapper" "dashboard" "$DASHBOARD_PORT" "$rundir" "$appdir/.env.local" "$run" \
    || die "could not write the dashboard run wrapper"

  cat > /Library/LaunchDaemons/com.monohost.dashboard.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.monohost.dashboard</string>
    <key>UserName</key><string>$DEPLOYER_USER</string>
    <key>WorkingDirectory</key><string>$rundir</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$wrapper</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>/Users/$DEPLOYER_USER</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>PORT</key><string>$DASHBOARD_PORT</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$MH_ROOT/logs/dashboard.out.log</string>
    <key>StandardErrorPath</key><string>$MH_ROOT/logs/dashboard.err.log</string>
</dict>
</plist>
EOF
  bootstrap_daemon com.monohost.dashboard

  # register: self-update ON → track the monohost repo (deployd autodeploys it); OFF → pinned 'local'
  # (deployd skips). Default inherits the existing setting so `monohost update` preserves your choice.
  local self_update="${MH_SELF_UPDATE:-}"
  if [[ -z "$self_update" ]]; then
    if awk -F'\t' '$1=="dashboard" && $2!="local" && $2!=""{f=1} END{exit !f}' "$MH_ROOT/registry/apps.tsv" 2>/dev/null; then
      self_update=1; else self_update=0; fi
  fi
  touch "$MH_ROOT/registry/apps.tsv"
  awk -F'\t' '$1!="dashboard"' "$MH_ROOT/registry/apps.tsv" > "$MH_ROOT/registry/apps.tsv.tmp"
  if [[ "$self_update" == 1 ]]; then
    printf 'dashboard\t%s\t%s\t%s\n' "$MONOHOST_REPO" "$DASHBOARD_BRANCH" "$DASHBOARD_PORT" >> "$MH_ROOT/registry/apps.tsv.tmp"
    ok "self-update ON — dashboard tracks $MONOHOST_REPO ($DASHBOARD_BRANCH) via deployd"
  else
    printf 'dashboard\tlocal\tmain\t%s\n' "$DASHBOARD_PORT" >> "$MH_ROOT/registry/apps.tsv.tmp"
    ok "self-update off — dashboard pinned (refreshes on 'monohost update')"
  fi
  mv "$MH_ROOT/registry/apps.tsv.tmp" "$MH_ROOT/registry/apps.tsv"
  chown "$ADMIN_USER":staff "$MH_ROOT/registry/apps.tsv"; chmod 644 "$MH_ROOT/registry/apps.tsv"
  ok "dashboard on :$DASHBOARD_PORT, served at /dashboard/"
}

############################ phase 7 (G4): Cloudflare public exposure #########
# From-scratch (no migration): if a domain is configured (MH_DOMAIN, or an existing zones.env), this
# runs `cloudflared tunnel login` + `create`, writes zones.env + a minimal config.yml, adds the
# one-time dev CNAME, and starts the daemon. With no domain it's a no-op (LAN-only install).
CF_DIR="$MH_ROOT/cloudflare"

cloudflare_install_tool() {
  local bu; bu="$(brew_user)"
  if [[ -x "$CLOUDFLARED" ]]; then
    ok "cloudflared already installed"
  else
    log "installing cloudflared via Homebrew (as $bu)"
    sudo -u "$bu" "$BREW" install cloudflared || die "brew install cloudflared failed"
  fi
}

cloudflare_install_dirs() {
  install -d -o "$ADMIN_USER" -g staff -m 700 "$CF_DIR"
  for d in public public-dev public-dev-host; do
    install -d -o "$ADMIN_USER" -g staff -m 755 "$MH_ROOT/caddy/$d"
  done
  ok "cloudflare/ (700) + caddy/public{,-dev,-dev-host}/ (755) ready"
}

tunnel_uuid() { sudo -H -u "$ADMIN_USER" "$CLOUDFLARED" tunnel list 2>/dev/null | awk -v n="$1" '$2==n{print $1; exit}'; }

# Provision the tunnel from scratch and write zones.env + config.yml. Idempotent: skips login/create
# when creds already exist; preserves an existing zones.env unless a fresh domain was provided.
cloudflare_bootstrap_tunnel() {
  local domain; domain="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "invalid domain '$domain'"
  local certp="/Users/$ADMIN_USER/.cloudflared/cert.pem"
  local tname; tname="monohost-$(scutil --get LocalHostName 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
  [[ "$tname" == "monohost-" ]] && tname="monohost-$(hostname -s | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"

  # 0. tunnel identity: once zones.env is configured its TUNNEL is AUTHORITATIVE — every DNS
  #    CNAME ever created points at that tunnel. Re-resolving by NAME on an update can silently
  #    switch to (or, when `tunnel list` fails on a flaky network, CREATE) a different tunnel:
  #    the connector comes up fine but every exposed hostname still routes to the old tunnel,
  #    taking ALL public services down. Never re-resolve or create once zones.env is real.
  #    NOTE: TUNNEL may be a UUID or a tunnel NAME (older installs stored the name — cloudflared
  #    accepts both) — so trust zones.env's own CREDS_FILE first and only fall back to the
  #    <TUNNEL>.json convention when CREDS_FILE is absent or stale.
  local uuid="" creds=""
  if [[ -f "$CF_DIR/zones.env" ]] && ! grep -q 'REPLACE-' "$CF_DIR/zones.env" 2>/dev/null; then
    uuid="$( . "$CF_DIR/zones.env" 2>/dev/null; echo "${TUNNEL:-}" )"
    creds="$( . "$CF_DIR/zones.env" 2>/dev/null; echo "${CREDS_FILE:-}" )"
  fi
  if [[ -n "$uuid" ]]; then
    if [[ -n "$creds" && -f "$creds" ]]; then
      : # zones.env's recorded credentials file exists — nothing to recover
    elif [[ -f "$CF_DIR/$uuid.json" ]]; then
      creds="$CF_DIR/$uuid.json"
    elif [[ -f "/Users/$ADMIN_USER/.cloudflared/$uuid.json" ]]; then
      install -o "$ADMIN_USER" -g staff -m 600 "/Users/$ADMIN_USER/.cloudflared/$uuid.json" "$CF_DIR/$uuid.json"
      creds="$CF_DIR/$uuid.json"
      ok "restored tunnel credentials $uuid.json from ~$ADMIN_USER/.cloudflared"
    else
      die "zones.env names tunnel '$uuid' but no credentials JSON was found (checked zones.env CREDS_FILE${creds:+ at $creds}, $CF_DIR/$uuid.json, and ~$ADMIN_USER/.cloudflared/$uuid.json).
Restore the credentials file, or remove $CF_DIR/zones.env to re-provision a new tunnel (existing DNS CNAMEs will need updating)."
    fi
    ok "tunnel identity from zones.env: $uuid (authoritative — not re-resolved by name)"
  else
    # fresh/incomplete install — provision from scratch
    # 1. browser auth (only if we have no origin cert yet)
    if [[ ! -f "$certp" ]]; then
      if [[ "${MH_NONINTERACTIVE:-}" == 1 ]]; then
        warn "no Cloudflare cert and non-interactive — skipping tunnel bootstrap (public exposure not configured)"
        return 0
      fi
      log "Authorizing monohost with Cloudflare. A browser/URL will open — sign in and pick the zone for '$domain'."
      sudo -H -u "$ADMIN_USER" "$CLOUDFLARED" tunnel login || die "cloudflared tunnel login failed"
      [[ -f "$certp" ]] || die "tunnel login did not produce $certp"
    fi

    # 2. create the tunnel if it doesn't exist; resolve its UUID
    uuid="$(tunnel_uuid "$tname")"
    if [[ -z "$uuid" ]]; then
      log "creating tunnel '$tname'"
      sudo -H -u "$ADMIN_USER" "$CLOUDFLARED" tunnel create "$tname" || die "cloudflared tunnel create failed"
      uuid="$(tunnel_uuid "$tname")"
    fi
    [[ -n "$uuid" ]] || die "could not resolve tunnel UUID for '$tname'"

    # 3. place the credentials JSON in the control plane (600 mh-admin)
    local src="/Users/$ADMIN_USER/.cloudflared/$uuid.json"
    [[ -f "$src" ]] || die "tunnel credentials $src missing"
    install -o "$ADMIN_USER" -g staff -m 600 "$src" "$CF_DIR/$uuid.json"
    creds="$CF_DIR/$uuid.json"
  fi

  # 4. write zones.env (only on a fresh domain or when missing/placeholder — preserve operator edits)
  if [[ -n "${MH_DOMAIN:-}" ]] || [[ ! -f "$CF_DIR/zones.env" ]] || grep -q 'REPLACE-' "$CF_DIR/zones.env" 2>/dev/null; then
    cat > "$CF_DIR/zones.env" <<EOF
# monohost Cloudflare zone config — generated by setup.sh for $domain.
BASE_DOMAIN=$domain
DEV_BASE=dev.$domain
TUNNEL=$uuid
CREDS_FILE=$creds
EOF
    chown "$ADMIN_USER":staff "$CF_DIR/zones.env"; chmod 640 "$CF_DIR/zones.env"
    ok "wrote $CF_DIR/zones.env for $domain"
  fi

  # 5. one-time dev CNAME (covers every dev app; idempotent — tolerate "already exists")
  if sudo -H -u "$ADMIN_USER" "$CLOUDFLARED" tunnel route dns "$uuid" "dev.$domain" 2>/dev/null; then
    ok "dev CNAME dev.$domain -> $uuid.cfargotunnel.com"
  else
    warn "dev CNAME dev.$domain may already exist (continuing)"
  fi

  # 6. (re)generate config.yml deterministically from the authoritative identity + the CURRENT
  #    exposures — never a minimal rewrite that discards ingress rules (that took every exposed
  #    service offline until the next expose/unexpose happened to regenerate them). On a fresh
  #    install (no exposures.tsv) this yields the same minimal catch-all config as before.
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/bin/mh-lib.sh"
  ADMIN="$ADMIN_USER" TUNNEL="$uuid" CREDS_FILE="$creds" regen_cf_config
  ok "tunnel $uuid configured for $domain (config.yml regenerated from exposures)"
}

cloudflare_install_daemon() {
  if [[ ! -f "$CF_DIR/config.yml" ]]; then
    warn "no $CF_DIR/config.yml — cloudflared daemon not installed (public exposure not configured)."
    return 0
  fi
  cat > /Library/LaunchDaemons/com.monohost.cloudflared.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.monohost.cloudflared</string>
    <key>UserName</key><string>$ADMIN_USER</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/cloudflared</string><string>tunnel</string>
        <string>--config</string><string>$CF_DIR/config.yml</string>
        <string>run</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>/Users/$ADMIN_USER</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$MH_ROOT/logs/cloudflared.out.log</string>
    <key>StandardErrorPath</key><string>$MH_ROOT/logs/cloudflared.err.log</string>
</dict>
</plist>
EOF
  # cloudflared runs as mh-admin, but logs/ is deployer-owned. launchd opens stdio paths as the JOB's
  # user, so pre-create them owned by mh-admin (an owned file is writable even in a non-writable dir).
  touch "$MH_ROOT/logs/cloudflared.out.log" "$MH_ROOT/logs/cloudflared.err.log"
  chown "$ADMIN_USER":staff "$MH_ROOT/logs/cloudflared.out.log" "$MH_ROOT/logs/cloudflared.err.log"
  chmod 644 "$MH_ROOT/logs/cloudflared.out.log" "$MH_ROOT/logs/cloudflared.err.log"
  bootstrap_daemon com.monohost.cloudflared
}

# Migrate to / maintain the multi-domain layout (idempotent; see the 2026-07-09 spec).
#   1) cloudflare/certs/ + a copy of the install domain's zone cert (COPY, not move — the login
#      skip-check above still keys off the canonical ~mh-admin/.cloudflared/cert.pem path)
#   2) registry/domains.tsv seeded with the install domain as the FIRST row (the dashboard cannot
#      read zones.env, so row order is its default-domain marker)
#   3) flat public-dev/*.caddy fragments -> public-dev/<domain>/; dev host blocks regenerated
#      one per domain (drops the legacy single dev.caddy)
cloudflare_migrate_domains() {
  local domain="$1" certp="/Users/$ADMIN_USER/.cloudflared/cert.pem"
  local dev_base domains_tsv="$MH_ROOT/registry/domains.tsv"
  local devdir="$MH_ROOT/caddy/public-dev" f
  dev_base="$( . "$CF_DIR/zones.env" 2>/dev/null; echo "${DEV_BASE:-dev.$domain}" )"

  install -d -o "$ADMIN_USER" -g staff -m 700 "$CF_DIR/certs"
  if [[ -f "$certp" && ! -f "$CF_DIR/certs/$domain.pem" ]]; then
    install -o "$ADMIN_USER" -g staff -m 600 "$certp" "$CF_DIR/certs/$domain.pem"
    ok "seeded zone cert cloudflare/certs/$domain.pem"
  fi

  if ! awk -F'\t' -v d="$domain" '$1==d{f=1} END{exit !f}' "$domains_tsv" 2>/dev/null; then
    { printf '%s\t%s\n' "$domain" "$dev_base"; [[ -f "$domains_tsv" ]] && cat "$domains_tsv"; } > "$domains_tsv.tmp"
    mv "$domains_tsv.tmp" "$domains_tsv"
    ok "seeded registry/domains.tsv with $domain"
  fi
  chown "$ADMIN_USER":staff "$domains_tsv"; chmod 644 "$domains_tsv"

  if compgen -G "$devdir/*.caddy" >/dev/null 2>&1; then
    install -d -o "$ADMIN_USER" -g staff -m 755 "$devdir/$domain"
    for f in "$devdir"/*.caddy; do mv "$f" "$devdir/$domain/"; done
    chown -R "$ADMIN_USER":staff "$devdir/$domain"
    ok "moved flat dev fragments into public-dev/$domain/"
  fi

  # regenerate the per-domain dev host blocks via the shared helper (drops the legacy dev.caddy)
  # shellcheck disable=SC1090
  . "$SCRIPT_DIR/bin/mh-lib.sh"
  BASE_DOMAIN="$domain"
  DEV_BASE="$dev_base"
  regen_dev_hosts

  if /opt/homebrew/bin/caddy validate --config "$CADDY_DIR/Caddyfile" --adapter caddyfile >/dev/null 2>&1; then
    /opt/homebrew/bin/caddy reload --config "$CADDY_DIR/Caddyfile" --adapter caddyfile 2>/dev/null \
      || launchctl kickstart -k system/com.monohost.caddy 2>/dev/null || true
  else
    warn "caddy validate failed after domain migration — check $CADDY_DIR"
  fi
  ok "multi-domain layout ready"
}

phase_cloudflare() {
  log "Phase 7 (G4) — Cloudflare public exposure"
  cloudflare_install_tool
  cloudflare_install_dirs

  # resolve a domain: an explicit MH_DOMAIN, else an already-configured zones.env (update path).
  local domain="${MH_DOMAIN:-}"
  if [[ -z "$domain" && -f "$CF_DIR/zones.env" ]]; then
    domain="$( . "$CF_DIR/zones.env" 2>/dev/null; echo "${BASE_DOMAIN:-}" )"
    case "$domain" in ''|REPLACE-*) domain="" ;; esac
  fi
  if [[ -z "$domain" ]]; then
    warn "no domain configured — skipping public exposure (LAN-only). Re-run with MH_DOMAIN=<your-domain> to enable."
    return 0
  fi

  cloudflare_bootstrap_tunnel "$domain"
  cloudflare_install_daemon
  # migrate/maintain the multi-domain layout only once zones.env is real (spec §5) — a bailed
  # non-interactive bootstrap must not seed domains.tsv for an unprovisioned domain.
  if [[ -f "$CF_DIR/zones.env" ]] && ! grep -q 'REPLACE-' "$CF_DIR/zones.env" 2>/dev/null; then
    cloudflare_migrate_domains "$domain"
  else
    warn "zones.env not configured — skipping multi-domain migration"
  fi
}

############################ done banner ######################################
print_done() {
  local host token
  host="$(scutil --get LocalHostName 2>/dev/null).local"
  [[ "$host" == ".local" ]] && host="$(hostname)"
  echo
  log "monohost is up."
  printf '  dashboard   http://%s/dashboard/\n' "$host"
  if [[ -s "$MH_ROOT/secrets/dashboard.token" ]]; then
    token="$(cat "$MH_ROOT/secrets/dashboard.token")"
    if [[ "${DASHBOARD_TOKEN_FRESH:-}" == 1 ]]; then
      printf '  admin token %s\n' "$token"
      printf '              (needed to onboard/expose from the dashboard — saved at %s/secrets/dashboard.token)\n' "$MH_ROOT"
    fi
  fi
  if [[ -f "$CF_DIR/zones.env" ]] && ! grep -q 'REPLACE-' "$CF_DIR/zones.env" 2>/dev/null; then
    local bd; bd="$( . "$CF_DIR/zones.env" 2>/dev/null; echo "${BASE_DOMAIN:-}" )"
    [[ -n "$bd" ]] && printf '  public      %s (prod: <app>.%s · dev: dev.%s/<app>/)\n' "$bd" "$bd" "$bd"
  fi
  printf '  manage      monohost status | monohost stop | monohost update\n'
  echo
}

############################ entrypoint ######################################
main() {
  local phase="${1:-all}" envfile="${2:-}"
  require_root "$phase"
  # install.sh hands the collected inputs (MH_HOSTNAME / MH_DOMAIN / MH_GITHUB_TOKEN) in a 600 env
  # file rather than through sudo's environment — sudoers-independent, and keeps the token off argv.
  if [[ -n "$envfile" && -r "$envfile" ]]; then
    set -a; . "$envfile"; set +a
  fi
  case "$phase" in
    preflight)  phase_preflight ;;
    users)      phase_preflight; phase_users ;;
    layout)     phase_preflight; phase_users; phase_layout ;;
    runtime)    phase_preflight; phase_users; phase_layout; phase_runtime ;;
    gitops)     phase_preflight; phase_users; phase_layout; phase_runtime; phase_gitops ;;
    routing)    phase_preflight; phase_users; phase_layout; phase_runtime; phase_gitops; phase_routing ;;
    dashboard)  phase_preflight; phase_users; phase_layout; phase_runtime; phase_gitops; phase_routing; phase_dashboard ;;
    cloudflare) phase_preflight; phase_users; phase_layout; phase_runtime; phase_gitops; phase_routing; phase_dashboard; phase_cloudflare ;;
    all)        phase_preflight; phase_users; phase_layout; phase_runtime; phase_gitops; phase_routing; phase_dashboard; phase_cloudflare; print_done ;;
    *)          die "unknown phase '$phase' (use: preflight | users | layout | runtime | gitops | routing | dashboard | cloudflare | all)" ;;
  esac
  log "done."
}

main "$@"
