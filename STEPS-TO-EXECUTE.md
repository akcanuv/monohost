# monohost — Operations Guide

> The entry doc is `README.md` and the full walkthrough is `how_to_monohost.md`. This is the
> day-to-day operator guide. `<mac>` below is your Mac's LAN name (`<name>.local`).

---

## Install

On a fresh macOS (Apple Silicon) Mac:

```bash
curl -fsSL https://monohost.org/install.sh | bash
```

You'll be asked for a LAN hostname, a GitHub deploy token (optional), and — optionally — a domain for
public exposure (with a one-time Cloudflare browser authorization). Everything else is automated.
When it finishes it prints the dashboard URL and a one-time **admin token** (needed to onboard/expose
from the dashboard — also stored at `/opt/monohost/secrets/dashboard.token`).

Non-interactive / scripted install:

```bash
MH_HOSTNAME=mybox MH_GITHUB_TOKEN=ghp_xxx MH_DOMAIN=example.com \
  bash -c "$(curl -fsSL https://monohost.org/install.sh)"
```

---

## Lifecycle

```bash
monohost status     # daemon states, registered apps, dashboard URL
monohost start      # start every monohost daemon (idempotent)
monohost stop       # stop them all (config + apps preserved)
monohost restart
monohost update     # fetch the latest monohost software and re-apply (your config is reused)
```

**Updates.** The control-plane scripts update via `monohost update` (deployd is non-root and can't
rewrite the root-owned trust boundary). The **dashboard** is bundled in the repo and run as a normal
app (`dir: dashboard`), so with auto-update on (`MH_SELF_UPDATE=1`, or chosen at install) it tracks the
monohost repo and redeploys itself on each release via deployd; off (default) it's pinned and refreshes
on `monohost update`. The setting is remembered, so `monohost update` preserves your choice.

**Daemons:** `com.monohost.caddy` (root, :80) · `com.monohost.deployd` (30 s poll) ·
`com.monohost.dashboard` (:8010) · `com.monohost.cloudflared` (only if exposure is configured) ·
one `com.monohost.<app>` per app (8011+).

---

## Day-to-day

**Add an app:** `http://<mac>/dashboard/` → **+ New app** → pick a repo, name it, Deploy.
(Headless: `sudo /opt/monohost/bin/onboard.sh <name> <repo-url> [branch]`.)

The repo needs a `monohost.json` carrying only app-intrinsic info — monohost assigns name/branch/port:

```json
{ "run": "uvicorn main:app --host 127.0.0.1 --port ${PORT}", "health": "/healthz" }
```

`run` is the literal start command (`${PORT}` injected; any runtime — uvicorn, gunicorn, Node, a
binary). Build is auto-detected from the repo: `pyproject.toml`/`uv.lock` → `uv sync`, `requirements.txt`
→ venv + `uv pip install -r`, `package.json` → `npm ci`, else none. For a monorepo / an app in a
subfolder, add an optional `"dir": "<subfolder>"` (the build + working dir; `monohost.json` stays at
the repo root). See the manifest examples in `README.md`.

**Update an app:** just `git push` to its branch → deployd redeploys within ~30 s.

**Remove an app:** the **offboard** button (or `sudo /opt/monohost/bin/offboard.sh <name>`).

**Expose an app publicly** (needs a configured domain): dashboard row → pick zone → **expose**.
- **dev** → `https://dev.<domain>/<name>/` (one shared host; the one-time `dev.<domain>` CNAME covers
  every dev app).
- **prod** → `https://<name>.<domain>/` (its own subdomain; the per-app CNAME is auto-created).
(Headless: `sudo /opt/monohost/bin/expose.sh <name> <dev|prod>`.)

**Unexpose:** the **unexpose** button (or `sudo /opt/monohost/bin/unexpose.sh <name>`).

**Logs:** `/opt/monohost/logs/<name>.{out,err}.log`, `…/deployd.log`, `…/caddy.{out,err}.log`,
`…/cloudflared.{out,err}.log`. Live tails are in the dashboard (click an app name).

---

## Multiple domains

Register any other Cloudflare-managed domain (already added to your Cloudflare account):

```bash
monohost domain add example.org     # prints a login URL — pick the example.org zone in the browser
monohost domain list
monohost domain remove example.org  # refused while apps are still exposed on it; DNS is never deleted
```

All domains share the one monohost tunnel. Each gets prod (`<app>.example.org`) and dev
(`dev.example.org/<app>/`) zones; pick the domain in the dashboard's expose dropdown, or headless:
`sudo -u mh-deployer sudo /opt/monohost/bin/expose.sh <app> prod example.org`.

> Upgrading an existing install: let `monohost update` run to completion — dev-zone routes can 404
> briefly mid-update (between the new scripts landing and the layout migration running).

---

## Adding public exposure later

If you installed LAN-only and want a domain afterwards:

```bash
sudo MH_DOMAIN=example.com bash /opt/monohost/.../setup.sh cloudflare
# or simply: MH_DOMAIN=example.com curl -fsSL https://monohost.org/install.sh | bash
```

You'll authorize Cloudflare in your browser once; the tunnel, `zones.env`, the dev CNAME, and the
daemon are all set up for you.

---

## Security posture

- The dashboard's mutating actions (onboard/offboard/expose/unexpose) require the **admin token** and
  only accept **LAN** requests — a stray public tunnel route can't drive the control plane.
- Apps run as the non-admin `mh-deployer`; only four root-owned, argument-validating scripts run as
  root, behind one narrow `NOPASSWD` sudo rule.
- Never add a wildcard/catch-all hostname to the Cloudflare tunnel ingress (the tooling never does).

---

## Repo layout (`monohost/`)

```
install.sh                    curl-served bootstrap (prereqs + prompts → setup.sh)
setup.sh                      idempotent phased installer
bin/  monohost                lifecycle CLI (start/stop/restart/status/update)
      gh-credential-helper.sh deployd.sh onboard.sh offboard.sh expose.sh unexpose.sh
caddy/Caddyfile               domain-agnostic master config (public host blocks generated at expose time)
cloudflare/zones.env.example  template (placeholders only; the live zones.env is generated)
etc/  sudoers.d-monohost      the narrow NOPASSWD rule (onboard, offboard, expose, unexpose)
dashboard/                    the bundled control-plane web UI (run from here via root monohost.json's dir)
monohost.json                 the dashboard app's manifest (run + health + dir: dashboard)
```

The dashboard is bundled in this repo (run from `dashboard/`); only the smoke example is a separate repo.
