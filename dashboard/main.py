"""monohost dashboard — status homepage + control plane (served at <this-mac>.local/dashboard/).

Runs as mh-deployer (an ordinary monohost app). Reads the registry + each app's monohost.json,
health-checks each app on loopback, and tails deployd.log — all without any extra privilege.

The mutating control-plane endpoints (onboard/offboard/expose/unexpose) shell out to root-owned
helpers via a narrow NOPASSWD sudo rule. They are gated: requests must arrive with a LAN Host (so a
stray public tunnel ingress can't reach them) AND carry the per-install admin token.
"""
import asyncio
import hmac
import ipaddress
import json
import os
import platform
import re
import shlex
import shutil
import socket
import subprocess
import time
from pathlib import Path

import httpx
from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import HTTPException
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    JSONResponse,
    StreamingResponse,
)
from fastapi.templating import Jinja2Templates

MH_ROOT = Path(os.environ.get("MH_ROOT", "/opt/monohost"))
REGISTRY = MH_ROOT / "registry" / "apps.tsv"
APPS_DIR = MH_ROOT / "apps"
DEPLOYD_LOG = MH_ROOT / "logs" / "deployd.log"
LOGS_DIR = MH_ROOT / "logs"
TOKEN_FILE = MH_ROOT / "secrets" / "github.token"
ONBOARD = "/opt/monohost/bin/onboard.sh"
OFFBOARD = "/opt/monohost/bin/offboard.sh"
EXPOSURES = MH_ROOT / "registry" / "exposures.tsv"
DOMAINS = MH_ROOT / "registry" / "domains.tsv"
EXPOSE = "/opt/monohost/bin/expose.sh"
UNEXPOSE = "/opt/monohost/bin/unexpose.sh"
DASHBOARD_TOKEN_FILE = MH_ROOT / "secrets" / "dashboard.token"
# Optional single-owner filter. Empty (the default) lists every repo the PAT can see — personal
# account AND any orgs it's authorized for. No org is ever hardcoded.
GITHUB_OWNER = os.environ.get("MH_GITHUB_OWNER", "").strip()
LOGO_FILE = Path(__file__).parent / "static" / "logo.png"

app = FastAPI(title="monohost dashboard")
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


# ── control-plane auth ──────────────────────────────────────────────────────
# Mutations are LAN-only (a stray public tunnel ingress that reaches this listener is rejected) and
# require the per-install admin token (generated at setup, stored 600 in secrets/dashboard.token).

def control_token() -> str:
    try:
        return DASHBOARD_TOKEN_FILE.read_text().strip()
    except Exception:
        return ""


def lan_host() -> str:
    """This Mac's mDNS name (<LocalHostName>.local), derived at runtime — never hardcoded."""
    try:
        r = subprocess.run(
            ["/usr/sbin/scutil", "--get", "LocalHostName"],
            capture_output=True, text=True, timeout=2,
        )
        n = r.stdout.strip()
        if n:
            return f"{n}.local"
    except Exception:
        pass
    return socket.gethostname()


def is_lan_host(host_header: str) -> bool:
    """True for loopback, *.local, private/link-local IPs, and dotless short hostnames; False for a
    public FQDN/IP (e.g. what the Cloudflare tunnel forwards). This is the LAN gate for the control
    plane, so it FAILS CLOSED: anything that doesn't clearly parse as LAN returns False."""
    raw = (host_header or "").split(",")[0].strip()
    if not raw:
        return False
    # strip the optional :port, handling bracketed/bare IPv6 (where ':' is part of the address)
    if raw.startswith("["):                 # [IPv6] or [IPv6]:port
        h = raw[1:].split("]", 1)[0]
    elif raw.count(":") == 1:               # host:port (IPv4 or hostname)
        h = raw.split(":", 1)[0]
    else:                                   # bare IPv6 literal, or a bare hostname
        h = raw
    h = h.strip().lower()
    if not h:
        return False
    if h == "localhost" or h.endswith(".local"):
        return True
    try:
        ip = ipaddress.ip_address(h)
        return ip.is_loopback or ip.is_private or ip.is_link_local
    except ValueError:
        pass
    # bare short hostname only (no dot, no colon); a mangled/unparsed IPv6 fragment must NOT slip through
    return "." not in h and ":" not in h


