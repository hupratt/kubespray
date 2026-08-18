#!/usr/bin/env python3
"""
ansible_dep_inventory.py

Scans an Ansible repo (playbooks, roles, templates) for:
  - container image references (docker_container, k8s manifests,
    docker-compose files/templates, Dockerfiles, raw "image:" keys)
  - Helm chart references (kubernetes.core.helm module, or raw
    `helm install/upgrade --version X` shell/command tasks)

Builds a deduplicated inventory and, optionally, checks each entry
against its upstream registry/chart repo to flag outdated versions.

Features:
  - Strict x86/amd64 semver tag evaluation (discards non-version floating 
    tags like 'amd64', 'latest', 'stable' as recommended versions).
  - Best-effort Jinja2 variable resolution pass.
  - OCI v2 Registry & Helm index.yaml support.

Requirements:
  - Python 3.8+
  - stdlib only for the inventory scan
  - PyYAML only needed for --check-updates on Helm charts
"""

import argparse
import json
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

try:
    import yaml  # needed for helm index.yaml parsing
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False


# --------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------

@dataclass
class ImageRef:
    repo: str
    tag: str
    sources: set = field(default_factory=set)
    latest: Optional[str] = None
    outdated: Optional[bool] = None
    check_error: Optional[str] = None


@dataclass
class HelmRef:
    chart: str
    version: str
    repo_url: Optional[str] = None
    sources: set = field(default_factory=set)
    latest: Optional[str] = None
    outdated: Optional[bool] = None
    check_error: Optional[str] = None


# --------------------------------------------------------------------------
# File discovery
# --------------------------------------------------------------------------

SCAN_EXTENSIONS = {".yml", ".yaml", ".j2"}
DOCKERFILE_NAMES = {"Dockerfile"}

DEFAULT_SKIP_DIRS = {
    ".git", ".venv", "venv", "env", "node_modules", ".terraform", "__pycache__",
    ".tox", "site-packages", "molecule", "tests", "test", ".github", "docs",
    "changelogs", ".ansible", "ansible_collections", "collections",
}


def discover_files(root: Path, skip_dirs: set):
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if any(part in skip_dirs for part in p.parts):
            continue
        if p.suffix in SCAN_EXTENSIONS or p.name in DOCKERFILE_NAMES or p.name.endswith(".yml.j2") or p.name.endswith(".yaml.j2"):
            yield p


# --------------------------------------------------------------------------
# Best-effort variable resolution
# --------------------------------------------------------------------------

VAR_ASSIGN_RE = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*["\']?([^"\'{}\n#]+?)["\']?\s*(?:#.*)?$')
JINJA_VAR_RE = re.compile(r'\{\{\s*([A-Za-z0-9_.]+)\s*(?:\|[^}]*)?\s*\}\}')


def build_var_map(files):
    var_map = {}
    for f in files:
        try:
            text = f.read_text(errors="ignore")
        except Exception:
            continue
        for line in text.splitlines():
            m = VAR_ASSIGN_RE.match(line)
            if m:
                name, value = m.group(1), m.group(2).strip()
                if value and "{{" not in value:
                    var_map[name] = value
    return var_map


def resolve_jinja(value: str, var_map: dict) -> str:
    if "{{" not in value:
        return value

    def repl(m):
        expr = m.group(1)
        base = expr.split(".")[0]
        return var_map.get(base, m.group(0))

    resolved = JINJA_VAR_RE.sub(repl, value)
    if "{{" in resolved:
        return f"unresolved:{resolved.strip()}"
    return resolved


# --------------------------------------------------------------------------
# Extraction patterns
# --------------------------------------------------------------------------

IMAGE_LINE_RE = re.compile(r'^\s*(?:-\s*)?(?:image|docker_image)\s*:\s*(.+)$')
FROM_LINE_RE = re.compile(r'^\s*FROM\s+(\S+)', re.IGNORECASE)

CHART_REF_RE = re.compile(r'^\s*chart_ref\s*:\s*(.+)$')
CHART_VERSION_RE = re.compile(r'^\s*chart_version\s*:\s*(.+)$')
CHART_REPO_URL_RE = re.compile(r'^\s*chart_repo_url\s*:\s*(.+)$')


def _clean_value(raw: str) -> str:
    v = raw.strip()
    if "{{" not in v or "}}" in v.split("#")[0]:
        v = re.sub(r'\s+#.*$', '', v)
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        v = v[1:-1]
    return v.strip()


