#!/usr/bin/env python3
"""
Nightly auto-remediation for CRITICAL/HIGH container CVEs.

Runs on the host (cron, 01:00 ET) and, for every running image that has open
CRITICAL/HIGH findings with a known fix:

  1. re-pulls the same tag, or rebuilds the image with --pull --no-cache
  2. Trivy-scans old vs new image (same Trivy DB) and only continues if the new
     image fixes something and introduces no new CRITICAL
  3. checks version gates (no surprise major upgrades / data migrations) and
     invariants (e.g. glibc under Postgres)
  4. backs up whatever the config lists (pg_dump, config dirs, layer files)
  5. recreates each container from its *current* config with the new image —
     no compose, no secrets: the running container already carries its env —
     keeping the old container stopped as <name>-autorem-prev
  6. waits for healthy/stable, runs the configured smoke tests, and rolls back
     to the old container on any failure

Results go to the security scanner (security.remediation_runs/actions), which
then runs the nightly full scan and emails the report including what was fixed.

Usage:
  auto-remediate.py                 # normal nightly run (refuses outside the window)
  auto-remediate.py --dry-run       # show what would be attempted; changes nothing
  auto-remediate.py --dry-run --scan  # ...and Trivy-scan current vs. refreshed images
  auto-remediate.py --only redis:7.2-bookworm --ignore-window   # manual single image
"""
from __future__ import annotations

import argparse
import copy
import fcntl
import http.client
import json
import logging
import re
import socket
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

CONFIG_PATH = Path(__file__).with_suffix(".toml")
PREV_SUFFIX = "-autorem-prev"

log = logging.getLogger("auto-remediate")


class RemediationError(Exception):
    pass


# ─── Shell / Docker helpers ───────────────────────────────────────────────────

def sh(cmd: list[str], timeout: int = 600, check: bool = True, input_bytes: bytes | None = None,
       stdout=subprocess.PIPE) -> subprocess.CompletedProcess:
    log.debug("$ %s", " ".join(cmd))
    try:
        r = subprocess.run(cmd, input=input_bytes, stdout=stdout, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RemediationError(f"timed out after {timeout}s: {' '.join(cmd[:4])}")
    if check and r.returncode != 0:
        err = (r.stderr or b"").decode(errors="replace").strip().splitlines()
        raise RemediationError(f"{' '.join(cmd[:4])} failed (rc={r.returncode}): {err[-1] if err else ''}")
    return r


def out(cmd: list[str], timeout: int = 600, check: bool = True) -> str:
    return sh(cmd, timeout=timeout, check=check).stdout.decode(errors="replace").strip()


def inspect(kind: str, ref: str) -> dict | None:
    r = sh(["docker", kind, "inspect", ref], check=False, timeout=60)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout)[0]


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str = "/var/run/docker.sock", timeout: int = 120):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._path)


def docker_create(name: str, body: dict) -> str:
    """POST /containers/create — the CLI has no way to create from a full inspect config."""
    conn = _UnixHTTPConnection()
    conn.request("POST", f"/v1.47/containers/create?name={name}", json.dumps(body),
                 {"Content-Type": "application/json"})
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    if resp.status != 201:
        raise RemediationError(f"create {name} failed: HTTP {resp.status} {data[:300]!r}")
    return json.loads(data)["Id"]


def normalize_ref(ref: str) -> str:
    """Config.Image as written by compose may omit the tag."""
    if "@" in ref:
        return ref
    last = ref.rsplit("/", 1)[-1]
    return ref if ":" in last else f"{ref}:latest"


def prev_tag(ref: str) -> str:
    repo, tag = ref.rsplit(":", 1)
    return f"{repo}:{(tag + PREV_SUFFIX)[:128]}"


# ─── Scanner API ──────────────────────────────────────────────────────────────

