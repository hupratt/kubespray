"""
inventory_to_md.py

Converts the JSON output of ansible_dep_inventory.py into a readable
Markdown report: separate tables for container images and Helm charts,
outdated entries flagged and sorted to the top, source files collapsed
into a <details> block so the table stays scannable.

Usage:
  python inventory_to_md.py --input inventory.json --output-file INVENTORY.md
  python inventory_to_md.py --input inventory.json                 # prints to stdout
  python inventory_to_md.py --input inventory.json --strip-prefix /home/hugo/Documents/Dev/kubespray/homelab_playbooks
  python inventory_to_md.py --input inventory.json --no-strip      # keep full paths as-is
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone


def status_flag(row):
    if row.get("outdated"):
        return "\u26a0\ufe0f **outdated**"
    status = (row.get("status") or "").strip()
    if not status or status == "up to date":
        return "\u2705 up to date"
    # anything else (HTTP errors, "no repo_url known", "cannot check: ...",
    # "chart not found in index", etc.) — surface it plainly, don't guess
    return f"\u2753 {status}"


def shorten(path: str, prefix: str) -> str:
    if prefix and path.startswith(prefix):
        path = path[len(prefix):].lstrip("/")
    return path or "."


def sources_cell(sources, prefix):
    sources = sources or []
    shortened = [shorten(s, prefix) for s in sources]
    if not shortened:
        return ""
    if len(shortened) == 1:
        return f"`{shortened[0]}`"
    first = f"`{shortened[0]}`"
    rest = "".join(f"<li><code>{s}</code></li>" for s in shortened[1:])
    return (
        f"{first} <details><summary>+{len(shortened) - 1} more</summary>"
        f"<ul>{rest}</ul></details>"
    )


def detect_common_prefix(rows):
    paths = [s for r in rows for s in (r.get("sources") or [])]
    if not paths:
        return ""
    try:
        common = os.path.commonpath(paths)
    except ValueError:
        return ""
    # only strip down to a directory, and only if it's more than just "/"
    if common in ("/", ""):
        return ""
    return common


def build_table(rows, prefix):
    if not rows:
        return "_None found._\n"
    # outdated first, then name, then current version, for stable readable order
    rows = sorted(rows, key=lambda r: (not r.get("outdated"), r.get("name", ""), r.get("current", "")))
    lines = [
        "| Name | Current | Latest | Status | Source(s) |",
        "|---|---|---|---|---|",
    ]
    for r in rows:
        name = r.get("name", "")
        current = r.get("current", "") or ""
        latest = r.get("latest", "") or "\u2014"
        flag = status_flag(r)
        srcs = sources_cell(r.get("sources"), prefix)
        # escape pipe characters that would break table cells
        name = name.replace("|", "\\|")
        current = current.replace("|", "\\|")
        latest = latest.replace("|", "\\|")
        lines.append(f"| `{name}` | `{current}` | `{latest}` | {flag} | {srcs} |")
    return "\n".join(lines) + "\n"


def build_report(data, prefix, title):
    images = [r for r in data if r.get("type") == "image"]
    helms = [r for r in data if r.get("type") == "helm"]

    n_img_outdated = sum(1 for r in images if r.get("outdated"))
    n_helm_outdated = sum(1 for r in helms if r.get("outdated"))
    n_img_unknown = sum(1 for r in images if not r.get("outdated") and (r.get("status") or "") not in ("", "up to date"))
    n_helm_unknown = sum(1 for r in helms if not r.get("outdated") and (r.get("status") or "") not in ("", "up to date"))

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    parts = [
        f"# {title}",
        "",
        f"_Generated {generated}_",
        "",
        f"- **{len(images)}** container images tracked \u2014 {n_img_outdated} outdated, {n_img_unknown} unchecked/unknown",
        f"- **{len(helms)}** Helm charts tracked \u2014 {n_helm_outdated} outdated, {n_helm_unknown} unchecked/unknown",
        "",
        "## Container Images",
        "",
        build_table(images, prefix),
        "## Helm Charts",
        "",
        build_table(helms, prefix),
    ]
    return "\n".join(parts)


def main():
    ap = argparse.ArgumentParser(description="Convert ansible_dep_inventory.py JSON into a Markdown report.")
    ap.add_argument("--input", required=True, help="Path to the inventory JSON file")
    ap.add_argument("--output-file", default=None, help="Write Markdown here instead of stdout")
    ap.add_argument("--strip-prefix", default=None, help="Common path prefix to strip from source file paths")
    ap.add_argument("--no-strip", action="store_true", help="Don't auto-detect/strip a common path prefix")
    ap.add_argument("--title", default="Dependency Inventory", help="Report title (H1)")
    args = ap.parse_args()

    try:
        with open(args.input, "r") as f:
            data = json.load(f)
    except Exception as e:
        print(f"Failed to read {args.input}: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(data, list):
        print("Expected a JSON array of rows (the --output json format from ansible_dep_inventory.py)", file=sys.stderr)
        sys.exit(1)

    if args.no_strip:
        prefix = ""
    elif args.strip_prefix is not None:
        prefix = args.strip_prefix
    else:
        prefix = detect_common_prefix(data)

    report = build_report(data, prefix, args.title)

    if args.output_file:
        with open(args.output_file, "w") as f:
            f.write(report)
        print(f"Wrote {args.output_file}", file=sys.stderr)
    else:
        print(report)


if __name__ == "__main__":
    main()