HELM_CLI_RE = re.compile(
    r'helm\s+(?:install|upgrade)\s+(?:--install\s+)?(?:\S+\s+)?([^\s]+)\s+[^\n]*?--version[= ]([^\s"\'\\]+)'
)
HELM_CLI_REPO_RE = re.compile(r'--repo[= ]([^\s"\'\\]+)')


def split_image_tag(ref: str):
    if "@sha256:" in ref:
        repo, digest = ref.split("@", 1)
        return repo, f"@{digest}"
    last_slash = ref.rfind("/")
    last_colon = ref.rfind(":")
    if last_colon > last_slash:
        return ref[:last_colon], ref[last_colon + 1:]
    return ref, "latest"


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------

_COMPONENT = r'[a-z0-9]+(?:[._-]+[a-z0-9]+)*'
STRICT_IMAGE_RE = re.compile(rf'^{_COMPONENT}(?::[0-9]+)?(?:/{_COMPONENT})*$')

FQCN_PREFIXES = {
    "ansible", "community", "amazon", "google", "kubernetes", "azure",
    "cisco", "junipernetworks", "arista", "f5networks", "netapp",
    "purestorage", "vmware", "fortinet", "theforeman", "servicenow",
    "splunk", "sensu", "datadog", "grafana", "module_utils",
    "ansible_collections", "ansible-core",
}

IMAGE_STOPWORDS = {
    "a", "an", "the", "this", "that", "other", "one", "any", "ambiguous",
    "passing", "parent", "result", "task", "scripts", "snapshot",
    "inventory", "logging", "monitoring", "collection", "configuration",
    "options", "false", "true", "docker",
}


def is_valid_image_repo(repo: str) -> bool:
    if not repo:
        return False
    r = repo.strip()
    if not r or r != repo:
        return False
    if not STRICT_IMAGE_RE.match(r):
        return False
    first = r.split("/", 1)[0].split(":", 1)[0]
    if "/" not in r and first.split(".")[0] in FQCN_PREFIXES:
        return False
    if "/" not in r and r in IMAGE_STOPWORDS:
        return False
    return True


CHART_NAME_RE = re.compile(rf'^{_COMPONENT}(?:/{_COMPONENT})?$')


def is_valid_chart(chart: str, version: str) -> bool:
    if not chart or not CHART_NAME_RE.match(chart):
        return False
    if not version or version.startswith("unresolved"):
        return False
    if not re.search(r'\d', version):
        return False
    return True


def scan_file(path: Path, var_map: dict, images: dict, helms: dict, stats: dict):
    try:
        text = path.read_text(errors="ignore")
    except Exception:
        return

    lines = text.splitlines()
    pending_chart_ref = None
    pending_chart_version = None
    pending_repo_url = None

    for line in lines:
        m = IMAGE_LINE_RE.match(line)
        if m:
            raw = resolve_jinja(_clean_value(m.group(1)), var_map)
            stats["images_seen"] += 1
            if raw.startswith("unresolved:"):
                repo, tag = "unresolved", raw[len("unresolved:"):]
                key = (repo, tag)
                entry = images.setdefault(key, ImageRef(repo=repo, tag=tag))
                entry.sources.add(str(path))
                continue
            repo, tag = split_image_tag(raw)
            if is_valid_image_repo(repo):
                key = (repo, tag)
                entry = images.setdefault(key, ImageRef(repo=repo, tag=tag))
                entry.sources.add(str(path))
            else:
                stats["images_rejected"] += 1
            continue

        m = FROM_LINE_RE.match(line)
        if m:
            raw = resolve_jinja(_clean_value(m.group(1)), var_map)
            if raw.lower() == "scratch":
                continue
            stats["images_seen"] += 1
            if raw.startswith("unresolved:"):
                repo, tag = "unresolved", raw[len("unresolved:"):]
                key = (repo, tag)
                entry = images.setdefault(key, ImageRef(repo=repo, tag=tag))
                entry.sources.add(str(path))
                continue
            repo, tag = split_image_tag(raw)
            if is_valid_image_repo(repo):
                key = (repo, tag)
                entry = images.setdefault(key, ImageRef(repo=repo, tag=tag))
                entry.sources.add(str(path))
            else:
                stats["images_rejected"] += 1
            continue

        m = CHART_REF_RE.match(line)
        if m:
            pending_chart_ref = resolve_jinja(_clean_value(m.group(1)), var_map)
        m = CHART_VERSION_RE.match(line)
        if m:
            pending_chart_version = resolve_jinja(_clean_value(m.group(1)), var_map)
        m = CHART_REPO_URL_RE.match(line)
        if m:
            pending_repo_url = resolve_jinja(_clean_value(m.group(1)), var_map)

        if pending_chart_ref and pending_chart_version:
            stats["helms_seen"] += 1
            if is_valid_chart(pending_chart_ref, pending_chart_version):
                key = (pending_chart_ref, pending_chart_version)
                entry = helms.setdefault(key, HelmRef(chart=pending_chart_ref, version=pending_chart_version, repo_url=pending_repo_url))
                entry.sources.add(str(path))
            else:
                stats["helms_rejected"] += 1
            pending_chart_ref = pending_chart_version = pending_repo_url = None

        m = HELM_CLI_RE.search(line)
        if m:
            chart_raw = resolve_jinja(m.group(1), var_map)
            version_raw = resolve_jinja(m.group(2), var_map)
            chart = chart_raw.rsplit("/", 1)[-1] if "/" in chart_raw and not chart_raw.startswith("http") else chart_raw
            repo_m = HELM_CLI_REPO_RE.search(line)
            repo_url = resolve_jinja(repo_m.group(1), var_map) if repo_m else None
            stats["helms_seen"] += 1
            if is_valid_chart(chart, version_raw):
                key = (chart, version_raw)
                entry = helms.setdefault(key, HelmRef(chart=chart, version=version_raw, repo_url=repo_url))
                entry.sources.add(str(path))
            else:
                stats["helms_rejected"] += 1


