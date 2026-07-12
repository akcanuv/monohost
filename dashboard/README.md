# monohost-dashboard

The monohost control-plane web UI, served at `http://<your-mac>.local/dashboard/`. It is **bundled in
the monohost repo** (this `dashboard/` subdir) and run by `mh-deployer` as an ordinary monohost app
via the root `monohost.json`'s `"dir": "dashboard"`. With auto-update on (`MH_SELF_UPDATE=1`), it
tracks the monohost repo and redeploys itself through the normal GitOps loop; off, it's pinned and
refreshes on `monohost update`.

## What it does
- **Status (read-only):** every registered app with live **up/down** (loopback health check), route,
  inferred type, port, deployed short-SHA, health latency, and public exposure — plus host telemetry
  and a tail of recent deploys (`deployd.log`). Live log drawer per app.
- **Control plane:** **New app** (repo picker → streamed onboard), **offboard**, and **expose/unexpose**
  (dev/prod). These shell out to the root-owned helpers via the narrow `NOPASSWD` sudo rule.

## Security
Mutating endpoints (`/onboard`, `/offboard`, `/expose`, `/unexpose`) are gated: the request must come
from a **LAN** host (so a stray public tunnel route can't reach them) **and** carry the per-install
**admin token** (`/opt/monohost/secrets/dashboard.token`, printed once at install). The page embeds the
token only for legitimate LAN requests. Read-only status routes stay open on the LAN.

## Data it reads (as `mh-deployer`, no extra privilege)
- `registry/apps.tsv` → the app list + authoritative port
- `apps/<name>/monohost.json` → run command + health path
- `GET 127.0.0.1:<port><health>` → status
- `git rev-parse --short HEAD` in `apps/<name>` → deployed SHA

## Repo picker
`/api/repos` lists every repo the deploy token can access — the user's personal account **and** any
orgs it's authorized for (`GET /user/repos`, paginated). No org is hardcoded; set `MH_GITHUB_OWNER` to
filter to one owner.
