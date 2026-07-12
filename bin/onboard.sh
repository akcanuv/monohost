#!/bin/bash
# monohost onboard.sh — PRIVILEGED onboarding, run as root via a narrow NOPASSWD sudoers rule:
#     mh-deployer ALL=(root) NOPASSWD: /opt/monohost/bin/onboard.sh
#
#   sudo /opt/monohost/bin/onboard.sh <name> <repo_https_url> [branch]
#
# This script IS the trust boundary: it is root-owned + immutable to the deployer and validates
# every input. The unprivileged dashboard invokes it synchronously and streams this stdout/stderr
# back to the operator.
#
# Idempotent: re-running an existing app re-syncs + reloads (safe after a partial failure).
# Exit codes: 0 = onboarded & healthy · 1 = bad input / hard failure · 2 = onboarded but unhealthy.
#
# Any-runtime: the app's monohost.json declares only app-intrinsic info — `run` (the literal start
# command, with ${PORT} injected) and an optional `health` path. monohost assigns the name, branch,
# and loopback port (the manifest never carries those). onboard.sh writes a per-app run wrapper that
# deployd can SIGTERM to force a no-root KeepAlive respawn on new code.
#
# Hardening: macOS sudo does NOT scrub PATH the way we want, so we reset it and use absolute paths.

set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# absolute tool paths
GREP=/usr/bin/grep; AWK=/usr/bin/awk; PY=/usr/bin/python3; SUDO=/usr/bin/sudo
GIT=/usr/bin/git; LAUNCHCTL=/bin/launchctl; CHOWN=/usr/sbin/chown; CHMOD=/bin/chmod
TEE=/usr/bin/tee; CURL=/usr/bin/curl; SLEEP=/bin/sleep; SEQ=/usr/bin/seq
HEAD=/usr/bin/head; MV=/bin/mv; TOUCH=/usr/bin/touch; DATE=/bin/date; SCUTIL=/usr/sbin/scutil
UV=/opt/homebrew/bin/uv; CADDY=/opt/homebrew/bin/caddy

MH_ROOT=/opt/monohost
DEPLOYER=mh-deployer
ADMIN=mh-admin
REGISTRY="$MH_ROOT/registry/apps.tsv"
HELPER="$MH_ROOT/bin/gh-credential-helper.sh"
LOCK="$MH_ROOT/registry/.lock"

fail() { echo "ERROR: $*" >&2; exit 1; }

LIB="$MH_ROOT/bin/mh-lib.sh"
[ -f "$LIB" ] || fail "missing $LIB (re-run monohost update)"
# shellcheck disable=SC1090
. "$LIB"    # provides write_run_wrapper (absolute tool paths)

# ---- serialize control-plane mutations (port alloc + registry/config rewrites) --------------
# macOS has no flock(1); use an atomic mkdir lockdir with stale-holder reclamation. All four
# privileged scripts share this lock so concurrent onboard/offboard/expose/unexpose can't race
# the port allocator or clobber apps.tsv/exposures.tsv (lost-update).
acquire_lock() {
  [ -n "${MH_LOCK_HELD:-}" ] && return 0           # reentrant: a parent monohost script already holds it
  local tries=0 holder
  while ! mkdir "$LOCK" 2>/dev/null; do
    holder="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$LOCK" 2>/dev/null; continue          # holder is dead → reclaim
    fi
    tries=$((tries + 1)); [ "$tries" -gt 300 ] && fail "timed out waiting for $LOCK (held by ${holder:-?})"
    $SLEEP 0.1
  done
  echo "$$" > "$LOCK/pid"; export MH_LOCK_HELD=$$
  trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM
}

# best-effort LAN hostname for the user-facing success line (no specific name baked in).
lan_host() {
  local lhn; lhn="$($SCUTIL --get LocalHostName 2>/dev/null)"
  if [ -n "$lhn" ]; then echo "$lhn.local"; else hostname; fi
}

# ---- args + strict validation -----------------------------------------------
name="${1:-}"; repo="${2:-}"; branch="${3:-main}"
[ -n "$name" ] && [ -n "$repo" ] || fail "usage: onboard.sh <name> <repo_https_url> [branch]"
echo "$name"   | $GREP -Eq '^[a-z0-9][a-z0-9-]{0,30}$'           || fail "invalid name '$name' (^[a-z0-9][a-z0-9-]{0,30}$)"
echo "$branch" | $GREP -Eq '^[A-Za-z0-9._][A-Za-z0-9._/-]{0,99}$' || fail "invalid branch '$branch' (no leading dash)"
echo "$repo"   | $GREP -Eq '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || fail "invalid repo url '$repo'"
[ "$name" = "dashboard" ] && fail "'dashboard' is reserved"

