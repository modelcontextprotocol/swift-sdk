"""Builds the interop report from the JSONL files of scripts/run-interop.sh.

    python3 interop/report.py <results-dir> > report.md
    python3 interop/report.py <results-dir> --expect interop/RESULTS.md > report.md

Each file is named <client>__<server>__<transport>__<era>[__<profile>].jsonl
(no profile: the basic battery or one example tool call), with the client's
exit status in <cell>.exit; the run script writes the exit status of each
example client to <name>.status.

A cell fails when a check fails, and also when it has no meta line or no
checks, or when the client exited with an error without reporting a failed
check (a crash, or the time limit). An example client fails when its exit
status is not 0.

With --expect, the report's table rows are compared with those of a recorded
report: every cell's counts, every example client's exit status, and every
failing check (without its detail text, which carries timings). Any
difference is printed to stderr and the exit status is 1.
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

SDKS = {"swift": "Swift", "go": "Go", "python": "Python"}
PROFILES = ["basic", "advanced", "connect", "session"]


def escape(value: object) -> str:
    """Peer-derived text as one Markdown table cell, without markup."""
    text = " ".join(str(value).split())
    for char, replacement in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;")):
        text = text.replace(char, replacement)
    for char in "\\|[]`*_":
        text = text.replace(char, "\\" + char)
    return text


def sdk_of(name: str) -> str:
    return name.split("-")[0]


def load(path: Path) -> tuple[dict | None, list[dict]]:
    meta: dict | None = None
    checks: list[dict] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "meta" in obj:
            meta = obj["meta"]
        elif "check" in obj:
            checks.append(obj)
    return meta, checks


def main() -> None:
    args = sys.argv[1:]
    expect: Path | None = None
    if "--expect" in args:
        i = args.index("--expect")
        expect = Path(args[i + 1])
        del args[i : i + 2]
    root = Path(args[0])
    cells = []
    for path in sorted(root.glob("*.jsonl")):
        parts = path.stem.split("__")
        client, server, transport, era = parts[:4]
        profile = parts[4] if len(parts) > 4 else "basic"
        meta, checks = load(path)
        exit_path = path.with_suffix(".exit")
        status = exit_path.read_text().strip() if exit_path.exists() else "missing"
        if meta is None:
            checks.append({"check": "run", "status": "fail", "detail": f"no meta line (exit status {status})"})
        elif not checks:
            checks.append({"check": "run", "status": "fail", "detail": f"no checks (exit status {status})"})
        elif status != "0" and not any(c.get("status") == "fail" for c in checks):
            checks.append({"check": "run", "status": "fail", "detail": f"exit status {status}"})
        cells.append((profile, client, server, transport, era, meta or {}, checks))
    cells.sort(key=lambda cell: PROFILES.index(cell[0]) if cell[0] in PROFILES else len(PROFILES))

    out: list[str] = []
    w = out.append
    for profile in PROFILES:
        rows = [cell for cell in cells if cell[0] == profile]
        if not rows:
            continue
        if out:
            w("")
        w(f"Profile `{profile}`:")
        w("")
        w("| Client | Server | Transport | Era | Negotiated | Pass | Fail | Skip |")
        w("|---|---|---|---|---|---|---|---|")
        for _, client, server, transport, era, meta, checks in rows:
            counts = defaultdict(int)
            for c in checks:
                counts[c.get("status")] += 1
            control = " (control)" if sdk_of(client) == sdk_of(server) else ""
            w(
                f"| {client}{control} | {server} | {transport} | {era} | {escape(meta.get('protocolVersion', '-'))} "
                f"| {counts['pass']} | {counts['fail']} | {counts['skip']} |"
            )

    statuses = sorted(root.glob("*.status"))
    if statuses:
        w("")
        w("Example clients (exit status 0 is success):")
        w("")
        w("| Example | Exit status |")
        w("|---|---|")
        for path in statuses:
            w(f"| {path.stem} | {path.read_text().strip()} |")

    failures = [
        (profile, client, server, transport, era, c)
        for profile, client, server, transport, era, _, checks in cells
        for c in checks
        if c.get("status") == "fail"
    ]
    for path in statuses:
        status = path.read_text().strip()
        if status != "0":
            client, _, server = path.stem.partition("__")
            failures.append(("example", client, server, "-", "-", {"check": "exit", "detail": f"exit status {status}"}))
    w("")
    if not failures:
        w("No failures.")
    else:
        w("Failures:")
        w("")
        w("| Profile | Client | Server | Transport | Era | Check | Detail |")
        w("|---|---|---|---|---|---|---|")
        for profile, client, server, transport, era, c in failures:
            detail = escape(str(c.get("detail", ""))[:200])
            w(f"| {profile} | {client} | {server} | {transport} | {era} | {escape(c.get('check', '?'))} | {detail} |")
    print("\n".join(out))
    if expect is not None and not matches(out, expect.read_text().splitlines(), expect):
        sys.exit(1)


def table_rows(lines: list[str]) -> list[str]:
    """The comparable rows of a report: table rows under their heading, minus
    header and separator rows, and minus the detail column of failure rows."""
    rows: list[str] = []
    heading = ""
    for line in lines:
        if line and not line.startswith("|"):
            heading = line
            continue
        if not line.startswith("|") or line.startswith("|---"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells[0] in ("Client", "Example", "Profile"):
            continue
        if heading.startswith("Failures"):
            cells = cells[:6]
        rows.append(f"{heading} " + " | ".join(cells))
    return rows


def matches(report: list[str], expected: list[str], path: Path) -> bool:
    got, want = table_rows(report), table_rows(expected)
    missing = [row for row in want if row not in got]
    unexpected = [row for row in got if row not in want]
    if not missing and not unexpected:
        print(f"interop: matches {path}", file=sys.stderr)
        return True
    print(f"interop: differs from {path}", file=sys.stderr)
    for row in missing:
        print(f"  - {row}", file=sys.stderr)
    for row in unexpected:
        print(f"  + {row}", file=sys.stderr)
    return False


if __name__ == "__main__":
    main()
