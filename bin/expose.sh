#!/bin/bash
# monohost expose.sh — PRIVILEGED public exposure via the Cloudflare tunnel. Root via:
#     mh-deployer ALL=(root) NOPASSWD: /opt/monohost/bin/expose.sh
#   sudo /opt/monohost/bin/expose.sh <name> <dev|prod>
#
# Mirrors onboard.sh: root-owned + immutable to the deployer, validates every input, idempotent.
# Exposes an already-onboarded app through the tunnel. Two zones (free *.<BASE_DOMAIN> TLS covers
# one level only, so dev is path-routed under a single host per domain):
#   - dev  -> https://<dev_base>/<name>/   (path fragment in caddy/public-dev/<domain>/<name>.caddy,
#            imported by that domain's generated host block caddy/public-dev-host/<dev_base>.caddy,
#            regenerated from zones.env + registry/domains.tsv; ONE one-time CNAME per domain covers
#            all its dev apps, no per-app DNS)
#   - prod -> https://<name>.<domain>/  (subdomain root block in caddy/public/<name>.caddy;
#            per-app CNAME via `tunnel route dns` if cert.pem present, else printed)
# It records the app in registry/exposures.tsv (source of truth), regenerates cloudflare/config.yml
# ingress deterministically from it, regenerates the dev host blocks from zones.env + domains.tsv, and
# reloads caddy + cloudflared. No literal domain is baked anywhere — everything comes from zones.env.
# Exit: 0 exposed · 1 bad input / hard fail · 2 exposed but a reload degraded.
#
# Hardening: macOS sudo does not scrub PATH the way we want, so we reset it and use absolute paths.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

GREP=/usr/bin/grep; AWK=/usr/bin/awk; HEAD=/usr/bin/head; SUDO=/usr/bin/sudo
LAUNCHCTL=/bin/launchctl; CHOWN=/usr/sbin/chown; CHMOD=/bin/chmod; MKDIR=/bin/mkdir
TEE=/usr/bin/tee; MV=/bin/mv; RM=/bin/rm; CMP=/usr/bin/cmp; TOUCH=/usr/bin/touch; DATE=/bin/date; SLEEP=/bin/sleep; TR=/usr/bin/tr
CADDY=/opt/homebrew/bin/caddy; CLOUDFLARED=/opt/homebrew/bin/cloudflared

MH_ROOT=/opt/monohost
ADMIN=mh-admin
DEPLOYER=mh-deployer
REGISTRY="$MH_ROOT/registry/apps.tsv"
EXPOSURES="$MH_ROOT/registry/exposures.tsv"
CF_DIR="$MH_ROOT/cloudflare"
ZONES_ENV="$CF_DIR/zones.env"
CONFIG="$CF_DIR/config.yml"
PUBLIC_DIR="$MH_ROOT/caddy/public"              # prod: one subdomain site block per app
DEV_PUBLIC_DIR="$MH_ROOT/caddy/public-dev"      # dev: one path fragment per app, under the dev host
DEV_HOST_DIR="$MH_ROOT/caddy/public-dev-host"   # dev: generated per-domain host blocks
LOG="$MH_ROOT/logs/deployd.log"
LOCK="$MH_ROOT/registry/.lock"
DOMAINS_TSV="$MH_ROOT/registry/domains.tsv"
CERTS_DIR="$CF_DIR/certs"

fail() { echo "ERROR: $*" >&2; exit 1; }

LIB="$MH_ROOT/bin/mh-lib.sh"
[ -f "$LIB" ] || fail "missing $LIB (re-run monohost update)"
# shellcheck disable=SC1090
. "$LIB"

# shared control-plane lock (see onboard.sh) — serializes config.yml / exposures.tsv rewrites.
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

# ---- args + strict validation -----------------------------------------------
name="${1:-}"; zone="${2:-}"; domain_arg="${3:-}"
[ -n "$name" ] && [ -n "$zone" ] || fail "usage: expose.sh <name> <dev|prod> [domain]"
echo "$name" | $GREP -Eq '^[a-z0-9][a-z0-9-]{0,30}$' || fail "invalid name '$name'"
[ "$name" = "dashboard" ] && fail "refusing to expose the dashboard (unauthenticated control plane)"
case "$zone" in dev|prod) : ;; *) fail "zone must be 'dev' or 'prod'" ;; esac
if [ -n "$domain_arg" ]; then
  domain_arg="$(echo "$domain_arg" | $TR '[:upper:]' '[:lower:]')"
  echo "$domain_arg" | $GREP -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
    || fail "invalid domain '$domain_arg'"
