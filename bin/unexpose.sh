#!/bin/bash
# monohost unexpose.sh — remove an app's public exposure. Root via the NOPASSWD rule:
#     mh-deployer ALL=(root) NOPASSWD: /opt/monohost/bin/unexpose.sh
#   sudo /opt/monohost/bin/unexpose.sh <name>
#
# Root-owned + immutable; validates input; idempotent (safe to re-run). Exit 0 = unexposed.
# Removes the app's caddy block (dev path fragment or prod subdomain block) and its ingress row.
# When a domain's last dev app is removed, that domain's generated host block is dropped too.
# DNS is intentionally left in place: the shared per-domain dev CNAME stays for other dev apps, and a
# prod CNAME is harmless once ingress is gone (we never make destructive Cloudflare API calls).
# Hardening: reset PATH, absolute tool paths.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

GREP=/usr/bin/grep; AWK=/usr/bin/awk; LAUNCHCTL=/bin/launchctl; MKDIR=/bin/mkdir; SLEEP=/bin/sleep
CHOWN=/usr/sbin/chown; CHMOD=/bin/chmod; RM=/bin/rm; MV=/bin/mv; CMP=/usr/bin/cmp; TOUCH=/usr/bin/touch; DATE=/bin/date
CADDY=/opt/homebrew/bin/caddy

MH_ROOT=/opt/monohost
ADMIN=mh-admin
DEPLOYER=mh-deployer
EXPOSURES="$MH_ROOT/registry/exposures.tsv"
CF_DIR="$MH_ROOT/cloudflare"
ZONES_ENV="$CF_DIR/zones.env"
CONFIG="$CF_DIR/config.yml"
PUBLIC_DIR="$MH_ROOT/caddy/public"              # prod subdomain blocks
DEV_PUBLIC_DIR="$MH_ROOT/caddy/public-dev"      # dev path fragments
DEV_HOST_DIR="$MH_ROOT/caddy/public-dev-host"   # generated <DEV_BASE> host block
LOG="$MH_ROOT/logs/deployd.log"
LOCK="$MH_ROOT/registry/.lock"
LIB="$MH_ROOT/bin/mh-lib.sh"

fail() { echo "ERROR: $*" >&2; exit 1; }

acquire_lock() {
  [ -n "${MH_LOCK_HELD:-}" ] && return 0           # reentrant: offboard.sh holds it while calling us
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

[ -f "$LIB" ] || fail "missing $LIB (re-run monohost update)"
# shellcheck disable=SC1090
. "$LIB"    # provides regen_dev_hosts (uses absolute tool paths; needs BASE_DOMAIN/DEV_BASE set)

name="${1:-}"
[ -n "$name" ] || fail "usage: unexpose.sh <name>"
echo "$name" | $GREP -Eq '^[a-z0-9][a-z0-9-]{0,30}$' || fail "invalid name '$name'"

acquire_lock

echo ">> unexposing '$name'"
# drop the app's fragments wherever they are: prod block, legacy flat dev fragment, and any
# domain's dev dir. Host blocks are regenerated below once zones.env is loaded.
$RM -f "$PUBLIC_DIR/$name.caddy" "$DEV_PUBLIC_DIR/$name.caddy" "$DEV_PUBLIC_DIR"/*/"$name.caddy"

$TOUCH "$EXPOSURES"
$AWK -F'\t' -v n="$name" '$1!=n' "$EXPOSURES" > "$EXPOSURES.tmp"
$MV "$EXPOSURES.tmp" "$EXPOSURES"
$CHOWN "$ADMIN":staff "$EXPOSURES"; $CHMOD 644 "$EXPOSURES"

# regenerate config.yml from the remaining exposures (needs zones.env)
[ -f "$ZONES_ENV" ] || fail "missing $ZONES_ENV"
# shellcheck disable=SC1090
. "$ZONES_ENV"
[ -n "${BASE_DOMAIN:-}" ] && [ -n "${DEV_BASE:-}" ] && [ -n "${TUNNEL:-}" ] && [ -n "${CREDS_FILE:-}" ] \
  || fail "$ZONES_ENV must set BASE_DOMAIN, DEV_BASE, TUNNEL, CREDS_FILE"
case "$BASE_DOMAIN$DEV_BASE$TUNNEL$CREDS_FILE" in *REPLACE-*) fail "$ZONES_ENV still has placeholder values";; esac
BASE_DOMAIN="${BASE_DOMAIN%%$'\n'*}"; DEV_BASE="${DEV_BASE%%$'\n'*}"
TUNNEL="${TUNNEL%%$'\n'*}"; CREDS_FILE="${CREDS_FILE%%$'\n'*}"
# shared deterministic regen (mh-lib.sh); sets CONFIG_CHANGED=1 only if the ingress actually
# changed (removing one of several dev apps leaves the <dev_base> rule in place → config.yml
# unchanged → tunnel left alone, other apps stay up).
regen_cf_config
echo ">> config + caddy block removed"
regen_dev_hosts   # drop host blocks for domains with no dev apps left (and the legacy dev.caddy)

# reload caddy (always, graceful) + cloudflared (only if ingress changed). cloudflared has NO
# live reload in `tunnel run` mode (see restart_cloudflared in mh-lib.sh): a config change means
# a graceful SIGTERM restart — connections drain, launchd respawns on the new config (~10-40s).
rc=0
if $CADDY reload --config "$MH_ROOT/caddy/Caddyfile" --adapter caddyfile 2>/dev/null; then
  echo ">> caddy reloaded"
else
  $LAUNCHCTL kickstart -k system/com.monohost.caddy && echo ">> caddy restarted" \
    || { echo ">> WARN: caddy reload failed"; rc=2; }
fi
if [ "$CONFIG_CHANGED" = 1 ]; then
  if restart_cloudflared; then
    echo ">> cloudflared restarted to load the new ingress (public routes back in ~10-40s)"
  else
    echo ">> WARN: cloudflared restart failed — run 'monohost restart'"; rc=2
  fi
else
  echo ">> cloudflared ingress unchanged — tunnel left untouched (other apps stay up)"
fi

[ -f "$LOG" ] || { $TOUCH "$LOG"; $CHOWN "$DEPLOYER":staff "$LOG"; }
echo "$($DATE '+%Y-%m-%dT%H:%M:%S') $name: unexposed" >> "$LOG"
if [ "$rc" = 0 ]; then echo ">> OK: '$name' unexposed"; else echo ">> unexposed with reload warnings"; fi
exit $rc