# --------------------------------------------------------------------------
# Version comparison & Architecture filtering helpers
# --------------------------------------------------------------------------

NUMERIC_VER_RE = re.compile(r'\d+(?:\.\d+)+')  # Requires at least major.minor (e.g. 1.2 or 1.2.3)

NON_X86_KEYWORDS = {
    "arm64", "aarch64", "armv7", "armv7l", "armv6", "armv6l", "arm",
    "ppc64le", "s390x", "riscv64", "mips", "mips64", "386", "i386"
}

X86_KEYWORDS = {"amd64", "x86_64", "x86-64", "x64"}

# Generic floating/alias tags to ignore during version lookup
NON_VERSION_TAGS = {"latest", "stable", "main", "master", "edge", "nightly", "amd64", "arm64"}


def is_x86_compatible_tag(tag: str) -> bool:
    """Ensure tag contains numeric semver and excludes non-x86 architectures."""
    t_lower = tag.lower()

    if t_lower in NON_VERSION_TAGS:
        return False

    # Must contain at least major.minor version digits
    if not NUMERIC_VER_RE.search(t_lower):
        return False

    # Exclude non-x86 tags
    parts = re.split(r'[-_./~+]', t_lower)
    if any(p in NON_X86_KEYWORDS for p in parts):
        return False

    return True


def version_tuple(v: str):
    m = NUMERIC_VER_RE.search(v)
    if not m:
        return None
    return tuple(int(x) for x in m.group(0).split("."))


def pick_latest(tags, current, filter_x86: bool = True):
    """Return highest semver-ish x86 tag from registry candidates."""
    cur_t = version_tuple(current)
    candidates = []

    current_has_x86_suffix = any(k in current.lower() for k in X86_KEYWORDS)

    for t in tags:
        if filter_x86 and not is_x86_compatible_tag(t):
            continue

        tv = version_tuple(t)
        if tv is None:
            continue

        t_has_x86_suffix = any(k in t.lower() for k in X86_KEYWORDS)
        priority = 1 if (current_has_x86_suffix == t_has_x86_suffix) else 0

        candidates.append((tv, priority, t))

    if not candidates:
        return None

    candidates.sort(key=lambda x: (x[0], x[1]))
    best_tuple, _, best_tag = candidates[-1]

    # If current image uses a non-version string tag (e.g. "latest"), recommend best semver tag
    if cur_t is None:
        return best_tag

    if best_tuple <= cur_t:
        return None  # already up to date

    return best_tag


# --------------------------------------------------------------------------
# Registry / chart repo lookups
# --------------------------------------------------------------------------

def http_get(url, headers=None, timeout=15):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(), dict(resp.getheaders())


