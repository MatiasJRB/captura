#!/usr/bin/env python3
"""Record privacy-safe, observed metrics for an agentic delivery run."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from decimal import Decimal, InvalidOperation
from pathlib import Path
from statistics import median
from typing import Any
from urllib.parse import urlparse


SCHEMA_VERSION = 1
STATUSES = ("succeeded", "failed", "blocked", "cancelled")
TASK_TYPES = ("feature", "bugfix", "maintenance", "research", "docs", "incident", "review")
ARTIFACT_TYPES = ("commit", "pr", "issue", "deploy", "document")
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")
SAFE_RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
COMMIT_REFERENCE = re.compile(r"^[0-9a-fA-F]{7,64}$")


class MetricsError(RuntimeError):
    """Raised when an observation cannot be recorded safely."""


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
        raise MetricsError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def repository_root(path: Path) -> Path:
    return Path(git(path.resolve(), "rev-parse", "--show-toplevel")).resolve()


def repository_identity(root: Path) -> str:
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


def metrics_directory(root: Path) -> Path:
    common = Path(git(root, "rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = root / common
    return common.resolve() / "geome7ric-agentic" / "metrics"


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso(value: dt.datetime) -> str:
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_iso(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def atomic_create(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("x", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except FileExistsError as error:
        raise MetricsError(f"run already active: {payload['runId']}") from error


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(content)
        temporary = Path(handle.name)
    temporary.replace(path)


def safe_identifier(value: str) -> str:
    if not SAFE_IDENTIFIER.fullmatch(value):
        raise argparse.ArgumentTypeError("must be a structured identifier without whitespace")
    return value


def run_identifier(value: str) -> str:
    if not SAFE_RUN_ID.fullmatch(value):
        raise argparse.ArgumentTypeError("must use only letters, numbers, dots, underscores or hyphens")
    return value


def nonnegative_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


def nonnegative_decimal(value: str) -> Decimal:
    try:
        parsed = Decimal(value)
    except InvalidOperation as error:
        raise argparse.ArgumentTypeError("must be a decimal number") from error
    if not parsed.is_finite() or parsed < 0:
        raise argparse.ArgumentTypeError("must be a finite value zero or greater")
    return parsed


def decimal_text(value: Decimal) -> str:
    if value == 0:
        return "0"
    result = format(value, "f")
    if "." in result:
        result = result.rstrip("0").rstrip(".")
    return result or "0"


def artifact(value: str) -> dict[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("must use TYPE=REFERENCE")
    kind, reference = value.split("=", 1)
    if kind not in ARTIFACT_TYPES:
        raise argparse.ArgumentTypeError(f"artifact type must be one of: {', '.join(ARTIFACT_TYPES)}")
    if kind == "commit":
        if not COMMIT_REFERENCE.fullmatch(reference):
            raise argparse.ArgumentTypeError("commit reference must be a 7-64 character hexadecimal SHA")
    elif kind in {"pr", "issue"} and reference.isdigit():
        pass
    else:
        parsed = urlparse(reference)
        if (
            parsed.scheme != "https"
            or not parsed.netloc
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
            or len(reference) > 300
        ):
            raise argparse.ArgumentTypeError(
                "artifact reference must be an HTTPS URL without credentials, query or fragment"
            )
    return {"type": kind, "reference": reference}


def read_events(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_SH)
        for number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                raise MetricsError(f"invalid metrics event at line {number}") from error
            if event.get("schemaVersion") != SCHEMA_VERSION:
                raise MetricsError(f"unsupported metrics event at line {number}")
            events.append(event)
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    return events


def append_event(path: Path, event: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
    with path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        handle.seek(0)
        for current in handle:
            if current.strip() and json.loads(current).get("runId") == event["runId"]:
                raise MetricsError(f"run already finished: {event['runId']}")
        handle.seek(0, os.SEEK_END)
        handle.write(line)
        handle.flush()
        os.fsync(handle.fileno())
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def run_exists(path: Path, run_id: str) -> bool:
    return any(event.get("runId") == run_id for event in read_events(path))


def start_run(args: argparse.Namespace) -> dict[str, Any]:
    root = repository_root(args.root)
    directory = metrics_directory(root)
    run_id = args.run_id or str(uuid.uuid4())
    events_path = directory / "events.jsonl"
    if run_exists(events_path, run_id):
        raise MetricsError(f"run already finished: {run_id}")

    version_path = root / ".geome7ric" / "VERSION"
    state: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "runId": run_id,
        "repository": repository_identity(root),
        "branch": git(root, "branch", "--show-current") or "detached",
        "sha": git(root, "rev-parse", "HEAD"),
        "agenticVersion": version_path.read_text(encoding="utf-8").strip()
        if version_path.is_file()
        else "source",
        "taskType": args.task_type,
        "startedAt": iso(utc_now()),
    }
    if args.model is not None:
        state["model"] = args.model
    state_path = directory / "active" / f"{run_id}.json"
    atomic_create(state_path, state)
    return {"runId": run_id, "startedAt": state["startedAt"], "statePath": str(state_path)}


def finish_run(args: argparse.Namespace) -> dict[str, Any]:
    root = repository_root(args.root)
    directory = metrics_directory(root)
    state_path = directory / "active" / f"{args.run_id}.json"
    if not state_path.is_file():
        if run_exists(directory / "events.jsonl", args.run_id):
            raise MetricsError(f"run already finished: {args.run_id}")
        raise MetricsError(f"active run not found: {args.run_id}")
    state = json.loads(state_path.read_text(encoding="utf-8"))
    finished_at = utc_now()
    duration_ms = round((finished_at - parse_iso(state["startedAt"])).total_seconds() * 1000)
    if duration_ms < 0:
        raise MetricsError("run start time is in the future")

    event = {
        **state,
        "status": args.status,
        "finishedAt": iso(finished_at),
        "durationMs": duration_ms,
    }
    optional = {
        "model": args.model,
        "toolCalls": args.tool_calls,
        "retries": args.retries,
        "humanInterventions": args.human_interventions,
        "inputTokens": args.input_tokens,
        "outputTokens": args.output_tokens,
    }
    for name, value in optional.items():
        if value is not None:
            event[name] = value
    if args.cost_usd is not None:
        event["costUsd"] = decimal_text(args.cost_usd)
    if args.artifacts:
        event["artifacts"] = args.artifacts

    append_event(directory / "events.jsonl", event)
    state_path.unlink()
    atomic_write(directory / "latest.json", json.dumps(event, indent=2, sort_keys=True) + "\n")
    return event


def coverage(events: list[dict[str, Any]], field: str) -> dict[str, int | float]:
    observed = sum(1 for event in events if field in event)
    total = len(events)
    return {
        "observed": observed,
        "total": total,
        "ratio": round(observed / total, 4) if total else 0.0,
    }


def summarize(events: list[dict[str, Any]], repository: str) -> dict[str, Any]:
    total = len(events)
    by_status: dict[str, int] = {}
    by_task_type: dict[str, int] = {}
    for event in events:
        by_status[event["status"]] = by_status.get(event["status"], 0) + 1
        by_task_type[event["taskType"]] = by_task_type.get(event["taskType"], 0) + 1

    durations = [event["durationMs"] for event in events]
    observed_costs = [Decimal(event["costUsd"]) for event in events if "costUsd" in event]

    def total_or_none(field: str) -> int | None:
        values = [event[field] for event in events if field in event]
        return sum(values) if values else None

    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": iso(utc_now()),
        "repository": repository,
        "totalRuns": total,
        "byStatus": dict(sorted(by_status.items())),
        "byTaskType": dict(sorted(by_task_type.items())),
        "successRatio": round(by_status.get("succeeded", 0) / total, 4) if total else None,
        "durationMs": {
            "total": sum(durations) if durations else None,
            "minimum": min(durations) if durations else None,
            "maximum": max(durations) if durations else None,
            "average": round(sum(durations) / total, 2) if durations else None,
            "median": median(durations) if durations else None,
        },
        "totals": {
            "toolCalls": total_or_none("toolCalls"),
            "retries": total_or_none("retries"),
            "humanInterventions": total_or_none("humanInterventions"),
            "tokens": {
                "input": total_or_none("inputTokens"),
                "output": total_or_none("outputTokens"),
            },
            "costUsd": decimal_text(sum(observed_costs, Decimal("0")))
            if observed_costs
            else None,
        },
        "coverage": {
            field: coverage(events, field)
            for field in (
                "model",
                "toolCalls",
                "retries",
                "humanInterventions",
                "inputTokens",
                "outputTokens",
                "costUsd",
                "artifacts",
            )
        },
    }


def render_markdown(summary: dict[str, Any]) -> str:
    duration = summary["durationMs"]
    ratio = summary["successRatio"]
    ratio_label = f"{ratio:.0%}" if ratio is not None else "—"
    lines = [
        "# Geome7ric Agentic — métricas observadas",
        "",
        f"- Repositorio: `{summary['repository']}`",
        f"- Ejecuciones: `{summary['totalRuns']}`",
        f"- Éxito: `{ratio_label}`",
        f"- Duración mediana: `{duration['median']} ms`" if duration["median"] is not None else "- Duración mediana: `—`",
        f"- Costo observado: `${summary['totals']['costUsd']}`"
        if summary["totals"]["costUsd"] is not None
        else "- Costo observado: `—`",
        "",
        "## Cobertura",
        "",
        "| Campo | Observado | Cobertura |",
        "|---|---:|---:|",
    ]
    for field, item in summary["coverage"].items():
        lines.append(f"| {field} | {item['observed']}/{item['total']} | {item['ratio']:.0%} |")
    lines.extend(
        [
            "",
            "> Los valores ausentes no se estiman. El registro no contiene prompts, respuestas ni logs.",
            "",
        ]
    )
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    start = commands.add_parser("start", help="Start an observed delivery run")
    start.add_argument("--root", type=Path, default=Path.cwd())
    start.add_argument("--run-id", type=run_identifier)
    start.add_argument("--task-type", choices=TASK_TYPES, required=True)
    start.add_argument("--model", type=safe_identifier)

    finish = commands.add_parser("finish", help="Finish and persist an observed delivery run")
    finish.add_argument("--root", type=Path, default=Path.cwd())
    finish.add_argument("--run-id", type=run_identifier, required=True)
    finish.add_argument("--status", choices=STATUSES, required=True)
    finish.add_argument("--model", type=safe_identifier)
    finish.add_argument("--tool-calls", type=nonnegative_int)
    finish.add_argument("--retries", type=nonnegative_int)
    finish.add_argument("--human-interventions", type=nonnegative_int)
    finish.add_argument("--input-tokens", type=nonnegative_int)
    finish.add_argument("--output-tokens", type=nonnegative_int)
    finish.add_argument("--cost-usd", type=nonnegative_decimal)
    finish.add_argument("--artifact", dest="artifacts", action="append", type=artifact, default=[])

    summary = commands.add_parser("summary", help="Summarize recorded runs")
    summary.add_argument("--root", type=Path, default=Path.cwd())
    summary.add_argument("--format", choices=("json", "markdown"), default="markdown")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "start":
            payload = start_run(args)
            print(json.dumps(payload, sort_keys=True))
        elif args.command == "finish":
            payload = finish_run(args)
            print(json.dumps(payload, sort_keys=True))
        else:
            root = repository_root(args.root)
            payload = summarize(
                read_events(metrics_directory(root) / "events.jsonl"), repository_identity(root)
            )
            if args.format == "json":
                print(json.dumps(payload, sort_keys=True))
            else:
                print(render_markdown(payload))
    except (
        MetricsError,
        json.JSONDecodeError,
        OSError,
        ValueError,
        KeyError,
        TypeError,
        InvalidOperation,
    ) as error:
        print(f"agentic metrics: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