fi

acquire_lock

# app must be onboarded (in the registry) and have a recorded port
$AWK -F'\t' -v n="$name" '$1==n{f=1} END{exit !f}' "$REGISTRY" 2>/dev/null \
  || fail "app '$name' is not onboarded (not in registry)"
port="$($AWK -F'\t' -v n="$name" '$1==n{print $4}' "$REGISTRY" | $GREP -E '^[0-9]+$' | $HEAD -1)"
[ -n "$port" ] || fail "app '$name' has no recorded port (re-onboard it)"

# ---- zones config -----------------------------------------------------------
[ -f "$ZONES_ENV" ] || fail "missing $ZONES_ENV (run the monohost cloudflare setup first)"
# shellcheck disable=SC1090
. "$ZONES_ENV"   # BASE_DOMAIN, DEV_BASE, TUNNEL, CREDS_FILE
[ -n "${BASE_DOMAIN:-}" ] && [ -n "${DEV_BASE:-}" ] && [ -n "${TUNNEL:-}" ] && [ -n "${CREDS_FILE:-}" ] \
  || fail "$ZONES_ENV must set BASE_DOMAIN, DEV_BASE, TUNNEL, CREDS_FILE"
# refuse unconfigured placeholders so nothing is ever exposed under a stand-in domain/tunnel.
case "$BASE_DOMAIN$DEV_BASE$TUNNEL$CREDS_FILE" in *REPLACE-*) fail "$ZONES_ENV still has placeholder values — run the monohost cloudflare setup";; esac
# defense-in-depth: a single line each — never let a stray newline inject YAML/Caddy lines
BASE_DOMAIN="${BASE_DOMAIN%%$'\n'*}"; DEV_BASE="${DEV_BASE%%$'\n'*}"
TUNNEL="${TUNNEL%%$'\n'*}"; CREDS_FILE="${CREDS_FILE%%$'\n'*}"
# ---- resolve the target domain (default: the install domain) -----------------
# A non-default domain MUST be registered in domains.tsv — the deployer cannot route arbitrary
# hostnames through the trust boundary.
domain="${domain_arg:-$BASE_DOMAIN}"
if [ "$domain" = "$BASE_DOMAIN" ]; then
  dev_base="$DEV_BASE"                     # zones.env is authoritative for the install domain
else
  dev_base="$($AWK -F'\t' -v d="$domain" '$1!~/^#/ && $1==d {print $2; exit}' "$DOMAINS_TSV" 2>/dev/null)"
  $AWK -F'\t' -v d="$domain" '$1!~/^#/ && $1==d {f=1} END{exit !f}' "$DOMAINS_TSV" 2>/dev/null \
    || fail "domain '$domain' is not registered (run: monohost domain add $domain)"
fi
dev_base="${dev_base%%$'\n'*}"; [ -n "$dev_base" ] || dev_base="dev.$domain"
# the free Universal SSL cert covers <domain> + one wildcard level only, so dev_base must be a
# SINGLE label under the domain (e.g. dev.<domain>). Enforce it or dev TLS silently fails.
devlabel="${dev_base%.$domain}"
{ [ "$devlabel" = "$dev_base" ] || printf '%s' "$devlabel" | $GREP -q '\.'; } \
  && fail "dev base ($dev_base) must be a single label under $domain, e.g. dev.$domain"

# fqdn is the tunnel INGRESS host. dev apps share <dev_base> (path-routed to /<name>/);
# prod apps each get their own subdomain on the chosen domain. `route` is the user-facing URL.
if [ "$zone" = dev ]; then
  fqdn="$dev_base"; route="https://$dev_base/$name/"
else
  fqdn="$name.$domain"; route="https://$fqdn/"
fi
echo ">> exposing '$name' -> $route (port $port)"

# ---- upsert exposures.tsv (admin-owned source of truth) ---------------------
$TOUCH "$EXPOSURES"
$AWK -F'\t' -v n="$name" '$1!=n' "$EXPOSURES" > "$EXPOSURES.tmp"
printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$fqdn" "$zone" "$port" "$domain" >> "$EXPOSURES.tmp"
$MV "$EXPOSURES.tmp" "$EXPOSURES"
$CHOWN "$ADMIN":staff "$EXPOSURES"; $CHMOD 644 "$EXPOSURES"