class Scanner:
    def __init__(self, base_url: str, container: str):
        self.base = base_url.rstrip("/")
        self.container = container

    def _req(self, method: str, path: str, body: dict | None = None, timeout: int = 60):
        data = json.dumps(body, default=str).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read() or b"{}")

    def wait_up(self, timeout: int = 300) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                self._req("GET", "/health", timeout=10)
                return
            except Exception:
                time.sleep(5)
        raise RemediationError("security scanner did not come up")

    def ensure_current_code(self) -> None:
        """src/ is bind-mounted; a plain restart loads new code if the endpoints are missing."""
        try:
            self._req("GET", "/internal/remediation-candidates")
            return
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
        log.info("Scanner is running old code — restarting %s to load it", self.container)
        sh(["docker", "restart", self.container], timeout=120)
        time.sleep(5)
        self.wait_up()

    def candidates(self) -> list[dict]:
        try:
            return self._req("GET", "/internal/remediation-candidates")["images"]
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
        # Scanner still on old code (dry runs don't restart it) — query via the mounted src
        code = ("import json; from src.db import get_remediation_candidates as g; "
                "print(json.dumps(g(), default=str))")
        return json.loads(out(["docker", "exec", self.container, "python", "-c", code]).splitlines()[-1])

    def start_run(self, started_at: datetime, status: str) -> int:
        return self._req("POST", "/internal/remediation-runs",
                         {"started_at": started_at.isoformat(), "status": status})["id"]

    def complete_run(self, run_id: int, report: dict) -> None:
        self._req("POST", f"/internal/remediation-runs/{run_id}/complete", report)

    def trigger_scan(self) -> None:
        # Wait for any in-flight scan (the lock would silently drop ours)
        for _ in range(120):
            runs = self._req("GET", "/scan/status").get("runs", [])
            if not any(r.get("status") == "running" and r.get("scan_type") == "full" for r in runs):
                break
            time.sleep(30)
        log.info("Triggering post-remediation full scan + email: %s", self._req("POST", "/scan/full?notify=true"))


# ─── Trivy (runs inside the scanner container, which has Trivy + the socket) ──

def trivy(scanner: Scanner, ref: str, ignored: set[str]) -> dict[tuple[str, str], str] | None:
    """{(cve, package): severity} for CRITICAL/HIGH, or None if the scan failed."""
    r = sh(["docker", "exec", scanner.container, "trivy", "image", "--format", "json", "--quiet",
            "--scanners", "vuln", "--ignorefile", "/app/trivyignore", ref],
           timeout=1800, check=False)
    if r.returncode not in (0, 1):
        log.warning("Trivy failed for %s: %s", ref, r.stderr.decode(errors="replace")[-300:])
        return None
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    found: dict[tuple[str, str], str] = {}
    for block in data.get("Results") or []:
        for v in block.get("Vulnerabilities") or []:
            sev = v.get("Severity")
            if sev in ("CRITICAL", "HIGH") and v.get("PkgName") not in ignored:
                found[(v["VulnerabilityID"], v["PkgName"])] = sev
    return found


def count(found: dict, sev: str) -> int:
    return sum(1 for s in found.values() if s == sev)


# ─── Version gates ────────────────────────────────────────────────────────────

def run_in_image(ref: str, cmd: str) -> str | None:
    r = sh(["docker", "run", "--rm", "--network", "none", "--entrypoint", "sh", ref, "-c", cmd],
           timeout=180, check=False)
    return r.stdout.decode(errors="replace").strip() if r.returncode == 0 else None


def parse_version(text: str | None) -> str | None:
    if not text:
        return None
    m = re.search(r"\d+(?:\.\d+)+", text) or re.search(r"RELEASE\.[\w\-]+", text)
    return m.group(0) if m else text.strip()[:80]


def jump_allowed(old: str, new: str, max_jump: str) -> bool:
    if max_jump == "any" or old == new:
        return True
    if max_jump == "none":
        return False
    try:
        o = [int(x) for x in old.split(".")]
        n = [int(x) for x in new.split(".")]
    except ValueError:
        return False
    keep = {"patch": 2, "minor": 1}[max_jump]
    return o[:keep] == n[:keep] and n >= o


# ─── Container recreate / rollback ────────────────────────────────────────────

_LAYER_STATE = re.compile(r"\.(db|sqlite|sqlite3|db\.mv\.db|mv\.db)$")