# ---- optional env vars (from the dashboard) on STDIN as JSON -----------------
# The dashboard sends app secrets/config as a JSON array [{"name":..,"value":..}] on stdin —
# NEVER as argv, so secrets can't leak into `ps`/process listings. A terminal stdin (a human
# running this by hand) is skipped; pipe `</dev/null` for an explicit no-env manual run.
env_json='[]'
if [ ! -t 0 ]; then
  env_json="$(cat)"; [ -n "$env_json" ] || env_json='[]'
fi

acquire_lock

appdir="$MH_ROOT/apps/$name"
plist="/Library/LaunchDaemons/com.monohost.$name.plist"
fragment="$MH_ROOT/caddy/apps/$name.caddy"
wrapper="$appdir/.monohost-run.sh"
label="com.monohost.$name"
echo ">> onboarding '$name' from $repo ($branch)"

# ---- clone or update (as the deployer, via the credential helper) ------------
git_deployer() {
  $SUDO -H -u "$DEPLOYER" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \
    "$GIT" -c credential.helper= -c credential.helper="$HELPER" "$@"
}
if [ -d "$appdir/.git" ]; then
  echo ">> repo exists — fetching $branch"
  git_deployer -C "$appdir" fetch --depth 1 origin "$branch" || fail "fetch failed"
  git_deployer -C "$appdir" reset --hard FETCH_HEAD          || fail "reset failed"
else
  echo ">> cloning"
  git_deployer clone --depth 1 --branch "$branch" "$repo" "$appdir" || fail "clone failed"
fi

# ---- read + validate the manifest (app-intrinsic fields ONLY) ----------------
manifest="$appdir/monohost.json"
[ -f "$manifest" ] || fail "repo has no monohost.json"
jget() { $PY -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$manifest" "$1" 2>/dev/null; }
run="$(jget run)"; health="$(jget health)"; [ -n "$health" ] || health="/healthz"
[ -n "$run" ] || fail "monohost.json must set 'run' (the literal start command, e.g. \"uvicorn main:app --host 127.0.0.1 --port \${PORT}\")"
# server-assigned keys must not be honored from the manifest (they'd conflict with monohost).
for k in name branch port; do
  v="$(jget "$k")"; [ -n "$v" ] && echo ">> note: monohost.json '$k' is ignored (monohost assigns it)"
done
echo "$health" | $GREP -Eq '^/[A-Za-z0-9._~/-]*$' || fail "invalid health path '$health'"

# Optional 'dir' — a subfolder of the repo to build + run from (for monorepos / apps not at the root).
# Default is the repo root. Validated to stay inside the checkout (relative, no '..', no leading '/').
dir="$(jget dir)"
if [ -n "$dir" ]; then
  echo "$dir" | $GREP -Eq '^[A-Za-z0-9._][A-Za-z0-9._/-]*$' || fail "invalid dir '$dir' (relative path, no leading dash/slash)"
  case "$dir" in *..*) fail "dir '$dir' must not contain '..'" ;; esac
fi
rundir="$appdir"; [ -n "$dir" ] && rundir="$appdir/$dir"
[ -d "$rundir" ] || fail "monohost.json dir '$dir' is not a directory in the repo"
[ -n "$dir" ] && echo ">> run dir: $dir/"

# ---- allocate a loopback port (reuse if re-onboarding; else next free) -------
port=""
if [ -f "$fragment" ]; then
  port="$($GREP -oE 'reverse_proxy 127\.0\.0\.1:[0-9]+' "$fragment" | $GREP -oE '[0-9]+$' | $HEAD -1)"
fi
if [ -z "$port" ]; then
  used="$(printf '%s\n' 8010; $GREP -hoE 'reverse_proxy 127\.0\.0\.1:[0-9]+' "$MH_ROOT"/caddy/apps/*.caddy 2>/dev/null | $GREP -oE '[0-9]+$')"
  for p in $($SEQ 8011 8099); do
    printf '%s\n' "$used" | $GREP -qx "$p" || { port="$p"; break; }
  done
fi
[ -n "$port" ] || fail "no free port in 8011-8099"
echo ">> port $port"

# ---- build step (auto-detected from the run dir; no manifest field needed) ---
# Python: pyproject.toml/uv.lock → `uv sync` (locked, reproducible); else requirements.txt → a venv +
# `uv pip install -r`. Node: package.json → npm. Otherwise no build (binary / vendored deps). The
# venv always lands at <run dir>/.venv, which the run wrapper puts on PATH.
if [ -f "$rundir/pyproject.toml" ] || [ -f "$rundir/uv.lock" ]; then
  echo ">> build: uv sync (wheels only)"
  $SUDO -H -u "$DEPLOYER" "$UV" sync --no-build --project "$rundir" || fail "uv sync failed"
