#!/usr/bin/env python3
"""Compare a remote OPF service against the local rules-only fallback."""

from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

from privacy_filter_service.local_fallback import redact_text


@dataclass
class LatencyResult:
    mode: str
    text_chars: int
    n: int
    best_ms: float
    p50_ms: float
    p95_ms: float
    max_ms: float
    mean_ms: float
    span_count: int


@dataclass
class FunctionalResult:
    case: str
    mode: str
    span_count: int
    labels: dict[str, int]
    redacted_text: str


def percentile(sorted_values: list[float], p: float) -> float:
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return sorted_values[0]
    idx = (len(sorted_values) - 1) * p
    lower = int(idx)
    upper = min(lower + 1, len(sorted_values) - 1)
    return sorted_values[lower] + (sorted_values[upper] - sorted_values[lower]) * (idx - lower)


def get_system_info() -> dict:
    return {
        "client": {
            "cpu": platform.processor() or platform.machine(),
            "logical_cores": os.cpu_count(),
            "os": f"{platform.system()} {platform.release()}",
            "machine": platform.machine(),
            "python": platform.python_version(),
        }
    }


def post_redact(base_url: str, text: str, timeout_s: float) -> dict:
    payload = json.dumps({"text": text}).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/redact",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout_s) as response:
        return json.loads(response.read().decode("utf-8"))


def local_inprocess(text: str) -> dict:
    return redact_text(text).model_dump()


def local_cli(text: str) -> dict:
    env = dict(os.environ)
    src_path = str(Path(__file__).resolve().parents[1] / "src")
    env["PYTHONPATH"] = f"{src_path}{os.pathsep}{env['PYTHONPATH']}" if env.get("PYTHONPATH") else src_path
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "privacy_filter_service.local_fallback",
            "--format",
            "json",
        ],
        input=text,
        text=True,
        capture_output=True,
        check=True,
        env=env,
    )
    return json.loads(proc.stdout)


def benchmark_mode(
    mode: str,
    texts: list[str],
    fn: Callable[[str], dict],
    num_runs: int,
) -> list[LatencyResult]:
    results: list[LatencyResult] = []
    for text in texts:
        fn(text)
        durations: list[float] = []
        span_count = 0
        for _ in range(num_runs):
            t0 = time.perf_counter()
            result = fn(text)
            durations.append((time.perf_counter() - t0) * 1000)
            span_count = int(result.get("summary", {}).get("span_count", 0))
        durations.sort()
        results.append(
            LatencyResult(
                mode=mode,
                text_chars=len(text),
                n=num_runs,
                best_ms=durations[0],
                p50_ms=percentile(durations, 0.50),
                p95_ms=percentile(durations, 0.95),
                max_ms=durations[-1],
                mean_ms=statistics.fmean(durations),
                span_count=span_count,
            )
        )
    return results


