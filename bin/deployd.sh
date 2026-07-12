#!/bin/bash
# monohost deployd — poll registered apps and deploy new commits.
#
# Runs AS mh-deployer, invoked by launchd every StartInterval (no long-lived process).
# mh-admin-owned + mode 755 → the deployer can execute it but cannot modify it (the
# immutable apply boundary). No root anywhere: a code update SIGTERMs the app's own run wrapper
# and launchd KeepAlive respawns it on the new code.
#
# Registry: /opt/monohost/registry/apps.tsv — tab-separated:  name <TAB> repo_url <TAB> branch <TAB> port
# A repo of "local" (or empty) marks a locally-managed app (e.g. the control-plane dashboard) that
# deployd must NOT git-pull. Deploy state IS git: compare remote tip (ls-remote) to local HEAD.

set -uo pipefail   # NOT -e: one app's failure must not abort the others

ROOT=/opt/monohost
REGISTRY="$ROOT/registry/apps.tsv"
HELPER="$ROOT/bin/gh-credential-helper.sh"
UV=/opt/homebrew/bin/uv

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# All git ops: clear macOS osxkeychain from the helper chain (else -25308 + hang on a
# headless box), use only our token helper, never prompt.
git_d() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \
    git -c credential.helper= -c credential.helper="$HELPER" "$@"
}

# build an app in place, runtime auto-detected (mirrors onboard.sh). Honors the manifest's optional
# 'dir' (a repo subfolder to build from). Returns non-zero on failure.
build_app() {
  local appdir="$1" sub d rc bld
  sub="$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('dir',''))" "$appdir/monohost.json" 2>/dev/null)"
  case "$sub" in *..*|/*) sub="" ;; esac          # ignore an unsafe dir (onboard validated the real one)
  d="$appdir"; [ -n "$sub" ] && [ -d "$appdir/$sub" ] && d="$appdir/$sub"
  # 1) dependency install — runtime auto-detected from the run dir
  if [ -f "$d/pyproject.toml" ] || [ -f "$d/uv.lock" ]; then
    "$UV" sync --no-build --project "$d" 2>&1 | tail -2; rc=${PIPESTATUS[0]}
  elif [ -f "$d/requirements.txt" ]; then
    [ -d "$d/.venv" ] || "$UV" venv "$d/.venv" >/dev/null 2>&1 || { echo "uv venv failed"; return 1; }
    "$UV" pip install --python "$d/.venv/bin/python" -r "$d/requirements.txt" 2>&1 | tail -3; rc=${PIPESTATUS[0]}
  elif [ -f "$d/package.json" ]; then
    local npm=""; for c in /opt/homebrew/bin/npm /usr/local/bin/npm; do [ -x "$c" ] && { npm="$c"; break; }; done
    [ -n "$npm" ] || { echo "npm not found"; return 1; }
    if [ -f "$d/package-lock.json" ]; then "$npm" --prefix "$d" ci 2>&1 | tail -2; else "$npm" --prefix "$d" install 2>&1 | tail -2; fi
    rc=${PIPESTATUS[0]}
  else
    rc=0   # no recognized build manifest — nothing to install
  fi
  [ "$rc" -ne 0 ] && return "$rc"
  # 2) optional 'build' hook (e.g. a monorepo frontend: "cd ui && npm ci && npm run build"). Runs
  # after deps, in the run dir, with the venv + Homebrew on PATH and .env.local sourced (so build-time
  # vars like VITE_* are available). Failure fails the deploy → caller rolls back.
  bld="$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('build','') or '')" "$appdir/monohost.json" 2>/dev/null)"
  [ -n "$bld" ] || return 0
  echo "build hook: $bld"
  ( cd "$d" || exit 1
    set -a; [ -f "$appdir/.env.local" ] && . "$appdir/.env.local"; set +a
    export PATH="$d/.venv/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    eval "$bld" ) 2>&1 | tail -8
  return "${PIPESTATUS[0]}"
}

[ -r "$REGISTRY" ] || { echo "$(ts) deployd: no registry at $REGISTRY"; exit 0; }

checked=0; deployed=0

# Stream the registry via a single open FD. onboard/offboard rewrite it with an atomic `mv`, so the
# FD we opened here keeps reading the original inode to completion — a concurrent rewrite can't
# truncate our iteration mid-tick. (Plain `while read … done < file`; no bash-4 mapfile, since the
# app daemon's interpreter is macOS /bin/bash 3.2.)
while IFS=$'\t' read -r name repo branch _port _rest; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue ;; esac          # allow # comments
  case "${repo:-}" in ''|local) continue ;; esac  # locally-managed app (dashboard) — never git-pull
  branch="${branch:-main}"
  appdir="$ROOT/apps/$name"
  checked=$((checked + 1))

  if [ ! -d "$appdir/.git" ]; then
    echo "$(ts) $name: not onboarded (no $appdir/.git) — skip"
    continue
  fi

  remote_sha=$(git_d ls-remote "$repo" "refs/heads/$branch" 2>/dev/null | awk '{print $1}')
  [ -n "$remote_sha" ] || { echo "$(ts) $name: ls-remote failed"; continue; }
  local_sha=$(git_d -C "$appdir" rev-parse HEAD 2>/dev/null)

  [ "$remote_sha" = "$local_sha" ] && continue   # up to date — stay quiet

  echo "$(ts) $name: deploying ${local_sha:0:7} -> ${remote_sha:0:7}"
  git_d -C "$appdir" fetch --depth 1 origin "$branch" 2>&1 \
    || { echo "$(ts) $name: fetch FAILED — keeping current"; continue; }
  # reset to FETCH_HEAD (always set by the fetch; the origin/<branch> tracking ref is not
  # guaranteed to update on a --depth 1 fetch).
  git_d -C "$appdir" reset --hard FETCH_HEAD 2>&1 \
    || { echo "$(ts) $name: reset FAILED — keeping current"; continue; }
  # If the build fails, roll the tree back to the previous good SHA: 'keeping current' becomes true
  # (so a later KeepAlive respawn runs the OLD code, not the new-but-unbuilt tree) AND HEAD != remote
  # again, so the next tick retries instead of treating the broken build as deployed.
  build_app "$appdir" \
    || { echo "$(ts) $name: build FAILED — rolling back to ${local_sha:0:7}"
         [ -n "${local_sha:-}" ] && git_d -C "$appdir" reset --hard "$local_sha" 2>&1
         continue; }

  # restart: SIGTERM the app's own run wrapper (mh-deployer owns it); its trap tears down the app
  # child and launchd KeepAlive respawns the wrapper on the new code. The wrapper path is unique
  # per app, so this never touches another app or this daemon.
  pkill -f "$appdir/.monohost-run.sh" 2>/dev/null || true
  deployed=$((deployed + 1))
  echo "$(ts) $name: deployed ${remote_sha:0:7}"
done < "$REGISTRY"

echo "$(ts) deployd: tick — ${checked} app(s) checked, ${deployed} deployed"
