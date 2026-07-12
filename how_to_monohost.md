# How to build a monohost app

A guide for **app authors**: how to structure a repo so it deploys cleanly on monohost. If you're
running the server, see `README.md` and `STEPS-TO-EXECUTE.md` instead.

monohost deploys a GitHub repo as a managed service and routes traffic to it. You add **one file**
(`monohost.json`), make sure your app binds the port monohost gives it, and — if it has a web
frontend — keep its URLs **mount-aware**. That's it. `git push` then redeploys it automatically.

---

## TL;DR checklist

- [ ] Add `monohost.json` at the **repo root** with a `run` command that binds `127.0.0.1:${PORT}`.
- [ ] Pick a dependency format monohost understands: `pyproject.toml`+`uv.lock`, `requirements.txt`, or `package.json`.
- [ ] Pin a **stable** Python with a `.python-version` file (native-extension wheels lag new Python releases).
- [ ] Expose a **health** endpoint that returns `200` (default `/healthz`).
- [ ] If you have a frontend: serve it from the **same process**, use **relative** asset paths, and make API/asset URLs **mount-aware** (see below).
- [ ] Commit any **data files** your app reads at runtime (monohost only ships what's in git).
- [ ] Set secrets/config as **env vars in the onboarding page** (written to a `0600 .env.local`, auto-loaded) — don't commit them.
- [ ] Need a **database or file storage**? The host runs MongoDB + S3/MinIO — wire it up with env vars (§8).

---

## 1. The manifest: `monohost.json`

A single JSON file at the **root of your repo**. It carries only what's *intrinsic to your app* —
monohost assigns the name, branch, and port, so those are **not** in the manifest.

```json
{
  "run": "uvicorn main:app --host 127.0.0.1 --port ${PORT}",
  "health": "/healthz",
  "dir": "app"
}
```

| Field | Required | Meaning |
|---|---|---|
| `run` | **yes** | The literal command that starts your app. `${PORT}` is substituted with the port monohost assigns. Any runtime works (uvicorn, gunicorn, hypercorn, `node`, a compiled binary, `python -m …`). |
| `health` | no (default `/healthz`) | A path that returns HTTP `200` when the app is healthy. monohost checks it after deploy and the dashboard polls it. |
| `dir` | no (default: repo root) | A **subfolder** to build and run from — for monorepos or apps not at the repo root (e.g. `"dir": "app"`). The manifest itself still lives at the repo root. Validated to stay inside the checkout (relative, no `..`). |
| `build` | no | An extra shell **build command** run after the auto-detected dependency install — for a frontend build or codegen step (e.g. `"cd ui && npm ci && npm run build"`). Runs on every deploy in the run dir, as your app's user, with the venv + Homebrew on `PATH` and `.env.local` already loaded. A non-zero exit fails the deploy. See §3. |

**Ignored if present:** `name`, `branch`, `port`. monohost owns those (name + branch are chosen at
onboard; the port is allocated on the server). Putting them in the manifest does nothing — it just
prints a note.

---

## 2. The port contract

monohost allocates a loopback port per app and passes it two ways — use either:

- the **`${PORT}`** token in your `run` command (substituted at deploy), and
- the **`PORT`** environment variable (exported into the process).

Your app **must bind `127.0.0.1` (loopback) on that port** — not `0.0.0.0`, not a hardcoded port.
monohost reverse-proxies public/LAN traffic to it; binding loopback keeps the app off the network
directly.

```jsonc
// good — binds the assigned loopback port
{ "run": "uvicorn main:app --host 127.0.0.1 --port ${PORT}" }
{ "run": "gunicorn app:app --bind 127.0.0.1:${PORT}" }
{ "run": "node server.js" }            // and read process.env.PORT, bind 127.0.0.1
```

```jsonc
// bad — hardcoded port / public bind
{ "run": "uvicorn main:app --host 0.0.0.0 --port 8000" }
```

---

## 3. Dependencies & build

monohost **auto-detects** how to build from the files in your run dir — no manifest field needed.
You don't need both a `requirements.txt` and a `pyproject.toml`; pick one.

| Files in the (run) dir | What monohost runs | Notes |
|---|---|---|
| `pyproject.toml` and/or `uv.lock` | `uv sync` | Locked + reproducible. **Recommended for Python.** Commit `uv.lock`. |
| `requirements.txt` | `uv venv` + `uv pip install -r requirements.txt` | Classic pip-style. |
| `package.json` | `npm ci` (or `npm install` if no lockfile) | Node must be installed on the server. |
| none of the above | *(no build)* | For a Go/compiled binary or vendored deps. |

The Python virtualenv always lands at `<run dir>/.venv` and is put on the app's `PATH`, so console
scripts (`uvicorn`, `gunicorn`, `flask`, `python`, …) resolve to it automatically.

> **Wheels-only.** `uv sync` runs with `--no-build` (install from prebuilt wheels, no compile
> toolchain). That's fast and reliable — *as long as wheels exist for your Python version* (see next).

### Pin your Python version

Add a **`.python-version`** file next to your `pyproject.toml`/`requirements.txt`:

```
3.12
```

Why this matters: native-extension packages (anything with a compiled component — `numpy`,
`onnxruntime`, `py-rust-stemmers`, `pydantic-core`, …) publish wheels for a given Python version
**months after** that Python is released. If the server's default Python is bleeding-edge (say
3.14) and a dependency has no 3.14 wheel yet, the wheels-only install fails with:

```
Distribution `…` can't be installed because it is marked as `--no-build` but has no binary distribution
```

Pinning a **stable** version (3.12 or 3.13 are safe bets) makes `uv` pick a Python that has wheels
for your whole dependency tree. `uv` will download that Python on the server automatically if it's
not present. (You can verify locally: `uv sync --no-build` from a clean checkout should succeed.)

### Extra build step (`build`) — e.g. a frontend

The auto-detected install above handles the **run dir's** own dependencies (one of `uv sync` /
`pip install` / `npm`). For anything more — most commonly a **frontend bundle** in a monorepo — add a
`build` command to your manifest. It runs **after** the dependency install, on **every deploy**:

```jsonc
// Python backend at the repo root that serves a built SPA from ui/dist
{
  "run": "uvicorn app.api.main:app --host 127.0.0.1 --port ${PORT}",
  "health": "/health",
  "build": "cd ui && npm ci --include=dev && npm run build"
}
```

- Runs in the **run dir**, as your app's user, with the app's `.venv/bin` and Homebrew on `PATH`
  (so `npm`, `node`, `uv`, `python` resolve) and your **`.env.local` already sourced** — so a Vite
  build can read `VITE_*` build-time variables you set on the onboarding page.
- It's a literal shell command: chain with `&&`, `cd` into subfolders, call any installed tool.
- **Node must be installed on the server** for npm builds.
- Because `.env.local` is sourced first, a `NODE_ENV=production` you set on the onboarding page would
  make `npm ci` skip **devDependencies** (where Vite/TypeScript live) and the build would fail — use
  `npm ci --include=dev` (as above) to be safe.
- A **non-zero exit fails the deploy** — monohost rolls back to the last good commit and keeps the
  old code running, then retries on your next push.