def require_control(request: Request, x_mh_token: str | None = Header(default=None)):
    """FastAPI dependency guarding the mutating endpoints. Fails closed."""
    if not is_lan_host(request.headers.get("host", "")):
        raise HTTPException(status_code=403, detail="control plane is LAN-only")
    tok = control_token()
    if not tok:
        raise HTTPException(status_code=503, detail="control plane locked (no admin token on the box)")
    if not x_mh_token or not hmac.compare_digest(x_mh_token, tok):
        raise HTTPException(status_code=401, detail="missing or invalid admin token")


def token_for(request: Request) -> str:
    """The admin token to embed in a page — only for legitimate LAN requests, never leaked publicly."""
    return control_token() if is_lan_host(request.headers.get("host", "")) else ""


def _fmt_bytes(n) -> str:
    """Human byte size — mirrors the frontend fmtBytes so SSR + live agree."""
    if n is None:
        return "—"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if n < 1024 or unit == "PB":
            return f"{round(n)} {unit}" if (n >= 100 or unit == "B") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{round(n)} PB"


def _fmt_uptime(s) -> str:
    if s is None:
        return "—"
    s = int(s)
    d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return f"{d}d {h}h" if d else (f"{h}h {m}m" if h else f"{m}m")


templates.env.filters["bytes"] = _fmt_bytes
templates.env.filters["uptime"] = _fmt_uptime


# ── host telemetry ──────────────────────────────────────────────────────────
# Read with zero privilege (the dashboard runs as an ordinary deployer): load
# average + core count from os, disk from shutil, memory from vm_stat/sysctl on
# macOS or /proc on Linux. Every probe is wrapped so a single failure degrades to
# a null field instead of a 500 — the frontend renders "—" for anything missing.

def _sysctl(key: str) -> str:
    # Absolute path: sysctl lives in /usr/sbin, which is NOT on the app's launchd
    # PATH (/opt/homebrew/bin:/usr/bin:/bin). Bare "sysctl" → FileNotFoundError there.
    for exe in ("/usr/sbin/sysctl", "sysctl"):
        try:
            r = subprocess.run([exe, "-n", key], capture_output=True, text=True, timeout=3)
            if r.returncode == 0:
                return r.stdout.strip()
        except FileNotFoundError:
            continue
    return ""


def _total_mem() -> int:
    """Total physical RAM via sysconf — no subprocess, works on macOS and Linux."""
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (ValueError, OSError, AttributeError):
        return 0


def _mem_macos() -> tuple[int, int]:
    """(total_bytes, used_bytes) on macOS via sysconf total + vm_stat page tallies."""
    total = _total_mem()
    # vm_stat is /usr/bin/vm_stat (on PATH), but pin it absolutely to be safe.
    out = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=3).stdout
    page = 4096
    m = re.search(r"page size of (\d+) bytes", out)
    if m:
        page = int(m.group(1))
    pages: dict[str, int] = {}
    for line in out.splitlines():
        mm = re.match(r"(.+?):\s+(\d+)\.", line)
        if mm:
            pages[mm.group(1).strip()] = int(mm.group(2))
    # "used" ≈ what Activity Monitor calls Memory Used: active + wired + compressed.
    used = (
        pages.get("Pages active", 0)
        + pages.get("Pages wired down", 0)
        + pages.get("Pages occupied by compressor", 0)
    ) * page
    return total, used


def _mem_linux() -> tuple[int, int]:
    """(total_bytes, used_bytes) on Linux from /proc/meminfo (kB → bytes)."""
    info: dict[str, int] = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        k, _, v = line.partition(":")
        parts = v.split()
        if parts and parts[0].isdigit():
            info[k.strip()] = int(parts[0]) * 1024
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", info.get("MemFree", 0))
    return total, max(0, total - avail)