def build_functional_cases() -> dict[str, str]:
    return {
        "email_phone": "Contact Alice at alice@example.com or 415-555-1212.",
        "url": "Dashboard: https://privacy.example.com/customer/alice?id=123",
        "bare_domain": "Customer portal lives at privacy.example.com/path?id=123",
        "secret": "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890",
        "jwt": (
            "Authorization: Bearer "
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
            "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkFsaWNlIn0."
            "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        ),
        "private_key": (
            "key = '''-----BEGIN PRIVATE KEY-----\n"
            "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n"
            "-----END PRIVATE KEY-----'''"
        ),
        "person_date": "Alice Smith was born on 1990-01-02 in Berkeley.",
        "address": "Ship it to 123 Main St, Springfield, IL 62704.",
        "clean": "Refactor parser and update README examples.",
    }


def functional_compare(base_url: str, timeout_s: float) -> list[FunctionalResult]:
    rows: list[FunctionalResult] = []
    for name, text in build_functional_cases().items():
        for mode, fn in (
            ("remote_opf_http", lambda value: post_redact(base_url, value, timeout_s)),
            ("local_fallback_inprocess", local_inprocess),
        ):
            result = fn(text)
            rows.append(
                FunctionalResult(
                    case=name,
                    mode=mode,
                    span_count=int(result.get("summary", {}).get("span_count", 0)),
                    labels=dict(result.get("summary", {}).get("by_label", {})),
                    redacted_text=str(result.get("redacted_text", "")),
                )
            )
    return rows


def build_latency_texts(base_text: str, sizes: list[int]) -> list[str]:
    return [base_text * size for size in sizes]


def print_markdown(
    *,
    service_info: dict,
    latency_results: list[LatencyResult],
    functional_results: list[FunctionalResult],
) -> str:
    lines: list[str] = []
    lines.append("## OPF GPU service vs local rules-only fallback POC")
    lines.append("")
    lines.append("Remote OPF service:")
    lines.append("")
    lines.append(f"- URL: `{service_info['url']}`")
    lines.append(f"- Health: `ready={service_info['health'].get('ready')}`, `device={service_info['health'].get('device')}`")
    model_info = service_info.get("model_info", {})
    lines.append(
        f"- Model info: `output_mode={model_info.get('output_mode')}`, "
        f"`decode_mode={model_info.get('decode_mode')}`"
    )
    lines.append("")
    lines.append("### Performance")
    lines.append("")
    lines.append("| mode | chars | runs | best ms | p50 ms | p95 ms | max ms | mean ms | spans |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for result in latency_results:
        lines.append(
            f"| {result.mode} | {result.text_chars} | {result.n} | "
            f"{result.best_ms:.2f} | {result.p50_ms:.2f} | {result.p95_ms:.2f} | "
            f"{result.max_ms:.2f} | {result.mean_ms:.2f} | {result.span_count} |"
        )
    lines.append("")
    lines.append("### Functional comparison")
    lines.append("")
    lines.append("| case | mode | spans | labels | redacted output |")
    lines.append("|---|---|---:|---|---|")
    for row in functional_results:
        redacted = row.redacted_text.replace("|", "\\|").replace("\n", "\\n")
        if len(redacted) > 120:
            redacted = redacted[:117] + "..."
        labels = json.dumps(row.labels, sort_keys=True)
        lines.append(f"| {row.case} | {row.mode} | {row.span_count} | `{labels}` | `{redacted}` |")
    lines.append("")
    lines.append("### Observations")
    lines.append("")
    lines.append("- Remote OPF has broader semantic coverage, especially people, dates, and addresses.")
    lines.append("- Local fallback is intentionally conservative and covers high-confidence rules/secrets.")
    lines.append("- In-process local fallback is very fast, but CLI cold start is significant; hook integration should batch files into one fallback invocation or use a small local helper.")
    return "\n".join(lines)


def get_json(base_url: str, path: str, timeout_s: float) -> dict:
    with urllib.request.urlopen(f"{base_url.rstrip('/')}{path}", timeout=timeout_s) as response:
        return json.loads(response.read().decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare remote OPF against local fallback")
    parser.add_argument("--base-url", default="http://192.168.88.75:8765")
    parser.add_argument("--timeout-s", type=float, default=10.0)
    parser.add_argument("--sizes", default="10,50,100,300")
    parser.add_argument("--num-runs", type=int, default=10)
    parser.add_argument("--cli-runs", type=int, default=3)
    parser.add_argument("--output-json", type=Path)
    parser.add_argument("--output-md", type=Path)
    args = parser.parse_args()

    try:
        health = get_json(args.base_url, "/health", args.timeout_s)
        model_info = get_json(args.base_url, "/model-info", args.timeout_s)
    except (urllib.error.URLError, TimeoutError) as exc:
        raise SystemExit(f"Remote OPF service unavailable: {exc}") from exc

    base_text = (
        "Test doc with email alice@example.com and phone 415-555-1212. "
        "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890 "
    )
    sizes = [int(value) for value in args.sizes.split(",")]
    texts = build_latency_texts(base_text, sizes)

    latency_results: list[LatencyResult] = []
    latency_results.extend(
        benchmark_mode(
            "remote_opf_http",
            texts,
            lambda value: post_redact(args.base_url, value, args.timeout_s),
            args.num_runs,
        )
    )
    latency_results.extend(
        benchmark_mode("local_fallback_inprocess", texts, local_inprocess, args.num_runs)
    )
    latency_results.extend(benchmark_mode("local_fallback_cli", texts, local_cli, args.cli_runs))

    functional_results = functional_compare(args.base_url, args.timeout_s)
    service_info = {
        "url": args.base_url,
        "health": health,
        "model_info": model_info,
    }
    markdown = print_markdown(
        service_info=service_info,
        latency_results=latency_results,
        functional_results=functional_results,
    )
    print(markdown)
    payload = {
        "system_info": get_system_info(),
        "service_info": service_info,
        "base_text": base_text,
        "sizes": sizes,
        "num_runs": args.num_runs,
        "cli_runs": args.cli_runs,
        "latency_results": [asdict(result) for result in latency_results],
        "functional_results": [asdict(result) for result in functional_results],
    }
    if args.output_json:
        args.output_json.parent.mkdir(parents=True, exist_ok=True)
        args.output_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    if args.output_md:
        args.output_md.parent.mkdir(parents=True, exist_ok=True)
        args.output_md.write_text(markdown + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