def layer_state(container: str, allowed: set[str]) -> list[str]:
    """Database-looking files that exist only in the container's writable layer."""
    diff = out(["docker", "diff", container], timeout=300, check=False)
    paths = [line[2:] for line in diff.splitlines() if line[:1] in ("A", "C")]
    return [p for p in paths if _LAYER_STATE.search(p) and p not in allowed
            and not p.startswith(("/tmp/", "/proc/", "/run/"))]


def clone_body(c: dict, old_image: dict, new_image_id: str) -> dict:
    """
    Build a /containers/create body from a running container, Watchtower-style:
    keep everything the container set explicitly, drop what it merely inherited
    from the old image so the new image's defaults (ENV, CMD, healthcheck…) apply.
    """
    cfg = copy.deepcopy(c["Config"])
    img = old_image.get("Config") or {}

    img_env = set(img.get("Env") or [])
    cfg["Env"] = [e for e in cfg.get("Env") or [] if e not in img_env]
    img_labels = img.get("Labels") or {}
    cfg["Labels"] = {k: v for k, v in (cfg.get("Labels") or {}).items() if img_labels.get(k) != v}
    if "com.docker.compose.image" in cfg["Labels"]:
        cfg["Labels"]["com.docker.compose.image"] = new_image_id
    for key in ("Cmd", "Entrypoint", "WorkingDir", "User", "Healthcheck", "StopSignal", "Shell", "OnBuild"):
        if cfg.get(key) == img.get(key):
            cfg.pop(key, None)
    for key in ("ExposedPorts", "Volumes"):
        rest = {k: v for k, v in (cfg.get(key) or {}).items() if k not in (img.get(key) or {})}
        cfg[key] = rest or None
    if cfg.get("Hostname") == c["Id"][:12]:
        cfg.pop("Hostname")
    cfg["Image"] = normalize_ref(c["Config"]["Image"])

    hc = copy.deepcopy(c["HostConfig"])
    # Anonymous volumes aren't in HostConfig — re-attach them so their data survives
    declared = {b.split(":")[1] for b in hc.get("Binds") or [] if ":" in b}
    declared |= {m.get("Target") for m in hc.get("Mounts") or []}
    for m in c.get("Mounts") or []:
        if m.get("Type") == "volume" and m["Destination"] not in declared:
            hc.setdefault("Binds", [])
            hc["Binds"] = (hc["Binds"] or []) + [f"{m['Name']}:{m['Destination']}{'' if m.get('RW', True) else ':ro'}"]

    body = {**cfg, "HostConfig": hc}
    if hc.get("NetworkMode") not in ("host", "none") and not str(hc.get("NetworkMode", "")).startswith("container:"):
        eps = {}
        for net, ep in (c["NetworkSettings"].get("Networks") or {}).items():
            eps[net] = {
                "Aliases": [a for a in ep.get("Aliases") or [] if a != c["Id"][:12]],
                "IPAMConfig": ep.get("IPAMConfig"),
                "Links": ep.get("Links"),
                "DriverOpts": ep.get("DriverOpts"),
            }
        body["NetworkingConfig"] = {"EndpointsConfig": eps}
    return body


class Journal:
    """Swaps in flight, persisted so a crashed run can be recovered next time."""

    def __init__(self, path: Path):
        self.path = path
        self.data = json.loads(path.read_text()) if path.exists() else {}

    def _save(self):
        self.path.write_text(json.dumps(self.data, indent=2))

    def add(self, name: str, entry: dict):
        self.data[name] = entry
        self._save()

    def remove(self, name: str):
        self.data.pop(name, None)
        self._save()


