#!/usr/bin/env python3
"""Execute consumer checks and persist observed, SHA-addressed evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


SCHEMA_VERSION = 2


def git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def repository_identity(root: Path) -> str:
    """Return owner/repository from origin, independent of a worktree folder."""
    remote = git(root, "config", "--get", "remote.origin.url", check=False).rstrip("/")
    if not remote:
        return root.name
    if "://" in remote:
        path = urlparse(remote).path
    elif ":" in remote:
        path = remote.rsplit(":", 1)[1]
    else:
        path = remote
    identity = path.strip("/")
    return identity[:-4] if identity.endswith(".git") else identity


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(value: dt.datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def evidence_directory(root: Path) -> Path:
    common = Path(git(root, "rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = root / common
    return common.resolve() / "geome7ric-agentic" / "evidence"


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(content)
        temporary = Path(handle.name)
    temporary.replace(path)


def render_markdown(report: dict[str, Any]) -> str:
    passed = report["status"] == "passed"
    lines = [
        "# Geome7ric Agentic — evidencia de gate local",
        "",
        f"- Estado: `{'passed' if passed else 'failed'}`",
        f"- Repositorio: `{report['repository']}`",
        f"- Branch: `{report['branch']}`",
        f"- SHA: `{report['sha']}`",
        f"- Tree: `{report['tree']}`",
        f"- Capa: `v{report['agenticVersion']}`",
        f"- Inicio (UTC): `{report['startedAt']}`",
        f"- Fin (UTC): `{report['finishedAt']}`",
        f"- Duración total: `{report['durationMs']} ms`",
        f"- Worktree al finalizar: `{report['worktree']}`",
        f"- Runtime: `Python {report['runtime']['python']}` / `{report['runtime']['platform']}`",
        "",
        "## Checks observados",
        "",
        "| Check | Estado | Exit code | Duración | Comando |",
        "|---|---:|---:|---:|---|",
    ]
    for check in report["checks"]:
        icon = "✅" if check["status"] == "passed" else "❌"
        command = check["command"].replace("|", "\\|")
        lines.append(
            f"| {check['name']} | {icon} {check['status']} | {check['exitCode']} | "
            f"{check['durationMs']} ms | `{command}` |"
        )
    lines.extend(
        [
            "",
            "> El runner ejecutó estos comandos. stdout/stderr no se persisten para evitar filtrar secretos.",
            "",
        ]
    )
    return "\n".join(lines)


def persist_report(root: Path, report: dict[str, Any]) -> dict[str, str]:
    directory = evidence_directory(root)
    stamp = report["finishedAt"].replace(":", "").replace("-", "")
    prefix = "gate" if report["status"] == "passed" else "failed-gate"
    stem = f"{prefix}-{report['sha']}-{stamp}"
    json_content = json.dumps(report, indent=2, sort_keys=True) + "\n"
    markdown_content = render_markdown(report)
    json_path = directory / f"{stem}.json"
    markdown_path = directory / f"{stem}.md"
    atomic_write(json_path, json_content)
    atomic_write(markdown_path, markdown_content)

    if report["status"] == "passed":
        latest_json = directory / "latest.json"
        latest_markdown = directory / "latest.md"
    else:
        latest_json = directory / "latest-failed.json"
        latest_markdown = directory / "latest-failed.md"
    atomic_write(latest_json, json_content)
    atomic_write(latest_markdown, markdown_content)
    return {
        "json": str(json_path),
        "markdown": str(markdown_path),
        "latestJson": str(latest_json),
        "latestMarkdown": str(latest_markdown),
    }


def run_checks(root: Path, checks: list[tuple[str, str]]) -> tuple[list[dict[str, Any]], bool]:
    results: list[dict[str, Any]] = []
    passed = True
    shell = os.environ.get("SHELL") or "/bin/sh"
    for name, command in checks:
        print(f"\n==> {name}: {command}", flush=True)
        started = time.monotonic_ns()
        result = subprocess.run(command, cwd=root, shell=True, executable=shell, check=False)
        duration_ms = round((time.monotonic_ns() - started) / 1_000_000)
        status = "passed" if result.returncode == 0 else "failed"
        results.append(
            {
                "name": name,
                "command": command,
                "exitCode": result.returncode,
                "durationMs": duration_ms,
                "status": status,
            }
        )
        if result.returncode:
            passed = False
    return results, passed


def build_report(
    root: Path,
    checks: list[dict[str, Any]],
    passed: bool,
    started_at: dt.datetime,
    finished_at: dt.datetime,
    duration_ms: int,
) -> dict[str, Any]:
    version_path = root / ".geome7ric" / "VERSION"
    version = version_path.read_text(encoding="utf-8").strip() if version_path.is_file() else "source"
    return {
        "schemaVersion": SCHEMA_VERSION,
        "status": "passed" if passed else "failed",
        "repository": repository_identity(root),
        "branch": git(root, "branch", "--show-current") or "detached",
        "sha": git(root, "rev-parse", "HEAD"),
        "tree": git(root, "rev-parse", "HEAD^{tree}"),
        "agenticVersion": version,
        "startedAt": iso(started_at),
        "finishedAt": iso(finished_at),
        "durationMs": duration_ms,
        "worktree": "dirty" if git(root, "status", "--porcelain") else "clean",
        "runtime": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "shell": os.environ.get("SHELL") or "/bin/sh",
        },
        "checks": checks,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Execute real checks and write structured local gate evidence."
    )
    parser.add_argument(
        "--check",
        action="append",
        nargs=2,
        required=True,
        metavar=("NAME", "COMMAND"),
        dest="checks",
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()

    root = Path(git(args.root.resolve(), "rev-parse", "--show-toplevel"))
    started_at = utc_now()
    started = time.monotonic_ns()
    results, passed = run_checks(root, [(name, command) for name, command in args.checks])
    finished_at = utc_now()
    duration_ms = round((time.monotonic_ns() - started) / 1_000_000)
    report = build_report(root, results, passed, started_at, finished_at, duration_ms)
    paths = persist_report(root, report)
    label = "Gate evidence" if passed else "Failed gate evidence"
    print(f"\n{label}: {paths['latestMarkdown']}")
    print(f"Structured evidence: {paths['latestJson']}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
