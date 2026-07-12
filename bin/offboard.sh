#!/bin/bash
# monohost offboard.sh — remove an app. Root via the narrow NOPASSWD sudoers rule:
#     mh-deployer ALL=(root) NOPASSWD: /opt/monohost/bin/offboard.sh
#
#   sudo /opt/monohost/bin/offboard.sh <name>
#
# Root-owned + immutable; validates input; idempotent (safe to re-run). Exit 0 = removed.
# Hardening: reset PATH, absolute tool paths (macOS sudo doesn't scrub env).

set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
GREP=/usr/bin/grep; AWK=/usr/bin/awk; LAUNCHCTL=/bin/launchctl; CHOWN=/usr/sbin/chown
CHMOD=/bin/chmod; RM=/bin/rm; MV=/bin/mv; MKDIR=/bin/mkdir; SLEEP=/bin/sleep; TOUCH=/usr/bin/touch; DATE=/bin/date
CADDY=/opt/homebrew/bin/caddy

MH_ROOT=/opt/monohost
ADMIN=mh-admin
DEPLOYER=mh-deployer
REGISTRY="$MH_ROOT/registry/apps.tsv"
LOCK="$MH_ROOT/registry/.lock"

fail() { echo "ERROR: $*" >&2; exit 1; }

# shared control-plane lock — held across the unexpose.sh call (which is reentrant via MH_LOCK_HELD).
acquire_lock() {
  [ -n "${MH_LOCK_HELD:-}" ] && return 0
  local tries=0 holder
  while ! $MKDIR "$LOCK" 2>/dev/null; do
    holder="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then $RM -rf "$LOCK" 2>/dev/null; continue; fi
    tries=$((tries + 1)); [ "$tries" -gt 300 ] && fail "timed out waiting for $LOCK (held by ${holder:-?})"
    $SLEEP 0.1
  done
  echo "$$" > "$LOCK/pid"; export MH_LOCK_HELD=$$
  trap '$RM -rf "$LOCK" 2>/dev/null' EXIT INT TERM
}

name="${1:-}"
[ -n "$name" ] || fail "usage: offboard.sh <name>"
echo "$name" | $GREP -Eq '^[a-z0-9][a-z0-9-]{0,30}$' || fail "invalid name '$name'"
[ "$name" = "dashboard" ] && fail "refusing to offboard the dashboard"

acquire_lock

# if the app is currently exposed publicly, tear that exposure down first (route + ingress)
if [ -f "$MH_ROOT/registry/exposures.tsv" ] && \
   $AWK -F'\t' -v n="$name" '$1==n{f=1} END{exit !f}' "$MH_ROOT/registry/exposures.tsv" 2>/dev/null; then
  echo ">> '$name' is exposed — unexposing first"
  "$MH_ROOT/bin/unexpose.sh" "$name" || echo ">> WARN: unexpose failed; continuing offboard"
fi

label="com.monohost.$name"
plist="/Library/LaunchDaemons/$label.plist"
fragment="$MH_ROOT/caddy/apps/$name.caddy"
appdir="$MH_ROOT/apps/$name"

echo ">> offboarding '$name'"
$LAUNCHCTL bootout "system/$label" 2>/dev/null || true
echo ">> daemon stopped"
$RM -f "$plist" "$fragment"
$RM -rf "$appdir"                       # also removes the per-app run wrapper
echo ">> files + route removed"

# de-register (admin-owned registry)
$TOUCH "$REGISTRY"
$AWK -F'\t' -v n="$name" '$1!=n' "$REGISTRY" > "$REGISTRY.tmp"
$MV "$REGISTRY.tmp" "$REGISTRY"
$CHOWN "$ADMIN":staff "$REGISTRY"; $CHMOD 644 "$REGISTRY"
echo ">> de-registered"

# reload caddy gracefully (fallback: restart)
if $CADDY reload --config "$MH_ROOT/caddy/Caddyfile" --adapter caddyfile 2>/dev/null; then
  echo ">> caddy reloaded"
else
  $LAUNCHCTL kickstart -k system/com.monohost.caddy; echo ">> caddy restarted"
fi

# activity event
LOG="$MH_ROOT/logs/deployd.log"
[ -f "$LOG" ] || { $TOUCH "$LOG"; $CHOWN "$DEPLOYER":staff "$LOG"; }
echo "$($DATE '+%Y-%m-%dT%H:%M:%S') $name: offboarded" >> "$LOG"

echo ">> OK: '$name' removed"
exit 0