def swap(c: dict, old_image: dict, new_image_id: str, cfg: dict, journal: Journal) -> dict:
    name = c["Name"].lstrip("/")
    bak = name + PREV_SUFFIX
    if inspect("container", bak):
        sh(["docker", "rm", "-f", bak])
    body = clone_body(c, old_image, new_image_id)
    restart = c["HostConfig"].get("RestartPolicy", {}).get("Name") or "no"

    journal.add(name, {"bak": bak, "restart": restart})
    sh(["docker", "stop", "-t", str(cfg.get("stop_timeout", 30)), name], timeout=cfg.get("stop_timeout", 30) + 60)
    sh(["docker", "rename", name, bak])
    sh(["docker", "update", "--restart=no", bak])
    try:
        docker_create(name, body)
        for p in cfg.get("preserve_paths") or []:
            tar = sh(["docker", "cp", f"{bak}:{p}", "-"], timeout=600).stdout
            sh(["docker", "cp", "-", f"{name}:{str(Path(p).parent)}"], input_bytes=tar, timeout=600)
        sh(["docker", "start", name], timeout=120)
    except Exception:
        restore(name, bak, restart)
        journal.remove(name)
        raise
    log.info("  swapped %s → new image (old kept as %s)", name, bak)
    return {"name": name, "bak": bak, "restart": restart,
            "was_unhealthy": (c["State"].get("Health") or {}).get("Status") == "unhealthy"}


def restore(name: str, bak: str, restart: str) -> None:
    sh(["docker", "rm", "-f", name], check=False)
    sh(["docker", "rename", bak, name])
    sh(["docker", "update", f"--restart={restart}", name])
    sh(["docker", "start", name], timeout=120)


def recover_from_journal(journal: Journal) -> list[str]:
    """Undo half-finished swaps left by a crashed or killed run."""
    notes = []
    for name, entry in list(journal.data.items()):
        bak = entry["bak"]
        cur, old = inspect("container", name), inspect("container", bak)
        if old and not (cur and cur["State"]["Running"]):
            log.warning("Recovering %s from %s (previous run did not finish)", name, bak)
            restore(name, bak, entry["restart"])
            notes.append(f"recovered {name} from an unfinished previous run")
        elif old:
            sh(["docker", "rm", "-f", bak], check=False)
        journal.remove(name)
    return notes


def wait_ready(name: str, timeout: int, require_healthy: bool = True, settle: int = 20) -> tuple[bool, str]:
    deadline = time.time() + timeout
    running_since = None
    while time.time() < deadline:
        c = inspect("container", name)
        if not c:
            return False, "container disappeared"
        st = c["State"]
        if st.get("Restarting") or c.get("RestartCount", 0) > 0:
            return False, f"restarting (exit code {st.get('ExitCode')})"
        if not st.get("Running"):
            if st.get("Status") in ("exited", "dead"):
                return False, f"exited with code {st.get('ExitCode')}"
        else:
            health = (st.get("Health") or {}).get("Status")
            if health and require_healthy:
                if health == "healthy":
                    return True, "healthy"
                if health == "unhealthy":
                    return False, "healthcheck unhealthy"
            else:
                running_since = running_since or time.time()
                if time.time() - running_since >= settle:
                    return True, "running"
        time.sleep(3)
    return False, f"not ready after {timeout}s"


def container_logs(name: str, lines: int = 15) -> str:
    r = sh(["docker", "logs", "--tail", str(lines), name], check=False, timeout=30)
    return (r.stdout + r.stderr).decode(errors="replace")[-1200:]


# ─── Tests ────────────────────────────────────────────────────────────────────

def run_test(t: dict, curl_image: str, timeout: int) -> tuple[bool, str]:
    deadline = time.time() + timeout
    detail = ""
    while True:
        if t["type"] == "http":
            net = t.get("network", "core_data_net")
            r = sh(["docker", "run", "--rm", "--network", net, curl_image, "-sS", "-o", "/dev/null",
                    "-w", "%{http_code}", "--max-time", "15", t["url"]], check=False, timeout=60)
            code = r.stdout.decode().strip()
            expect = t.get("expect", [200])
            ok = (code.isdigit() and 0 < int(code) < 500) if expect == "lt500" else (code.isdigit() and int(code) in expect)
            detail = f"HTTP {code or 'no response'} from {t['url']}"
        elif t["type"] == "exec":
            r = sh(["docker", "exec", t["container"], *t["cmd"]], check=False, timeout=60)
            ok = r.returncode == 0
            detail = f"exec in {t['container']}: rc={r.returncode} {(r.stdout + r.stderr).decode(errors='replace').strip()[-160:]}"
        else:
            return False, f"unknown test type {t['type']}"
        if ok or time.time() > deadline:
            return ok, detail
        time.sleep(10)


# ─── Backups ──────────────────────────────────────────────────────────────────

