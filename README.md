# monohost

A single-host, git-driven deploy plane for a Mac mini. No Docker, no VM, no SSH deploys — push to
GitHub and your app is live on your own hardware. Apps run as native launchd services behind Caddy,
public exposure rides a Cloudflare tunnel, and **server state is a pure function of git**.

## Install

On a fresh macOS (Apple Silicon) Mac:

```bash
curl -fsSL https://monohost.org/install.sh | bash
```

The installer sets everything up and only asks for what it genuinely can't know:

- a **LAN hostname** (the dashboard lives at `http://<name>.local/dashboard/` — default: your Mac's name),
- a **GitHub deploy token** (a fine-grained PAT — used to list and clone your repos; optional, public repos work without it),
- optionally, a **domain** for public exposure (you authorize Cloudflare once in your browser; the tunnel is created for you),
- optionally, **auto-update** (the dashboard then tracks the monohost repo and redeploys itself on each release).

Everything else — service accounts, the trust boundary, Homebrew + runtimes, Caddy, the autodeploy
daemon, the dashboard, the tunnel, DNS — is automated. When it finishes you get a dashboard URL and a
one-time admin token.

## Manage

```bash
monohost status     # daemons, apps, dashboard URL
monohost stop       # stop everything (apps + config preserved)
monohost start      # start everything
monohost update     # fetch the latest monohost and re-apply (your config is reused)
monohost domain add example.org    # register another Cloudflare domain for exposure
monohost domain list               # domains, their dev hosts, and exposure counts
monohost domain remove example.org # deregister (refused while apps are exposed on it)
```

### Updates

monohost's **control-plane scripts** update when you run `monohost update` (it re-clones the repo and
re-applies the installer; your domain/token/tunnel config is reused). This is always how the privileged
scripts update — deployd is deliberately non-root and can't rewrite the root-owned trust boundary.

The **dashboard** is bundled in the monohost repo (run from its `dashboard/` subdir), so it's just
another app to the autodeploy loop. With **auto-update** on (chosen at install, or `MH_SELF_UPDATE=1`),
the dashboard tracks the monohost repo and redeploys itself on every release via the same `git push` →
deployd path as your apps. Off (default) it's pinned and refreshes only on `monohost update`. A broken
release is self-healing — deployd rolls back a failed build to the previous commit.

## Deploy an app

Open the dashboard (`http://<name>.local/dashboard/`) → **New app** → pick a repo → Deploy. From then
on, `git push` redeploys within one poll interval — no login to the box.

Your repo needs one file, **`monohost.json`**, carrying only what's intrinsic to the app (monohost
assigns the name, branch, and port):

```json
{
  "run": "uvicorn main:app --host 127.0.0.1 --port ${PORT}",
  "health": "/healthz"
}
```

- **`run`** — the literal command that starts your app. `${PORT}` is injected by monohost (also in the
  `PORT` env var). Any runtime works: uvicorn/FastAPI, gunicorn/Flask, Node, a Go binary, `python -m …`.
- **`health`** — a path that returns `200` when the app is up (default `/healthz`).
- **`dir`** *(optional)* — a subfolder of the repo to build and run from, for monorepos or apps not at
  the repo root (e.g. `"dir": "backend"`). Defaults to the repo root (where `monohost.json` lives).

`monohost.json` stays at the repo root even when `dir` is set. See the **Manifest examples** below.

### How dependencies are installed

monohost auto-detects how to build from the files in your repo (no manifest field needed). You don't
need a `requirements.txt` if you use `pyproject.toml`, and vice-versa — either works:

| Files in the repo | What monohost runs |
|---|---|
| `pyproject.toml` and/or `uv.lock` | `uv sync` (locked, reproducible — recommended for Python) |
| `requirements.txt` | creates a venv and runs `uv pip install -r requirements.txt` |
| `package.json` | `npm ci` (or `npm install` if there's no lockfile) |
| none of the above | no build step (for a Go/compiled binary or vendored deps) |

The Python virtualenv always lands at `<rundir>/.venv` and is put on the app's `PATH`, so `uvicorn`,
`gunicorn`, `flask`, `python`, etc. resolve to it.

### Manifest examples

```jsonc
// FastAPI / uvicorn (pyproject.toml + uv.lock)
{ "run": "uvicorn main:app --host 127.0.0.1 --port ${PORT}", "health": "/healthz" }

// Flask / gunicorn (requirements.txt)
{ "run": "gunicorn app:app --bind 127.0.0.1:${PORT}", "health": "/health" }

// Node / Express (package.json)
{ "run": "node server.js", "health": "/healthz" }

// app in a subfolder of a monorepo (manifest still at the repo root)
{ "run": "uvicorn main:app --host 127.0.0.1 --port ${PORT}", "health": "/healthz", "dir": "backend" }
```

## Expose an app publicly

If you set up a domain, each app row has an **expose** button with two zones:

- **prod** → `https://<app>.<your-domain>/` (its own subdomain, served at root),
- **dev** → `https://dev.<your-domain>/<app>/` (one shared host, one CNAME covers every dev app).

Have more than one Cloudflare domain? Register the extras with `monohost domain add <domain>`
(one-time browser authorization per domain, exactly like install) and the dashboard's expose
control grows a domain dropdown. Every registered domain gets the same two zones. One `monohost
update` first if you installed before multi-domain shipped.

Public exposure rides your Cloudflare tunnel; the dashboard's control plane is **LAN-only and admin-token
gated**, so a stray tunnel route can never reach onboarding/exposure.

## How it works

- **Trust boundary** — two non-admin service accounts. `mh-admin` owns the immutable control plane;
  `mh-deployer` owns the data plane and runs your apps. Privileged actions go through four root-owned,
  argument-validating scripts behind a single narrow `NOPASSWD` sudo rule.
- **Autodeploy (`deployd`)** — a 30s launchd tick compares each app's remote tip to local `HEAD` and,
  on a change, fetches + rebuilds + restarts it. The restart is root-free: it SIGTERMs the app's own run
  wrapper and launchd `KeepAlive` respawns it on the new code.
- **Routing (Caddy on :80)** — path-routes `<name>.local/<app>/` on the LAN; public host blocks are
  generated from your domain at expose time (nothing about your domain is baked into the shipped config).

See `how_to_monohost.md` for the full walkthrough, and `STEPS-TO-EXECUTE.md` for day-to-day ops.

## Layout

One repo. The control plane (`install.sh`, `setup.sh`, the `monohost` CLI, the privileged
`bin/*.sh` scripts, the Caddy config) plus the **bundled dashboard** in `dashboard/` — itself an
ordinary monohost app, run from that subdir via the root `monohost.json`'s `"dir": "dashboard"`, so it
can ride the same autodeploy loop as everything else.

Self-hosted, single-operator, on your own Mac. No external control plane.