def get_docker_tags(repo: str):
    if "/" in repo and "." in repo.split("/")[0]:
        host = repo.split("/")[0]
        image_path = repo[len(host) + 1:]
    else:
        host = "registry-1.docker.io"
        image_path = repo if "/" in repo else f"library/{repo}"

    tags_url = f"https://{host}/v2/{image_path}/tags/list"

    headers = {}
    try:
        body, _ = http_get(tags_url, headers=headers)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            www_auth = e.headers.get("WWW-Authenticate", "")
            realm_m = re.search(r'realm="([^"]+)"', www_auth)
            service_m = re.search(r'service="([^"]+)"', www_auth)
            if not realm_m:
                raise
            realm = realm_m.group(1)
            service = service_m.group(1) if service_m else ""
            token_url = f"{realm}?service={service}&scope=repository:{image_path}:pull"
            token_body, _ = http_get(token_url)
            token = json.loads(token_body).get("token") or json.loads(token_body).get("access_token")
            headers["Authorization"] = f"Bearer {token}"
            body, _ = http_get(tags_url, headers=headers)
        else:
            raise
    data = json.loads(body)
    return data.get("tags", [])


def get_helm_latest(chart: str, repo_url: str):
    if not HAVE_YAML:
        return None, "pyyaml not installed"
    if not repo_url:
        return None, "no repo_url known for this chart"
    index_url = repo_url.rstrip("/") + "/index.yaml"
    try:
        body, _ = http_get(index_url)
    except Exception as e:
        return None, f"fetch failed: {e}"
    try:
        idx = yaml.safe_load(body)
    except Exception as e:
        return None, f"parse failed: {e}"
    entries = idx.get("entries", {})
    versions = entries.get(chart)
    if not versions:
        for k in entries:
            if k.endswith(chart) or chart.endswith(k):
                versions = entries[k]
                break
    if not versions:
        return None, "chart not found in index"
    vers = [v.get("version") for v in versions if v.get("version")]
    latest = pick_latest(vers, "0", filter_x86=False)
    return (latest or vers[0] if vers else None), None


def check_updates(images: dict, helms: dict, delay: float, filter_x86: bool):
    print("Checking for updates (network calls, this can take a bit)...", file=sys.stderr)
    for entry in images.values():
        if entry.repo == "unresolved" or entry.tag.startswith("@sha256"):
            entry.check_error = "cannot check: unresolved or digest-pinned"
            continue
        try:
            tags = get_docker_tags(entry.repo)
            latest = pick_latest(tags, entry.tag, filter_x86=filter_x86)
            entry.latest = latest
            entry.outdated = latest is not None
        except Exception as e:
            entry.check_error = str(e)
        time.sleep(delay)

    for entry in helms.values():
        latest, err = get_helm_latest(entry.chart, entry.repo_url)
        if err:
            entry.check_error = err
        else:
            entry.latest = latest
            entry.outdated = (
                latest is not None 
                and version_tuple(latest) 
                and version_tuple(entry.version) 
                and version_tuple(latest) > version_tuple(entry.version)
            )
        time.sleep(delay)


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def to_rows(images: dict, helms: dict):
    rows = []
    for e in sorted(images.values(), key=lambda x: x.repo):
        rows.append({
            "type": "image",
            "name": e.repo,
            "current": e.tag,
            "latest": e.latest or "",
            "outdated": bool(e.outdated),
            "status": e.check_error or ("outdated" if e.outdated else ("up to date" if e.latest is not None or e.outdated is False else "")),
            "sources": sorted(e.sources),
        })
    for e in sorted(helms.values(), key=lambda x: x.chart):
        rows.append({
            "type": "helm",
            "name": e.chart,
            "current": e.version,
            "latest": e.latest or "",
            "outdated": bool(e.outdated),
            "status": e.check_error or ("outdated" if e.outdated else ("up to date" if e.check_error is None else "")),
            "sources": sorted(e.sources),
        })
    return rows


def print_table(rows, show_sources=True):
    if not rows:
        print("No images or helm charts found.")
        return
    w_type = max(len("type"), max(len(r["type"]) for r in rows))
    w_name = max(len("name"), max(len(r["name"]) for r in rows))
    w_cur = max(len("current"), max(len(r["current"]) for r in rows))
    w_lat = max(len("latest"), max(len(r["latest"]) for r in rows))
    header = f'{"type":<{w_type}}  {"name":<{w_name}}  {"current":<{w_cur}}  {"latest":<{w_lat}}  flag'
    print(header)
    print("-" * len(header))
    for r in rows:
        flag = "OUTDATED" if r["outdated"] else (r["status"] if r["status"] and r["status"] not in ("up to date",) else "")
        print(f'{r["type"]:<{w_type}}  {r["name"]:<{w_name}}  {r["current"]:<{w_cur}}  {r["latest"]:<{w_lat}}  {flag}')
        if show_sources:
            first = r["sources"][0] if r["sources"] else "?"
            extra = f" (+{len(r['sources'])-1} more)" if len(r["sources"]) > 1 else ""
            print(f'{"":<{w_type}}  \u2514\u2500 {first}{extra}')