def take_backups(cfg: dict, first_container: str, backup_root: Path) -> list[str]:
    day = backup_root / datetime.now().strftime("%Y-%m-%d")
    day.mkdir(parents=True, exist_ok=True)
    made = []
    for db in cfg.get("backup_pg_dbs") or []:
        dest = day / f"pg-{db}.dump"
        with dest.open("wb") as fh:
            sh(["docker", "exec", "postgres", "sh", "-c", f'pg_dump -U "$POSTGRES_USER" -Fc {db}'],
               stdout=fh, timeout=1800)
        if dest.stat().st_size == 0:
            raise RemediationError(f"pg_dump of {db} produced an empty file")
        made.append(str(dest))
    for p in cfg.get("backup_container_paths") or []:
        dest = day / f"{first_container}{p.replace('/', '_')}.tgz"
        with dest.open("wb") as fh:
            sh(["docker", "exec", first_container, "tar", "czf", "-", "-C", "/", p.lstrip("/")],
               stdout=fh, timeout=1800)
        made.append(str(dest))
    for p in cfg.get("preserve_paths") or []:
        dest = day / f"{first_container}{p.replace('/', '_')}.tar"
        with dest.open("wb") as fh:
            sh(["docker", "cp", f"{first_container}:{p}", "-"], stdout=fh, timeout=600)
        made.append(str(dest))
    return made


def prune_backups(root: Path, keep_days: int) -> None:
    cutoff = datetime.now() - timedelta(days=keep_days)
    for d in root.glob("20??-??-??"):
        try:
            if datetime.strptime(d.name, "%Y-%m-%d") < cutoff:
                sh(["rm", "-rf", str(d)])
        except ValueError:
            pass


# ─── Per-image remediation ────────────────────────────────────────────────────