- This means you **no longer need to commit build artifacts** (e.g. `ui/dist`) — let the server build
  them. (You still commit anything read at runtime that *isn't* produced by the build; see §6.)

---

## 4. Frontends and internal paths (the important one)

monohost runs **one process per app** and routes to it three ways:

| Where | URL | How monohost routes it |
|---|---|---|
| LAN | `http://<mac>.local/<name>/` | path-routed — **strips `/<name>`** before proxying |
| dev zone (public) | `https://dev.<domain>/<name>/` | path-routed — **strips `/<name>`** |
| prod zone (public) | `https://<name>.<domain>/` | served at the **root** — no strip |

Your backend always receives **stripped** paths (`/`, `/api/...`) — so write your routes normally.
The subtlety is the **browser**: under the LAN/dev path routes the page lives at `<host>/<name>/`, so
any **absolute** URL your app emits (`/api/…`, `/assets/…`, `<a href="/">`) is fetched by the browser
at `<host>/api/…` — which **misses** the `/<name>/` route and returns monohost's catch-all (you'll see
`JSON.parse: unexpected character at line 1 column 1` — that's the plain-text 404, not JSON).

**Rules for a compatible frontend:**

1. **Serve the frontend from the same process** (e.g. FastAPI `StaticFiles`, Flask static, Express
   static). monohost runs one process — don't expect a separate dev server.
2. **Use relative asset paths** in your HTML: `href="styles.css"`, `src="app.js"`,
   `src="assets/logo.png"` — **not** `/styles.css`, `/assets/…`.
3. **Make API calls and emitted URLs mount-aware.** Derive the mount prefix at runtime and prefix
   every API/asset URL with it. The cleanest, framework-agnostic way (vanilla JS):

   ```js
   // Works whether monohost serves the app under /<name>/ (LAN/dev) or at a domain root (prod).
   const MOUNT = (() => {
     try { return new URL(".", document.currentScript.src).pathname; } catch (e) {}
     return location.pathname.replace(/[^/]*$/, "") || "/";
   })();
   const api = (p) => MOUNT + String(p).replace(/^\//, "");   // "/api/x" -> "/<name>/api/x" or "/api/x"

   // use it:
   const res = await fetch(api("/api/docs"));
   ```

   If your backend emits absolute URLs inside content (e.g. `<img src="/api/.../assets/...">`),
   rewrite them on the client too:

   ```js
   function fixApiUrls(root) {
     if (MOUNT === "/") return;
     root.querySelectorAll('img[src^="/api/"]').forEach((el) =>
       el.setAttribute("src", MOUNT + el.getAttribute("src").slice(1)));
   }
   ```

   *(React/Vite: set `base: "./"` and use relative `fetch` against an axios/fetch baseURL derived the
   same way. Most SPA routers also accept a runtime `basename`.)*

> **Shortcut:** if you only ever expose the app at a **prod subdomain** (`<name>.<domain>/`, served at
> root), absolute `/api/…` paths work as-is with no changes. The mount-aware approach above is what
> makes it *also* work on the LAN and dev path routes. Doing it the mount-aware way costs nothing at
> the root, so it's the recommended default.

Access the LAN route with the **trailing slash** (`<host>/manak/`) — the dashboard's app link already
does this.

---

## 5. Health checks

Expose a cheap endpoint that returns `200` when the app is up. Default is `/healthz`; override with
`health` in the manifest. It should not depend on slow startup work — return `200` as soon as the
process can serve. monohost checks it right after deploy, and the dashboard polls it for the live
up/down indicator.

```python
@app.get("/healthz")
def healthz():
    return {"status": "ok"}
```

---

## 6. Runtime data & files

monohost deploys **only what's committed to git** — it does a shallow clone of your chosen branch. So:

- Any data files your app **reads at runtime** must be **committed** to the repo (and to the branch
  you deploy). Reference them relative to your code, not by an absolute machine path.
- The whole repo is cloned, then your app runs from `dir` (if set). So data at the repo root is
  available even when the app lives in a subfolder — resolve it relative to the repo root.
- Large binaries are fine but bloat the clone; **Git LFS is not pulled** by the deploy, so don't put
  runtime-required files behind LFS (you'd get pointer files).
- Writable runtime state (caches, indexes) can be written under the app dir and **survives redeploys**
  (a redeploy `git reset`s tracked files but leaves untracked ones like `.venv/` and your `.cache/`).

---

## 7. Config & secrets

monohost sets `PORT`, `HOME`, and `PATH` for you. **Everything else** — API keys, signing secrets,
database/storage credentials — you provide as **environment variables on the onboarding page**.

- The dashboard's **+ New app** page has an **Environment variables** section: add any number of
  `NAME` / `value` pairs (and use the **+ S3 storage** / **+ MongoDB** presets to pre-fill the
  standard names — see §8). They're stored privately for your app — **untracked so they survive
  redeploys** (§6) — and **auto-loaded into your process**. You just read `os.environ` /
  `process.env`; no `run`-command boilerplate.
- Names must match `^[A-Za-z_][A-Za-z0-9_]*$`. **`PORT`, `HOME`, and `PATH` are reserved** (monohost
  sets them) and are rejected.
- Re-onboarding with the env section **empty keeps your existing secrets**; re-enter values to
  replace them. Secrets are never read back into the browser.
- **Still don't commit secrets.** Ship non-secret config as committed defaults; set the secret bits
  via the editor. The onboarding page is **LAN + token gated**.

---

## 8. Data services: MongoDB & S3 (MinIO)

The host runs two native data services your app reaches over **loopback**: **MongoDB** (document
store) and **S3-compatible object storage (MinIO)**. Object storage is *also* reachable publicly at
**`https://files.example.com`** so browsers up/download bytes directly — they don't pass through your
app (the whole point of S3).

| Service | Your app reaches it at | Public? |
|---|---|---|
| **MongoDB** | `mongodb://127.0.0.1:27017/<db>` | No — loopback only |
| **S3 API (MinIO)** | `http://127.0.0.1:9000` (internal) | Yes, at `https://files.example.com` (for browsers) |

### Getting connected (via the env editor)

You wire both up by setting env vars on the onboarding page (§7). Two presets fill in the standard
names:

- **+ MongoDB** → adds a fixed **`MONGO_URI`** (`mongodb://127.0.0.1:27017`, locked) plus
  **`MONGO_DB`** for your **database name**. MongoDB has **no auth** in Phase 1 (loopback,
  single-operator), so you need **nothing from the operator** — just choose a distinct db name.
- **+ S3 storage** → adds the S3 variables. The two endpoints are **host-fixed (locked)**; you fill
  in **`S3_BUCKET`**, **`S3_ACCESS_KEY`**, **`S3_SECRET_KEY`**.

S3 is the one piece that **needs the operator**: only they can mint a bucket-scoped key for you. Ask
for "a bucket (private or public-read) + a scoped key"; they hand you the block to paste into the
editor:

```
S3_ENDPOINT_INTERNAL=http://127.0.0.1:9000
S3_ENDPOINT_PUBLIC=https://files.example.com
S3_BUCKET=<your-bucket>
S3_ACCESS_KEY=<scoped key>
S3_SECRET_KEY=<scoped secret>
```

Your key is **scoped to your bucket(s) only** — it is not the admin key and can't touch other apps'
data.

### MongoDB

Loopback, **no authentication** in Phase 1. Treat the URI as config so auth can be enabled later with
no code change.

```python
# pip/uv add pymongo
import os
from pymongo import MongoClient

db = MongoClient(os.environ["MONGO_URI"])[os.environ["MONGO_DB"]]   # connection + database name
db.notes.insert_one({"hello": "world"})
```

Use a **distinct db name** per app; don't assume other databases are yours.

### S3 — two rules that make it work

**Rule 1 — two endpoints.** Use the *internal* endpoint for your own I/O, the *public* one **only** to
sign URLs for browsers:

| Endpoint | Use it for | Why |
|---|---|---|
| `S3_ENDPOINT_INTERNAL` (`http://127.0.0.1:9000`) | your app's own `put`/`get`/`list` | fast, no Cloudflare hop, no 100 MB cap |
| `S3_ENDPOINT_PUBLIC` (`https://files.example.com`) | **minting presigned URLs** for browsers | the signature is host-specific — sign for the public host or it won't validate |

**Rule 2 — path-style URLs:** `https://files.example.com/<bucket>/<key>` (not `<bucket>.files…`).
Configure your SDK for path-style.

```python
import os, boto3
from botocore.config import Config

_cfg = Config(signature_version="s3v4", s3={"addressing_style": "path"})
def s3(endpoint):
    return boto3.client("s3", endpoint_url=endpoint,
        aws_access_key_id=os.environ["S3_ACCESS_KEY"],
        aws_secret_access_key=os.environ["S3_SECRET_KEY"],
        region_name="us-east-1", config=_cfg)

internal = s3(os.environ["S3_ENDPOINT_INTERNAL"])   # server-side I/O
public   = s3(os.environ["S3_ENDPOINT_PUBLIC"])     # presigned URLs
bucket   = os.environ["S3_BUCKET"]

internal.put_object(Bucket=bucket, Key="reports/2026.pdf", Body=open("2026.pdf", "rb"))
download_url = public.generate_presigned_url("get_object",                 # hand to a browser
    Params={"Bucket": bucket, "Key": "reports/2026.pdf"}, ExpiresIn=300)
upload_url = public.generate_presigned_url("put_object",                   # browser PUTs straight to S3
    Params={"Bucket": bucket, "Key": "incoming/photo.jpg"}, ExpiresIn=300)
```

Node (AWS SDK v3) is the same idea — `new S3Client({ endpoint, credentials, forcePathStyle: true })`,
then `getSignedUrl(...)` against the **public** client.

**Public-read buckets:** if the operator made the bucket public-read, any object is fetchable with no
signing at `https://files.example.com/<bucket>/<key>` — good for images/CSS/downloads. Put **only**
non-sensitive data there.

### Constraints & gotchas

| Symptom / limit | Cause | Fix |
|---|---|---|
| `SignatureDoesNotMatch` in the browser | URL signed against `127.0.0.1:9000` | Sign presigned URLs with `S3_ENDPOINT_PUBLIC` (Rule 1) |
| Browser `PUT` of a big file fails (~`413`) | Cloudflare caps one proxied request at **100 MB** | Use multipart (SDKs do this automatically), or upload server-side over loopback |
| `403 AccessDenied` on a private object URL | no/expired signature, or wrong key | Presign it; check your scoped key covers the bucket |
| `404` on `/minio/admin/...` publicly | the admin API is blocked at the edge (by design) | Admin ops are operator-only — you don't need them |
| Bucket/db "doesn't exist" | not provisioned / wrong name | Ask the operator (S3 bucket) or pick the right name (Mongo db) |
| Secrets missing at runtime | env var not set at onboard | Set it in the env editor (§7) and re-onboard |

### Local development

The instances live on the host. For local dev either run your **own** MinIO + MongoDB (point the env
vars at `localhost`), or use the **public** S3 endpoint with your scoped key from your laptop (set
both `S3_ENDPOINT_*` to `https://files.example.com` — you lose the loopback fast-path but the code is
identical). Keep everything in env vars so the same code runs in both places.

---

## 9. The deploy lifecycle

1. **Onboard once** — from the dashboard: **+ New app** → pick your repo → name it (and set any env
   vars, §7).
2. **Push to deploy** — every `git push` to the deployed branch is picked up automatically within
   ~30s: monohost fetches, rebuilds (per §3), and restarts your app. No login to the box.
3. **Restart mechanism** — a redeploy sends your process a `SIGTERM` and restarts it on the new code.
   Handling `SIGTERM` for a graceful shutdown is nice but not required.
4. **Failed builds self-heal** — if a build fails, monohost rolls the checkout back to the previous
   commit and keeps the old code running, then retries on your next push.

App name must match `^[a-z0-9][a-z0-9-]{0,30}$` (it becomes the route segment). The name `dashboard`
is reserved.

---

## 10. Exposing publicly (optional)

Once onboarded, an app is reachable on your LAN at `<mac>.local/<name>/`. To put it on the internet,
use the dashboard's **expose** button:

- **prod** → `https://<name>.<domain>/` — its own subdomain, served at root. Absolute paths work; best
  for a primary app.
- **dev** → `https://dev.<domain>/<name>/` — one shared host, path-routed (needs the mount-aware
  frontend from §4). One CNAME covers all dev apps.

Both ride your Cloudflare tunnel. The dashboard control plane itself is never publicly exposable.

---

## Worked examples

```jsonc
// FastAPI + uvicorn, app at repo root, deps via pyproject.toml + uv.lock
{ "run": "uvicorn main:app --host 127.0.0.1 --port ${PORT}", "health": "/healthz" }
```

```jsonc
// Flask + gunicorn, deps via requirements.txt
{ "run": "gunicorn app:app --bind 127.0.0.1:${PORT}", "health": "/health" }
```

```jsonc
// Node / Express (read process.env.PORT, bind 127.0.0.1), deps via package.json
{ "run": "node server.js", "health": "/healthz" }
```

```jsonc
// Monorepo: FastAPI backend + static frontend live in app/, data at the repo root
{ "run": "uvicorn backend.main:app --host 127.0.0.1 --port ${PORT}", "health": "/api/ping", "dir": "app" }
```

For the monorepo case, add `app/.python-version` (e.g. `3.13`) next to `app/pyproject.toml`, and make
the frontend mount-aware as in §4. (This is exactly how the `manak` engineering-standards app — a
FastAPI backend serving a static frontend over a committed `lib/` data tree — runs on monohost.)

---

## Common pitfalls (and fixes)

| Symptom | Cause | Fix |
|---|---|---|
| `JSON.parse: unexpected character at line 1 column 1` in the browser | Frontend uses absolute `/api/…` under the `/<name>/` path route → hits monohost's text catch-all | Make API/asset URLs mount-aware (§4), or expose at a prod subdomain |
| `… marked as --no-build but has no binary distribution` during deploy | A dependency has no wheel for the resolved (often too-new) Python | Pin `.python-version` to a stable version with wheels (§3) |
| App "deploys" but data is missing / empty | Data not committed, on a different branch, or behind Git LFS | Commit the data to the deployed branch; don't use LFS for runtime files (§6) |
| App never goes healthy | Bound `0.0.0.0`/a hardcoded port, or `health` path wrong | Bind `127.0.0.1:${PORT}`; set `health` to a real `200` route (§2, §5) |
| Assets 404 on the LAN/dev route | Absolute asset paths (`/styles.css`) | Use relative paths (`styles.css`) and a mount-aware base (§4) |