elif [ -f "$rundir/requirements.txt" ]; then
  echo ">> build: uv venv + pip install -r requirements.txt"
  [ -d "$rundir/.venv" ] || $SUDO -H -u "$DEPLOYER" "$UV" venv "$rundir/.venv" || fail "uv venv failed"
  $SUDO -H -u "$DEPLOYER" "$UV" pip install --python "$rundir/.venv/bin/python" -r "$rundir/requirements.txt" \
    || fail "pip install -r requirements.txt failed"
elif [ -f "$rundir/package.json" ]; then
  NPM=""; for c in /opt/homebrew/bin/npm /usr/local/bin/npm; do [ -x "$c" ] && { NPM="$c"; break; }; done
  [ -n "$NPM" ] || fail "package.json present but npm not found (install Node first)"
  # npm is a JS script (#!/usr/bin/env node); it shells out to `node` on PATH. Our scrubbed PATH
  # (line 22) lacks the Homebrew bin dir where node lives, so put node's dir (== npm's dir) on the
  # build's PATH via env — otherwise npm dies with "env: node: No such file or directory".
  NODEBIN="$(dirname "$NPM")"
  echo ">> build: npm ci"
  if [ -f "$rundir/package-lock.json" ]; then
    $SUDO -H -u "$DEPLOYER" /usr/bin/env "PATH=$NODEBIN:$PATH" "$NPM" --prefix "$rundir" ci || fail "npm ci failed"
  else
    $SUDO -H -u "$DEPLOYER" /usr/bin/env "PATH=$NODEBIN:$PATH" "$NPM" --prefix "$rundir" install || fail "npm install failed"
  fi
else
  echo ">> build: no pyproject/uv.lock/requirements.txt/package.json — skipping (binary or vendored deps)"
fi

# ---- app env file (.env.local): secrets/config from the dashboard form -------
# Written 0600, deployer-owned, in the app dir (untracked → survives redeploys). The run wrapper
# below auto-sources it (set -a) so the app reads os.environ as usual — no `bash -lc 'set -a; .'`
# boilerplate needed. Reserved keys (PORT/HOME/PATH) are refused so app config can't override what
# monohost assigns. An EMPTY submission leaves any existing .env.local untouched (a code-only
# redeploy keeps previously set secrets). All validation/quoting is done in python (shlex.quote).
envfile="$appdir/.env.local"
envcontent="$(MH_ENV_JSON="$env_json" $PY -c '
import json, os, re, shlex, sys
data = json.loads(os.environ.get("MH_ENV_JSON", "[]") or "[]")
if not isinstance(data, list):
    sys.exit("env payload must be a JSON array")
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
RESERVED = {"PORT", "HOME", "PATH"}
seen, out = set(), []
for item in data:
    if not isinstance(item, dict):
        sys.exit("each env item must be a {name,value} object")
    k = str(item.get("name", "")).strip()
    v = str(item.get("value", ""))
    if not k:
        continue
    if not NAME.match(k):
        sys.exit("invalid env var name: %r" % k)
    if k in RESERVED:
        sys.exit("env var %s is reserved by monohost" % k)
    if k in seen:
        sys.exit("duplicate env var: %s" % k)
    seen.add(k)
    out.append("%s=%s" % (k, shlex.quote(v)))
sys.stdout.write("".join(line + "\n" for line in out))
')" || fail "invalid environment variables (see message above)"

if [ -n "$envcontent" ]; then
  ( umask 077; printf '%s' "$envcontent" > "$envfile.tmp" ) || fail "could not write .env.local"
  $MV "$envfile.tmp" "$envfile"
  $CHOWN "$DEPLOYER":staff "$envfile"; $CHMOD 600 "$envfile"
  echo ">> wrote $(printf '%s' "$envcontent" | $GREP -c '=') env var(s) to .env.local (0600)"
elif [ -f "$envfile" ]; then
  echo ">> no env vars submitted — keeping existing .env.local"
fi

# ---- optional 'build' hook (e.g. a monorepo frontend) -----------------------
# Runs AFTER deps install and AFTER .env.local is written, in the run dir, as the deployer, with the
# venv + Homebrew on PATH and .env.local sourced (so build-time vars like VITE_* are available). The
# same hook runs on every redeploy (deployd build_app). A failure aborts the deploy.
build_hook="$(jget build)"
if [ -n "$build_hook" ]; then
  echo ">> build hook: $build_hook"
  $SUDO -H -u "$DEPLOYER" /usr/bin/env \
    "PATH=$rundir/.venv/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" \
    MH_RUNDIR="$rundir" MH_ENVFILE="$envfile" MH_BUILD="$build_hook" \
    /bin/bash -c 'cd "$MH_RUNDIR" || exit 1; set -a; [ -f "$MH_ENVFILE" ] && . "$MH_ENVFILE"; set +a; eval "$MH_BUILD"' \
    || fail "build hook failed: $build_hook"