# ---- caddy block (control-plane owned) --------------------------------------
# dev  -> a path fragment in public-dev/<domain>/, imported by that domain's generated host block.
# prod -> a standalone subdomain site block served at root.
ensure_dir() { [ -d "$1" ] || { $MKDIR -p "$1"; $CHOWN "$ADMIN":staff "$1"; $CHMOD 755 "$1"; }; }
ensure_dir "$PUBLIC_DIR"; ensure_dir "$DEV_PUBLIC_DIR"; ensure_dir "$DEV_HOST_DIR"
# hygiene: drop this app's fragments EVERYWHERE first (prod block, every domain's dev dir, and the
# legacy flat dev fragment) so switching zone or domain never leaves a stale route behind.
$RM -f "$PUBLIC_DIR/$name.caddy" "$DEV_PUBLIC_DIR/$name.caddy" "$DEV_PUBLIC_DIR"/*/"$name.caddy"
if [ "$zone" = dev ]; then
  ensure_dir "$DEV_PUBLIC_DIR/$domain"
  $TEE "$DEV_PUBLIC_DIR/$domain/$name.caddy" >/dev/null <<FRAG
redir /$name /$name/ 308
handle_path /$name/* {
    reverse_proxy 127.0.0.1:$port
}
FRAG
  $CHOWN "$ADMIN":staff "$DEV_PUBLIC_DIR/$domain/$name.caddy"; $CHMOD 644 "$DEV_PUBLIC_DIR/$domain/$name.caddy"
else
  $TEE "$PUBLIC_DIR/$name.caddy" >/dev/null <<FRAG
http://$fqdn {
    # The public subdomain uniquely identifies this app; serve it at root.
    # Apps exposed this way should use relative asset paths (like examples/monohost-smoke).
    reverse_proxy 127.0.0.1:$port
}
FRAG
  $CHOWN "$ADMIN":staff "$PUBLIC_DIR/$name.caddy"; $CHMOD 644 "$PUBLIC_DIR/$name.caddy"
fi
regen_dev_hosts   # rebuild all dev host blocks (drops empty ones and the legacy dev.caddy)
echo ">> caddy block written"

# ---- regenerate cloudflare ingress (shared, deterministic; sets CONFIG_CHANGED) --------------
regen_cf_config
echo ">> cloudflare config.yml regenerated"

# ---- DNS: prod = per-app CNAME; dev = none (one-time <dev_base> CNAME covers all dev apps) --
# The zone-scoped cert for the domain lives at certs/<domain>.pem (written by `monohost domain
# add`); the install domain may predate that layout, so fall back to the legacy canonical path.
if [ "$zone" = prod ]; then
  cert=""
  if $SUDO -u "$ADMIN" test -r "$CERTS_DIR/$domain.pem"; then
    cert="$CERTS_DIR/$domain.pem"
  elif [ "$domain" = "$BASE_DOMAIN" ] && $SUDO -u "$ADMIN" test -r "/Users/$ADMIN/.cloudflared/cert.pem"; then
    cert="/Users/$ADMIN/.cloudflared/cert.pem"
  fi
  if [ -x "$CLOUDFLARED" ] && [ -n "$cert" ]; then
    if $SUDO -H -u "$ADMIN" /usr/bin/env TUNNEL_ORIGIN_CERT="$cert" "$CLOUDFLARED" tunnel route dns "$TUNNEL" "$fqdn"; then
      echo ">> DNS: created CNAME $fqdn -> $TUNNEL.cfargotunnel.com"
    else
      echo ">> WARN: 'tunnel route dns' failed — add CNAME $fqdn -> $TUNNEL.cfargotunnel.com manually"
    fi
  else
    echo ">> ACTION REQUIRED: add DNS CNAME  $fqdn  ->  $TUNNEL.cfargotunnel.com  (no zone cert for $domain to automate)"
  fi
fi

# ---- reload caddy (always, graceful) + cloudflared (only if ingress changed) ----------------
# caddy reload is zero-downtime and always needed (the new route fragment / dev host). cloudflared
# has NO live reload in `tunnel run` mode (see restart_cloudflared in mh-lib.sh), so a config
# change means a graceful SIGTERM restart: existing public connections drain, launchd respawns
# the daemon on the new config, and routes reconnect in ~10-40s. Unchanged config = untouched.
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

# ---- activity event (surfaced in the dashboard "Recent activity") -----------
[ -f "$LOG" ] || { $TOUCH "$LOG"; $CHOWN "$DEPLOYER":staff "$LOG"; }
echo "$($DATE '+%Y-%m-%dT%H:%M:%S') $name: exposed -> $route" >> "$LOG"

if [ "$rc" = 0 ]; then echo ">> OK: '$name' exposed at $route"; else echo ">> exposed with reload warnings ($route)"; fi
exit $rc
