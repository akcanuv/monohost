#!/bin/bash
# monohost mh-lib.sh — shared helpers SOURCED (never executed) by the root-owned control-plane
# scripts (expose.sh, unexpose.sh) and by setup.sh. Installed root:wheel 644 at
# /opt/monohost/bin/mh-lib.sh: its code runs as root inside the sudo targets, so it must be
# exactly as immutable to mh-admin/mh-deployer as those scripts themselves.
#
# Uses literal absolute tool paths only (callers run with a scrubbed PATH).
# Contract: the caller sets BASE_DOMAIN and DEV_BASE (from zones.env) before calling
# regen_dev_hosts. MH_ROOT and ADMIN default to /opt/monohost and mh-admin.

# Deterministically (re)generate EVERY dev host block: one per domain whose public-dev/<domain>/
# dir has fragments; everything else in public-dev-host/ is removed (incl. the legacy single
# dev.caddy). Same philosophy as the cloudflared config regen — full regeneration, never
# incremental bookkeeping. Reads extra domains from registry/domains.tsv.
regen_dev_hosts() {
  local root="${MH_ROOT:-/opt/monohost}" admin="${ADMIN:-mh-admin}"
  local domains_tsv="$root/registry/domains.tsv"
  local dev_dir="$root/caddy/public-dev" host_dir="$root/caddy/public-dev-host"
  local d db
  [ -n "${BASE_DOMAIN:-}" ] && [ -n "${DEV_BASE:-}" ] \
    || { echo "regen_dev_hosts: BASE_DOMAIN/DEV_BASE unset (source zones.env first)" >&2; return 1; }
  [ -d "$host_dir" ] || { /bin/mkdir -p "$host_dir"; /usr/sbin/chown "$admin":staff "$host_dir"; /bin/chmod 755 "$host_dir"; }
  /bin/rm -f "$host_dir"/*.caddy
  {
    printf '%s\t%s\n' "$BASE_DOMAIN" "$DEV_BASE"
    [ -f "$domains_tsv" ] && /usr/bin/awk -F'\t' -v b="$BASE_DOMAIN" '$1!~/^#/ && $1!="" && $1!=b' "$domains_tsv"
  } | while IFS=$'\t' read -r d db; do
    [ -n "$d" ] || continue
    db="${db%%$'\n'*}"; [ -n "$db" ] || db="dev.$d"
    [ -n "$(/bin/ls -A "$dev_dir/$d" 2>/dev/null)" ] || continue
    /usr/bin/tee "$host_dir/$db.caddy" >/dev/null <<FRAG
http://$db {
    import $dev_dir/$d/*.caddy
    handle {
        respond "monohost dev — no app at this path" 404
    }
}
FRAG
    /usr/sbin/chown "$admin":staff "$host_dir/$db.caddy"; /bin/chmod 644 "$host_dir/$db.caddy"
  done
  # load-bearing: under callers' pipefail/set -e the pipeline above reports 1 when domains.tsv
  # is absent (a normal pre-migration state) even though every write succeeded. Do not remove.
  return 0
}

# Deterministically (re)generate cloudflare/config.yml: tunnel identity from zones.env (caller
# sets TUNNEL and CREDS_FILE) + one ingress rule per DISTINCT exposed hostname (exposures.tsv
# col 2; all dev apps share their domain's <dev_base> host so they collapse to one rule), then
# the catch-all. NEVER write config.yml any other way — a partial/minimal rewrite that drops
# ingress rules takes every exposed service offline until the next regen (historical bug).
# Sets CONFIG_CHANGED=1 only if the file actually differs, so callers can leave the tunnel
# alone when nothing changed. Atomic tmp+mv; 600 admin-owned (it names the credentials file).
regen_cf_config() {
  local root="${MH_ROOT:-/opt/monohost}" admin="${ADMIN:-mh-admin}"
  local exposures="$root/registry/exposures.tsv" config="$root/cloudflare/config.yml"
  [ -n "${TUNNEL:-}" ] && [ -n "${CREDS_FILE:-}" ] \
    || { echo "regen_cf_config: TUNNEL/CREDS_FILE unset (source zones.env first)" >&2; return 1; }
  CONFIG_CHANGED=0
  {
    printf 'tunnel: %s\n' "$TUNNEL"
    printf 'credentials-file: %s\n' "$CREDS_FILE"
    printf 'ingress:\n'
    if [ -f "$exposures" ]; then
      /usr/bin/awk -F'\t' 'NF>=2 && $1!~/^#/ && !seen[$2]++ {printf "  - hostname: %s\n    service: http://127.0.0.1:80\n", $2}' "$exposures"
    fi
    printf '  - service: http_status:404\n'
  } > "$config.tmp"
  if [ -f "$config" ] && /usr/bin/cmp -s "$config.tmp" "$config"; then
    /bin/rm -f "$config.tmp"
  else
    CONFIG_CHANGED=1
    /bin/mv "$config.tmp" "$config"
    /usr/sbin/chown "$admin":staff "$config"; /bin/chmod 600 "$config"
  fi
  return 0
}

# Restart cloudflared so it loads a changed config.yml. There is NO live reload in `tunnel run`
# mode: cloudflared reads config only at startup, handles only SIGTERM/SIGINT (SIGHUP is
# UNHANDLED and kills the process without draining), and its config-file watcher exists only in
# the flagless service mode monohost doesn't use. SIGTERM drains connections gracefully and
# launchd KeepAlive respawns the daemon on the new config; public routes reconnect in ~10-40s.
restart_cloudflared() {
  /bin/launchctl kill SIGTERM system/com.monohost.cloudflared 2>/dev/null \
    || /bin/launchctl kickstart -k system/com.monohost.cloudflared
}

# Write an app's launchd run wrapper (used by onboard.sh, setup.sh's dashboard phase, and the
# wrapper migration). deployd SIGTERMs the wrapper (matched by its unique path) to redeploy.
#   write_run_wrapper <path> <name> <port> <rundir> <envfile> <run-command>
# The app is spawned in its OWN process group (set -m) and the trap kills that whole group:
# killing only the direct child orphans real servers behind npm/sh launchers, leaving the port
# bound so the launchd respawn crash-loops. The trap is installed BEFORE the spawn so a
# deploy-time SIGTERM can never hit the gap and orphan a just-spawned child.
write_run_wrapper() {
  local wrapper="$1" name="$2" port="$3" rundir="$4" envfile="$5" run="$6"
  local deployer="${DEPLOYER:-mh-deployer}"
  {
    printf '#!/bin/sh\n'
    printf '# monohost run wrapper for %s — regenerated on every deploy. Do not edit.\n' "$name"
    printf '# deployd SIGTERMs this wrapper (matched by its path) to force a launchd KeepAlive respawn.\n'
    printf 'set -a; [ -f "%s" ] && . "%s"; set +a\n' "$envfile" "$envfile"
    printf 'export PORT=%s\n' "$port"
    printf 'for d in "%s/.venv/bin" "%s/node_modules/.bin"; do [ -d "$d" ] && PATH="$d:$PATH"; done\n' "$rundir" "$rundir"
    printf 'export PATH\n'
    printf 'cd "%s" || exit 1\n' "$rundir"
    printf 'set -m\n'
    printf '# TERM the whole process group, grant 10s to shut down, then KILL the group. Bounded:\n'
    printf '# a child that ignores TERM must never hang the wrapper (launchd would think the job\n'
    printf '# is still up and the redeploy respawn would never happen).\n'
    printf 'term_tree() {\n'
    printf '    kill -TERM -"$app_pid" 2>/dev/null\n'
    printf '    n=0\n'
    printf '    while kill -0 -"$app_pid" 2>/dev/null && [ "$n" -lt 100 ]; do /bin/sleep 0.1; n=$((n+1)); done\n'
    printf '    kill -KILL -"$app_pid" 2>/dev/null\n'
    printf '    exit 0\n'
    printf '}\n'
    printf 'trap term_tree TERM INT\n'
    printf '%s &\n' "$run"
    printf 'app_pid=$!\n'
    printf 'wait "$app_pid"\n'
  } > "$wrapper.tmp" || return 1
  /bin/mv "$wrapper.tmp" "$wrapper" || return 1
  /usr/sbin/chown "$deployer":staff "$wrapper"; /bin/chmod 755 "$wrapper"
}