def _uptime_seconds() -> float | None:
    try:
        if platform.system() == "Darwin":
            # CLOCK_UPTIME_RAW is seconds since boot — no subprocess, no PATH issue.
            return time.clock_gettime(time.CLOCK_UPTIME_RAW)
        return float(Path("/proc/uptime").read_text().split()[0])
    except Exception:
        return None


def system_stats() -> dict:
    """A point-in-time host snapshot — load, memory, disk, uptime. Never raises."""
    cores = os.cpu_count() or 1

    load = None
    try:
        load = list(os.getloadavg())  # (1m, 5m, 15m)
    except (OSError, AttributeError):
        pass

    mem = None
    try:
        total, used = _mem_macos() if platform.system() == "Darwin" else _mem_linux()
        if total:
            mem = {
                "total": total,
                "used": used,
                "free": max(0, total - used),
                "pct": round(used / total * 100, 1),
            }
    except Exception:
        pass

    disk = None
    try:
        du = shutil.disk_usage("/")
        disk = {
            "total": du.total,
            "used": du.used,
            "free": du.free,
            "pct": round(du.used / du.total * 100, 1) if du.total else None,
        }
    except Exception:
        pass

    cpu_pct = None
    if load is not None:
        # CPU load as a saturation %: 1-minute load average against the core count,
        # clamped to 100. This *is* "cpu load" — honest and dependency-free.
        cpu_pct = round(min(load[0] / cores, 1.0) * 100, 1)

    return {
        "host": platform.node() or socket.gethostname(),
        "os": f"{platform.system()} {platform.release()}",
        "arch": platform.machine(),
        "cores": cores,
        "load": load,
        "cpu_pct": cpu_pct,
        "mem": mem,
        "disk": disk,
        "uptime": _uptime_seconds(),
        "ts": time.time(),
    }


def read_registry() -> list[dict]:
    apps: list[dict] = []
    if not REGISTRY.exists():
        return apps
    for line in REGISTRY.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if parts and parts[0]:
            reg_port = (
                int(parts[3]) if len(parts) > 3 and parts[3].strip().isdigit() else None
            )
            apps.append(
                {
                    "name": parts[0],
                    "repo": parts[1] if len(parts) > 1 else "",
                    "branch": parts[2] if len(parts) > 2 else "main",
                    "reg_port": reg_port,  # authoritative running port (from onboard.sh)
                }
            )
    return apps


def read_exposures() -> dict:
    """name -> {fqdn, zone, domain} for apps currently exposed publicly (registry/exposures.tsv).
    domain is "" for legacy 4-column rows — treated as the install (default) domain."""
    out: dict = {}
    if not EXPOSURES.exists():
        return out
    for line in EXPOSURES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 3 and parts[0]:
            domain = parts[4] if len(parts) >= 5 and parts[4] else ""
            out[parts[0]] = {"fqdn": parts[1], "zone": parts[2], "domain": domain}
    return out


def read_domains() -> list[dict]:
    """Registered exposure domains from registry/domains.tsv, in file order. The FIRST row is the
    install (default) domain — guaranteed by setup.sh's seeding order; the dashboard cannot read
    zones.env (cloudflare/ is 700 mh-admin), so row order is the default marker."""
    out: list[dict] = []
    if not DOMAINS.exists():
        return out
    for line in DOMAINS.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if parts and parts[0]:
            dev_base = parts[1] if len(parts) > 1 and parts[1] else f"dev.{parts[0]}"
            out.append({"domain": parts[0], "dev_base": dev_base})
    return out


def app_manifest(name: str) -> dict:
    f = APPS_DIR / name / "monohost.json"
    if f.exists():
        try:
            return json.loads(f.read_text())
        except Exception:
            return {}
    return {}


def read_env_local(name: str) -> list[dict]:
    """An app's current env vars, parsed back out of its 0600 .env.local.

    onboard.sh writes one `KEY=<shlex.quote(value)>` per line, so a single shlex.split over the
    whole file round-trips it exactly — quoting, spaces and embedded newlines included. Unreadable
    or malformed file → no vars (the form then just shows none)."""
    try:
        toks = shlex.split((APPS_DIR / name / ".env.local").read_text())
    except Exception:
        return []
    out: list[dict] = []
    for tok in toks:
        k, sep, v = tok.partition("=")
        if sep and k:
            out.append({"name": k, "value": v})
    return out