fi

# ---- per-app run wrapper (deployer-owned). launchd runs THIS; deployd SIGTERMs it to redeploy.
# Shared template in mh-lib.sh: the app runs in its own process group and the TERM trap kills the
# whole tree (a direct-child kill orphans real servers behind npm/sh launchers, leaving the port
# bound so the respawn crash-loops). The literal `run` (incl. ${PORT}) is embedded verbatim.
write_run_wrapper "$wrapper" "$name" "$port" "$rundir" "$envfile" "$run" || fail "could not write run wrapper"
echo ">> run wrapper written ($wrapper)"

# ---- generate the app daemon plist (root); launchd runs the wrapper ----------
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>UserName</key><string>$DEPLOYER</string>
    <key>WorkingDirectory</key><string>$rundir</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$wrapper</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>/Users/$DEPLOYER</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>PORT</key><string>$port</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$MH_ROOT/logs/$name.out.log</string>
    <key>StandardErrorPath</key><string>$MH_ROOT/logs/$name.err.log</string>
</dict>
</plist>
PLIST
$CHOWN root:wheel "$plist"; $CHMOD 644 "$plist"
# `launchctl bootout` is ASYNCHRONOUS — it returns before the old job is torn down, so an immediate
# re-bootstrap races it and fails with "5: Input/output error", leaving the app with no daemon. On the
# re-onboard path (this branch only fires when already loaded) wait for the old job to disappear, then
# retry the bootstrap a few times (same hardening as setup.sh bootstrap_daemon).
if $LAUNCHCTL print "system/$label" >/dev/null 2>&1; then
  $LAUNCHCTL bootout "system/$label" 2>/dev/null || true
  for i in $($SEQ 1 20); do
    $LAUNCHCTL print "system/$label" >/dev/null 2>&1 || break
    $SLEEP 0.5
  done
fi
for i in 1 2 3 4 5; do
  $LAUNCHCTL bootstrap system "$plist" 2>/dev/null && break
  [ "$i" = 5 ] && fail "launchctl bootstrap failed"
  $SLEEP 1
done
echo ">> daemon $label loaded"

# ---- caddy route fragment (deployer-owned data plane) -----------------------
$SUDO -u "$DEPLOYER" $TEE "$fragment" >/dev/null <<FRAG
redir /$name /$name/ 308
handle_path /$name/* {
    reverse_proxy 127.0.0.1:$port
}
FRAG
echo ">> caddy fragment written"

# ---- register (admin-owned registry; idempotent) ----------------------------
# 4 columns: name <TAB> repo <TAB> branch <TAB> allocated_port. The port here is the
# authoritative running port (the dashboard reads it; deployd ignores the 4th column).
$TOUCH "$REGISTRY"
$AWK -F'\t' -v n="$name" '$1!=n' "$REGISTRY" > "$REGISTRY.tmp"
printf '%s\t%s\t%s\t%s\n' "$name" "$repo" "$branch" "$port" >> "$REGISTRY.tmp"
$MV "$REGISTRY.tmp" "$REGISTRY"
$CHOWN "$ADMIN":staff "$REGISTRY"; $CHMOD 644 "$REGISTRY"
echo ">> registered"

# ---- reload caddy gracefully (fallback: restart) ----------------------------
if $CADDY reload --config "$MH_ROOT/caddy/Caddyfile" --adapter caddyfile 2>/dev/null; then
  echo ">> caddy reloaded"
else
  $LAUNCHCTL kickstart -k system/com.monohost.caddy; echo ">> caddy restarted"
fi

# ---- activity event (surfaced in the dashboard "Recent activity") -----------
LOG="$MH_ROOT/logs/deployd.log"
[ -f "$LOG" ] || { $TOUCH "$LOG"; $CHOWN "$DEPLOYER":staff "$LOG"; }
echo "$($DATE '+%Y-%m-%dT%H:%M:%S') $name: onboarded -> :$port" >> "$LOG"

# ---- health gate ------------------------------------------------------------
$SLEEP 2
if $CURL -fsS "http://127.0.0.1:$port$health" >/dev/null 2>&1; then
  echo ">> OK: '$name' healthy on :$port — reachable at http://$(lan_host)/$name/"
  exit 0
fi
echo ">> WARN: '$name' onboarded but health check failed (see $MH_ROOT/logs/$name.err.log)"
exit 2