def remediate_image(ref: str, containers: list[dict], cfg: dict, ctx: dict) -> dict:
    t0 = time.time()
    names = [c["Name"].lstrip("/") for c in containers]
    action = {"image_ref": ref, "image_name": ref.rsplit(":", 1)[0], "containers": names,
              "strategy": cfg.get("strategy"), "tests": []}

    def done(outcome: str, reason: str) -> dict:
        action.update(outcome=outcome, reason=reason, duration_sec=int(time.time() - t0))
        log.info("  → %s: %s", outcome.upper(), reason)
        return action

    old_id = containers[0]["Image"]
    action["old_image_id"] = old_id
    prev = prev_tag(ref)
    sh(["docker", "tag", old_id, prev])
    old_image = inspect("image", old_id)

    # 1. Refresh the image on its current tag
    try:
        if cfg["strategy"] == "pull":
            sh(["docker", "pull", "-q", ref], timeout=1800)
        else:
            b = cfg["build"]
            cmd = ["docker", "build", "--pull", "--no-cache", "-q", "-f", b["dockerfile"], "-t", ref]
            for k, v in (b.get("args") or {}).items():
                cmd += ["--build-arg", f"{k}={v}"]
            sh(cmd + [b["context"]], timeout=3600)
    except RemediationError as exc:
        sh(["docker", "tag", old_id, ref], check=False)
        return done("failed", f"{cfg['strategy']} failed: {exc}")

    new_id = inspect("image", ref)["Id"]
    action["new_image_id"] = new_id
    if new_id == old_id:
        return done("no_update", "no newer image is published for this tag" if cfg["strategy"] == "pull"
                    else "rebuild produced an identical image")

    def reject(reason: str) -> dict:
        sh(["docker", "tag", old_id, ref])
        return done("rejected", reason)

    # 2. Version gate + invariants
    if cfg.get("version_cmd"):
        action["old_version"] = parse_version(run_in_image(prev, cfg["version_cmd"]))
        action["new_version"] = parse_version(run_in_image(ref, cfg["version_cmd"]))
        max_jump = cfg.get("max_jump", "any")
        if max_jump != "any" and not (action["old_version"] and action["new_version"]):
            return reject("could not determine the image version for the version gate")
        if not jump_allowed(action["old_version"] or "", action["new_version"] or "", max_jump):
            return reject(f"upstream moved {action['old_version']} → {action['new_version']}, beyond the "
                          f"allowed '{max_jump}' jump — needs a planned upgrade")
    for icmd in cfg.get("invariant_cmds") or []:
        a, b = run_in_image(prev, icmd), run_in_image(ref, icmd)
        if a != b:
            return reject(f"invariant changed ({icmd!r}: {a!r} → {b!r})")

    # 3. Prove the new image is better
    before = trivy(ctx["scanner"], prev, ctx["ignored"])
    after = trivy(ctx["scanner"], ref, ctx["ignored"]) if before is not None else None
    if before is None or after is None:
        return reject("Trivy scan failed, so the improvement could not be verified")
    fixed = {k: s for k, s in before.items() if k not in after}
    new = {k: s for k, s in after.items() if k not in before}
    action.update(
        critical_before=count(before, "CRITICAL"), high_before=count(before, "HIGH"),
        critical_after=count(after, "CRITICAL"), high_after=count(after, "HIGH"),
        critical_fixed=count(fixed, "CRITICAL"), high_fixed=count(fixed, "HIGH"),
        fixed_cves=[{"cve": k[0], "package": k[1], "severity": s} for k, s in sorted(fixed.items())],
    )
    if not fixed:
        return reject("the refreshed image fixes none of the open CRITICAL/HIGH findings")
    if count(new, "CRITICAL"):
        return reject(f"the refreshed image introduces {count(new, 'CRITICAL')} new CRITICAL finding(s)")
    if len(after) >= len(before):
        return reject(f"no net improvement ({len(before)} → {len(after)} CRITICAL/HIGH)")

    # 4. Don't recreate containers holding state in their writable layer
    allowed = set(cfg.get("preserve_paths") or []) | set(cfg.get("ignore_layer_paths") or [])
    for c in containers:
        risky = layer_state(c["Name"].lstrip("/"), allowed)
        if risky:
            return reject(f"{c['Name'].lstrip('/')} stores data in its container layer ({', '.join(risky[:3])}); "
                          "add it to preserve_paths or move it to a volume")

    if ctx["dry_run"]:
        sh(["docker", "tag", old_id, ref])
        return done("skipped", f"dry run — would deploy, fixing {action['critical_fixed']} critical / "
                               f"{action['high_fixed']} high")

    # 5. Backups
    try:
        backups = take_backups(cfg, names[0], ctx["backup_root"])
    except RemediationError as exc:
        return reject(f"pre-swap backup failed: {exc}")

    # 6. Swap, wait, test — roll everything back on any failure
    swaps: list[dict] = []
    failure = None
    try:
        for c in containers:
            swaps.append(swap(c, old_image, new_id, cfg, ctx["journal"]))
        for s in swaps:
            ok, why = wait_ready(s["name"], cfg.get("ready_timeout", 180), require_healthy=not s["was_unhealthy"])
            action["tests"].append({"name": f"{s['name']} ready", "ok": ok, "detail": why})
            if not ok:
                failure = f"{s['name']} {why}: {container_logs(s['name'])}"
                break
        if not failure:
            for t in cfg.get("tests") or []:
                ok, detail = run_test(t, ctx["curl_image"], cfg.get("ready_timeout", 180))
                action["tests"].append({"name": t.get("url") or " ".join(t.get("cmd", [])), "ok": ok, "detail": detail})
                if not ok:
                    failure = detail
                    break
    except Exception as exc:
        failure = f"swap error: {exc}"

    if failure:
        log.warning("  test failure — rolling back: %s", failure[:300])
        rollback_problems = []
        for s in reversed(swaps):
            try:
                restore(s["name"], s["bak"], s["restart"])
                ctx["journal"].remove(s["name"])
                ok, why = wait_ready(s["name"], cfg.get("ready_timeout", 180), require_healthy=not s["was_unhealthy"])
                if not ok:
                    rollback_problems.append(f"{s['name']} {why}")
            except Exception as exc:
                rollback_problems.append(f"{s['name']}: {exc}")
        sh(["docker", "tag", old_id, ref], check=False)
        action.update(critical_fixed=0, high_fixed=0)
        reason = f"rolled back: {failure[:600]}"
        if rollback_problems:
            reason += f" | ROLLBACK PROBLEMS: {'; '.join(rollback_problems)}"
        return done("rolled_back", reason)

    for s in swaps:
        sh(["docker", "rm", s["bak"]], check=False)
        ctx["journal"].remove(s["name"])
    ver = f" ({action['old_version']} → {action['new_version']})" if action.get("old_version") else ""
    return done("deployed",
                f"{'re-pulled' if cfg['strategy'] == 'pull' else 'rebuilt'}{ver}; fixed {action['critical_fixed']} "
                f"critical / {action['high_fixed']} high; {len(new)} new high; "
                f"{len(cfg.get('tests') or [])} test(s) passed" + (f"; backups: {len(backups)}" if backups else ""))