def deployed_sha(name: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(APPS_DIR / name), "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return out.stdout.strip() or "?"
    except Exception:
        return "?"


async def health_of(client: httpx.AsyncClient, port, health: str) -> dict:
    if not port:
        return {"up": None, "detail": "no port"}
    try:
        t0 = time.perf_counter()
        r = await client.get(f"http://127.0.0.1:{port}{health}")
        ms = int((time.perf_counter() - t0) * 1000)
        return {"up": r.status_code == 200, "code": r.status_code, "ms": ms}
    except Exception as e:
        return {"up": False, "detail": type(e).__name__}


async def gather() -> list[dict]:
    rows: list[dict] = []
    exposures = read_exposures()
    async with httpx.AsyncClient(timeout=2.0) as client:
        for a in read_registry():
            m = app_manifest(a["name"])
            # Registry port (set by onboard.sh) is authoritative. The manifest no longer carries a
            # port (it's server-assigned), so this is just a defensive fallback.
            port = a.get("reg_port") or m.get("port")
            # The minimal manifest has no 'type'; show the runtime inferred from the run command.
            run_cmd = m.get("run", "")
            disp_type = m.get("type") or (run_cmd.split()[0] if run_cmd else "?")
            exp = exposures.get(a["name"])
            # dev apps are path-routed under the shared host (https://dev.../<name>/);
            # prod apps are served at their subdomain root (https://<name>.../).
            public_url = None
            if exp:
                public_url = (
                    f"https://{exp['fqdn']}/{a['name']}/"
                    if exp["zone"] == "dev"
                    else f"https://{exp['fqdn']}/"
                )
            rows.append(
                {
                    **a,
                    "port": port,
                    "type": disp_type,
                    "route": f"/{a['name']}/",
                    "sha": deployed_sha(a["name"]),
                    "health": await health_of(client, port, m.get("health", "/healthz")),
                    "public": {
                        "exposed": exp is not None,
                        "fqdn": exp["fqdn"] if exp else None,
                        "zone": exp["zone"] if exp else None,
                        "domain": exp.get("domain") if exp else None,
                        "url": public_url,
                    },
                }
            )
    return rows


def recent_activity(n: int = 12) -> list[str]:
    if not DEPLOYD_LOG.exists():
        return []
    # No trailing space — offboard lines ("<name>: offboarded") have no text after the verb.
    # ": deployed" still won't match deployd's "... 0 deployed" tick lines (no colon there).
    markers = (": deploying", ": deployed", ": onboarded", ": offboarded", ": exposed", ": unexposed")
    events = [
        ln for ln in DEPLOYD_LOG.read_text().splitlines()
        if any(m in ln for m in markers)
    ]
    return events[-n:][::-1]


@app.get("/healthz")
def healthz():
    return {"status": "ok", "app": "dashboard"}


@app.get("/api/apps")
async def api_apps():
    return JSONResponse(await gather())


@app.get("/api/system")
def api_system():
    return JSONResponse(system_stats())


@app.get("/logo.png")
def logo():
    if LOGO_FILE.exists():
        return FileResponse(LOGO_FILE, media_type="image/png")
    return JSONResponse({"error": "logo not bundled"}, status_code=404)


@app.get("/logs/{name}")
async def logs(name: str):
    """Live-stream the tail of a service's logs (out + err), `tail -F` style.

    The dashboard runs as mh-deployer and each app's daemon runs as the same user, so its
    StandardOut/ErrorPath files are deployer-readable — no privilege needed. `name` is validated
    against the app-name grammar to keep it inside logs/ (no path traversal).
    """
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,30}", name):
        return JSONResponse({"error": "invalid name"}, status_code=400)
    files = [LOGS_DIR / f"{name}.err.log", LOGS_DIR / f"{name}.out.log"]
    existing = [str(f) for f in files if f.exists()]
    if not existing:
        return JSONResponse({"error": f"no logs for '{name}'"}, status_code=404)

    async def stream():
        # /usr/bin/tail is absolute on purpose: the launchd PATH (/opt/homebrew/bin:/usr/bin:/bin)
        # does include /usr/bin, but pinning it matches the rest of this module and is robust.
        proc = await asyncio.create_subprocess_exec(
            "/usr/bin/tail", "-n", "200", "-F", *existing,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        )
        try:
            assert proc.stdout is not None
            async for line in proc.stdout:
                yield line
        finally:
            # client disconnected (switched service / closed drawer) → kill the tail so it doesn't leak
            try:
                proc.terminate()
            except ProcessLookupError:
                pass

    return StreamingResponse(
        stream(),
        media_type="text/plain",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


def github_token() -> str:
    try:
        return TOKEN_FILE.read_text().strip()
    except Exception:
        return ""


@app.get("/api/repos")
async def api_repos():
    token = github_token()
    if not token:
        return JSONResponse({"error": "no deploy token on the box"}, status_code=500)
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
    # Token-driven: lists every repo the PAT can access — the user's personal account AND any orgs
    # it's authorized for. Works for personal accounts, org members, and classic + fine-grained PATs
    # (the org-only /orgs/{org}/repos endpoint 404s for personal accounts, so it is never used).
    url = (
        "https://api.github.com/user/repos"
        "?per_page=100&sort=updated&affiliation=owner,organization_member"
    )
    repos: list[dict] = []
    async with httpx.AsyncClient(timeout=15) as client:
        for _ in range(10):  # follow Link rel=next, up to ~1000 repos
            r = await client.get(url, headers=headers)
            if r.status_code != 200:
                return JSONResponse(
                    {"error": f"github {r.status_code}", "detail": r.text[:300]}, status_code=502
                )
            for x in r.json():
                # optional single-owner filter (MH_GITHUB_OWNER); empty = list everything
                if GITHUB_OWNER and x["owner"]["login"].lower() != GITHUB_OWNER.lower():
                    continue
                repos.append(
                    {
                        "name": x["name"],
                        "full_name": x["full_name"],
                        "clone_url": x["clone_url"],
                        "private": x["private"],
                        "default_branch": x.get("default_branch", "main"),
                    }
                )
            nxt = r.links.get("next", {}).get("url")
            if not nxt:
                break
            url = nxt
    return JSONResponse(repos)


@app.get("/api/env/{name}")
def api_env(name: str, _auth: None = Depends(require_control)):
    """Current env vars for an app, used to pre-fill the edit form. Values come back in the clear,
    so this rides the same LAN-only + admin-token gate as the mutating endpoints."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,30}", name):
        return JSONResponse({"error": "invalid name"}, status_code=400)
    return JSONResponse(read_env_local(name))


def env_payload(body: dict) -> bytes:
    """Normalize the onboard request's optional `env` into the JSON bytes onboard.sh reads on
    stdin: a list of {"name","value"} objects, keeping only entries with a non-empty name.

    Secrets travel via stdin (never argv) so they can't surface in `ps`/process listings.
    onboard.sh re-validates every name and shell-quotes every value — it is the trust boundary;
    this is just shaping, not security."""
    raw = body.get("env")
    pairs: list[dict] = []
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, dict):
                name = str(item.get("name", "")).strip()
                if name:
                    pairs.append({"name": name, "value": str(item.get("value", ""))})
    return json.dumps(pairs).encode()


@app.post("/onboard")
async def onboard(request: Request, _auth: None = Depends(require_control)):
    body = await request.json()
    name = str(body.get("name", "")).strip()
    repo = str(body.get("repo", "")).strip()
    branch = str(body.get("branch", "main")).strip() or "main"
    payload = env_payload(body)
    n_env = len(json.loads(payload))

    async def stream():
        # Args are passed as separate argv (no shell) and onboard.sh re-validates them — it is
        # the real trust boundary. Env vars go over stdin (NOT argv) so secrets stay out of `ps`.
        # We just stream onboard.sh's output back to the browser line by line.
        note = f"  (+{n_env} env var(s) via stdin)" if n_env else ""
        yield f"$ sudo onboard.sh {name} {repo} {branch}{note}\n".encode()
        try:
            proc = await asyncio.create_subprocess_exec(
                "sudo", ONBOARD, name, repo, branch,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except Exception as e:  # pragma: no cover
            yield f"failed to start onboard.sh: {e}\n".encode()
            return
        assert proc.stdin is not None and proc.stdout is not None
        # onboard.sh reads all of stdin up front; write the (tiny) payload and close so it proceeds.
        proc.stdin.write(payload)
        await proc.stdin.drain()
        proc.stdin.close()
        async for line in proc.stdout:
            yield line
        rc = await proc.wait()
        yield f"\n[exit {rc}]\n".encode()

    return StreamingResponse(stream(), media_type="text/plain")


@app.post("/offboard")
async def offboard(request: Request, _auth: None = Depends(require_control)):
    body = await request.json()
    name = str(body.get("name", "")).strip()
    # offboard.sh re-validates and refuses the dashboard; we just run it and report.
    proc = await asyncio.create_subprocess_exec(
        "sudo", OFFBOARD, name,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    return JSONResponse(
        {"ok": proc.returncode == 0, "rc": proc.returncode, "output": out.decode()}
    )


@app.post("/expose")
async def expose(request: Request, _auth: None = Depends(require_control)):
    body = await request.json()
    name = str(body.get("name", "")).strip()
    zone = str(body.get("zone", "dev")).strip() or "dev"
    domain = str(body.get("domain", "")).strip()

    async def stream():
        # expose.sh re-validates name + zone + domain — it is the trust boundary.
        argv = ["sudo", EXPOSE, name, zone] + ([domain] if domain else [])
        shown = ["sudo", "expose.sh", name, zone] + ([domain] if domain else [])
        yield ("$ " + " ".join(shown) + "\n").encode()
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except Exception as e:  # pragma: no cover
            yield f"failed to start expose.sh: {e}\n".encode()
            return
        assert proc.stdout is not None
        async for line in proc.stdout:
            yield line
        rc = await proc.wait()
        yield f"\n[exit {rc}]\n".encode()

    return StreamingResponse(stream(), media_type="text/plain")


@app.post("/unexpose")
async def unexpose(request: Request, _auth: None = Depends(require_control)):
    body = await request.json()
    name = str(body.get("name", "")).strip()
    proc = await asyncio.create_subprocess_exec(
        "sudo", UNEXPOSE, name,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    return JSONResponse(
        {"ok": proc.returncode == 0, "rc": proc.returncode, "output": out.decode()}
    )


@app.get("/new", response_class=HTMLResponse)
async def new_app(request: Request, name: str = ""):
    # ?name=<app> → edit mode: the same form, with repo + name pinned to the registry row and the
    # env rows pre-filled from .env.local (fetched separately, behind the control gate). Submitting
    # re-runs onboard.sh, which is idempotent — it rewrites .env.local and redeploys the app.
    edit = next((a for a in read_registry() if a["name"] == name), None) if name else None
    return templates.TemplateResponse(
        request,
        "new.html",
        {"control_token": token_for(request), "lan_host": lan_host(), "edit": edit},
    )


@app.exception_handler(404)
async def not_found(request: Request, exc: HTTPException):
    """Render the branded 404 for browser navigations; keep JSON for API/XHR clients."""
    accept = request.headers.get("accept", "")
    wants_html = "text/html" in accept and request.method == "GET"
    if not wants_html:
        return JSONResponse({"detail": getattr(exc, "detail", "Not Found")}, status_code=404)
    return templates.TemplateResponse(request, "404.html", {}, status_code=404)


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    # Starlette's current signature is TemplateResponse(request, name, context).
    return templates.TemplateResponse(
        request,
        "index.html",
        {
            "apps": await gather(),
            "activity": recent_activity(),
            "system": system_stats(),
            "control_token": token_for(request),
            "lan_host": lan_host(),
            "domains": read_domains(),
        },
    )