def to_markdown(rows):
    lines = ["| Type | Name | Current | Latest | Status | Sources |",
             "|---|---|---|---|---|---|"]
    for r in rows:
        status = "**OUTDATED**" if r["outdated"] else (r["status"] or "ok")
        srcs = "<br>".join(r["sources"][:3]) + (f" (+{len(r['sources'])-3} more)" if len(r["sources"]) > 3 else "")
        lines.append(f'| {r["type"]} | {r["name"]} | {r["current"]} | {r["latest"]} | {status} | {srcs} |')
    return "\n".join(lines)


def to_csv(rows):
    import csv
    import io
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["type", "name", "current", "latest", "outdated", "status", "sources"])
    for r in rows:
        w.writerow([r["type"], r["name"], r["current"], r["latest"], r["outdated"], r["status"], ";".join(r["sources"])])
    return buf.getvalue()


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Build a container image / Helm chart inventory from an Ansible repo.")
    ap.add_argument("--path", default=".", help="Path to the Ansible repo root (default: current dir)")
    ap.add_argument("--check-updates", action="store_true", help="Query registries/chart repos for newer versions")
    ap.add_argument("--output", choices=["table", "json", "md", "csv"], default="table")
    ap.add_argument("--output-file", default=None, help="Write output to this file instead of stdout")
    ap.add_argument("--delay", type=float, default=0.3, help="Delay between network calls in seconds (default 0.3)")
    ap.add_argument("--exclude", action="append", default=[], help="Additional directory name to exclude (repeatable)")
    ap.add_argument("--no-default-excludes", action="store_true",
                     help="Don't skip molecule/tests/docs/collections/etc — scan everything")
    ap.add_argument("--no-sources", action="store_true", help="Hide the source-file line under each table row")
    ap.add_argument("--x86-only", dest="x86_only", action="store_true", default=True,
                     help="Only evaluate x86/amd64 compatible tags during update checks (default)")
    ap.add_argument("--no-x86-only", dest="x86_only", action="store_false",
                     help="Include all architecture tags when evaluating updates")
    args = ap.parse_args()

    root = Path(args.path).resolve()
    if not root.exists():
        print(f"Path not found: {root}", file=sys.stderr)
        sys.exit(1)

    skip_dirs = set() if args.no_default_excludes else set(DEFAULT_SKIP_DIRS)
    skip_dirs |= set(args.exclude)

    files = list(discover_files(root, skip_dirs))
    if not files:
        print(f"No .yml/.yaml/.j2/Dockerfile files found under {root} (after excludes: {sorted(skip_dirs)})", file=sys.stderr)
        sys.exit(1)

    var_map = build_var_map(files)

    images: dict = {}
    helms: dict = {}
    stats = {"images_seen": 0, "images_rejected": 0, "helms_seen": 0, "helms_rejected": 0}
    for f in files:
        scan_file(f, var_map, images, helms, stats)

    print(
        f"Scanned {len(files)} files under {root} "
        f"(excluded dirs: {', '.join(sorted(skip_dirs)) or 'none'})",
        file=sys.stderr,
    )
    print(
        f"Images: {len(images)} kept, {stats['images_rejected']} rejected as not real image refs "
        f"(out of {stats['images_seen']} candidate lines). "
        f"Helm: {len(helms)} kept, {stats['helms_rejected']} rejected "
        f"(out of {stats['helms_seen']} candidates).",
        file=sys.stderr,
    )

    if args.check_updates:
        check_updates(images, helms, args.delay, filter_x86=args.x86_only)

    rows = to_rows(images, helms)

    if args.output == "table":
        print_table(rows, show_sources=not args.no_sources)
        if args.output_file:
            import contextlib, io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                print_table(rows, show_sources=not args.no_sources)
            Path(args.output_file).write_text(buf.getvalue())
        return
    elif args.output == "json":
        out = json.dumps(rows, indent=2)
    elif args.output == "md":
        out = to_markdown(rows)
    elif args.output == "csv":
        out = to_csv(rows)

    if args.output_file:
        Path(args.output_file).write_text(out)
        print(f"Wrote {args.output_file}", file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    main()