# ─── Main ─────────────────────────────────────────────────────────────────────

def hhmm(s: str) -> tuple[int, int]:
    h, m = s.split(":")
    return int(h), int(m)


def at(now: datetime, s: str) -> datetime:
    h, m = hhmm(s)
    return now.replace(hour=h, minute=m, second=0, microsecond=0)


def snapshot_health() -> dict[str, str]:
    states = {}
    for cid in out(["docker", "ps", "-q"]).split():
        c = inspect("container", cid)
        if c:
            states[c["Name"].lstrip("/")] = (c["State"].get("Health") or {}).get("Status") or "running"
    return states


def health_sweep(before: dict[str, str]) -> list[dict]:
    """Containers that were running/healthy before the run and aren't now; one restart attempt each."""
    def degraded(now_states):
        bad = []
        for name, was in before.items():
            now = now_states.get(name, "missing")
            if now in ("missing", "unhealthy") and was != "unhealthy":
                bad.append(name)
        return bad

    time.sleep(30)
    bad = degraded(snapshot_health())
    for name in bad:
        if inspect("container", name):
            log.warning("Health sweep: restarting degraded container %s", name)
            sh(["docker", "restart", name], check=False, timeout=180)
    if bad:
        time.sleep(90)
    final = snapshot_health()
    return [{"name": n, "state": final.get(n, "missing")} for n in degraded(final)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="change nothing; report what would happen")
    ap.add_argument("--scan", action="store_true", help="with --dry-run: also pull/build + Trivy-compare")
    ap.add_argument("--only", action="append", default=[], help="limit to this image ref (repeatable)")
    ap.add_argument("--ignore-window", action="store_true", help="run outside the configured time window")
    ap.add_argument("--no-report", action="store_true", help="don't record the run or trigger the scan/email")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    conf = tomllib.loads(CONFIG_PATH.read_text())
    win, run = conf["window"], conf["runner"]
    tz = ZoneInfo(win["timezone"])
    now = datetime.now(tz)
    if not (at(now, win["start"]) <= now < at(now, win["end"])) and not args.ignore_window and not args.dry_run:
        log.error("Outside the maintenance window %s–%s %s; refusing to run", win["start"], win["end"], win["timezone"])
        return 2

    log_dir = Path(run["log_dir"])
    log_dir.mkdir(parents=True, exist_ok=True)
    lock = open(log_dir / "auto-remediate.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.error("Another auto-remediate run is in progress")
        return 3

    scanner = Scanner(run["scanner_url"], run["scanner_container"])
    journal = Journal(log_dir / "auto-remediate.journal.json")
    notes = recover_from_journal(journal) if not args.dry_run else []
    scanner.wait_up()
    if not args.dry_run:
        scanner.ensure_current_code()
    report_enabled = not args.no_report and not args.dry_run
    started_at = datetime.now(tz)
    run_id = scanner.start_run(started_at, "running") if report_enabled else None

    ctx = {
        # In a dry run remediate_image (only reached with --scan) stops right before backups/swap
        "scanner": scanner, "journal": journal, "dry_run": args.dry_run,
        "ignored": set(run.get("ignored_packages") or []), "curl_image": run["curl_image"],
        "backup_root": Path(run["backup_dir"]),
    }

    actions: list[dict] = []
    status = "dry_run" if args.dry_run else "completed"
    health_before = snapshot_health()
    try:
        if not args.dry_run and inspect("image", run["curl_image"]) is None:
            sh(["docker", "pull", "-q", run["curl_image"]], timeout=600)

        # Running containers grouped by image ref
        groups: dict[str, list[dict]] = {}
        for cid in out(["docker", "ps", "-q"]).split():
            c = inspect("container", cid)
            if c and not c["Name"].endswith(PREV_SUFFIX):
                groups.setdefault(normalize_ref(c["Config"]["Image"]), []).append(c)

        wanted = {f"{r['image_name']}:{r['image_tag']}": r for r in scanner.candidates()}
        images_conf = conf.get("images", {})
        order = [r for r in images_conf if r in groups] + sorted(r for r in groups if r not in images_conf)
        excluded = tuple(run.get("exclude") or [])

        for ref in order:
            if args.only and ref not in args.only:
                continue
            cand = wanted.get(ref)
            if not cand:
                continue  # nothing fixable on this image
            label = f"{ref} [{cand['critical']} critical / {cand['high']} high fixable]"
            cfg = images_conf.get(ref)
            base = {"image_ref": ref, "image_name": ref.rsplit(":", 1)[0],
                    "containers": [c["Name"].lstrip("/") for c in groups[ref]]}
            if ref.startswith(excluded) or not cfg or cfg.get("strategy") == "skip":
                reason = "excluded from automation" if ref.startswith(excluded) or cfg else \
                         "not listed in auto-remediate.toml"
                log.info("%s — skipped: %s", label, reason)
                actions.append({**base, "strategy": "skip", "outcome": "skipped", "reason": reason})
                continue

            now = datetime.now(tz)
            if not args.dry_run and not args.ignore_window and (
                    now >= at(now, win["last_start"])
                    or now + timedelta(minutes=cfg.get("est_minutes", 10)) > at(now, win["finish_by"])):
                log.info("%s — deferred: not enough time left in the window", label)
                actions.append({**base, "strategy": cfg["strategy"], "outcome": "skipped",
                                "reason": "deferred to tomorrow night — not enough time left in the window"})
                continue

            log.info("%s — %s (%s)", label, cfg["strategy"], ", ".join(base["containers"]))
            if args.dry_run and not args.scan:
                actions.append({**base, "strategy": cfg["strategy"], "outcome": "skipped",
                                "reason": f"dry run — would {cfg['strategy']} (~{cfg.get('est_minutes', 10)} min)"})
                continue
            try:
                actions.append(remediate_image(ref, groups[ref], cfg, ctx))
            except Exception as exc:
                log.exception("Unexpected error remediating %s", ref)
                actions.append({**base, "strategy": cfg["strategy"], "outcome": "failed", "reason": str(exc)[:500]})
                status = "partial"
    except Exception as exc:
        log.exception("Auto-remediation run failed")
        notes.append(f"run aborted: {exc}")
        status = "failed"
    finally:
        sweep = health_sweep(health_before) if not args.dry_run else []
        if sweep:
            log.warning("Health sweep — still degraded: %s", sweep)
        if not args.dry_run:
            prune_backups(ctx["backup_root"], run.get("backup_keep_days", 14))

        dep = [a for a in actions if a.get("outcome") == "deployed"]
        log.info("Done: %d deployed, %d rolled back, %d rejected/no-update, fixed %d critical / %d high",
                 len(dep), sum(a.get("outcome") == "rolled_back" for a in actions),
                 sum(a.get("outcome") in ("rejected", "no_update") for a in actions),
                 sum(a.get("critical_fixed", 0) for a in dep), sum(a.get("high_fixed", 0) for a in dep))
        if args.dry_run:
            for a in actions:
                print(f"  {a['outcome']:<10} {a['image_ref']:<50} {a.get('reason', '')}")
        if report_enabled:
            try:
                scanner.wait_up()
                scanner.complete_run(run_id, {"completed_at": datetime.now(tz).isoformat(), "status": status,
                                              "actions": actions, "health_sweep": sweep,
                                              "notes": "; ".join(notes) or None})
                scanner.trigger_scan()
            except Exception:
                log.exception("Could not report to the security scanner")
                status = "failed"
    return 0 if status in ("completed", "dry_run") else 1


if __name__ == "__main__":
    sys.exit(main())
