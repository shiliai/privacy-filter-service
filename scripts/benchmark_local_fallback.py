#!/usr/bin/env python3
"""Benchmark the local rules-only fallback redactor."""

from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from privacy_filter_service.local_fallback import redact_text


@dataclass
class LocalFallbackBenchmarkResult:
    mode: str
    text_chars: int
    duration_ms: float
    p50_ms: float
    p95_ms: float
    max_ms: float
    mean_ms: float
    span_count: int


def build_texts(base: str, sizes: list[int]) -> list[tuple[int, str]]:
    return [(n, base * n) for n in sizes]


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
        "cpu": {
            "model": platform.processor() or platform.machine(),
            "logical_cores": os.cpu_count(),
        },
        "os": {
            "system": platform.system(),
            "release": platform.release(),
            "version": platform.version(),
            "machine": platform.machine(),
        },
        "python": platform.python_version(),
    }


def benchmark_text(text: str, num_runs: int) -> LocalFallbackBenchmarkResult:
    warmup = redact_text(text)
    durations: list[float] = []
    span_count = warmup.summary.span_count
    for _ in range(num_runs):
        t0 = time.perf_counter()
        result = redact_text(text)
        durations.append((time.perf_counter() - t0) * 1000)
        span_count = result.summary.span_count
    durations.sort()
    return LocalFallbackBenchmarkResult(
        mode="local_fallback",
        text_chars=len(text),
        duration_ms=min(durations),
        p50_ms=percentile(durations, 0.50),
        p95_ms=percentile(durations, 0.95),
        max_ms=durations[-1],
        mean_ms=statistics.fmean(durations),
        span_count=span_count,
    )


def benchmark_cli_text(text: str, num_runs: int) -> LocalFallbackBenchmarkResult:
    durations: list[float] = []
    span_count = 0
    env = dict(os.environ)
    src_path = str(Path(__file__).resolve().parents[1] / "src")
    env["PYTHONPATH"] = f"{src_path}{os.pathsep}{env['PYTHONPATH']}" if env.get("PYTHONPATH") else src_path
    for _ in range(num_runs):
        t0 = time.perf_counter()
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
        durations.append((time.perf_counter() - t0) * 1000)
        span_count = int(json.loads(proc.stdout)["summary"]["span_count"])
    durations.sort()
    return LocalFallbackBenchmarkResult(
        mode="local_fallback_cli",
        text_chars=len(text),
        duration_ms=min(durations),
        p50_ms=percentile(durations, 0.50),
        p95_ms=percentile(durations, 0.95),
        max_ms=durations[-1],
        mean_ms=statistics.fmean(durations),
        span_count=span_count,
    )


def print_markdown(results: list[LocalFallbackBenchmarkResult], system_info: dict) -> None:
    print("# Local Fallback Benchmark Results\n")
    print("## System Info\n")
    print(f"- CPU: {system_info['cpu'].get('model', 'unknown')}")
    print(f"- CPU cores: {system_info['cpu'].get('logical_cores', 'unknown')}")
    print(f"- OS: {system_info['os'].get('system')} {system_info['os'].get('release')}")
    print(f"- Python: {system_info.get('python')}")
    print()
    print("## Latency\n")
    print("| mode | chars | best_ms | p50_ms | p95_ms | max_ms | mean_ms | span_count |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for result in results:
        print(
            f"| {result.mode} | {result.text_chars} | {result.duration_ms:.3f} | "
            f"{result.p50_ms:.3f} | {result.p95_ms:.3f} | {result.max_ms:.3f} | "
            f"{result.mean_ms:.3f} | {result.span_count} |"
        )
    print()


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark local fallback redaction")
    parser.add_argument(
        "--output",
        type=Path,
        help="Write JSON results to this file.",
    )
    parser.add_argument(
        "--base-text",
        default=(
            "Test doc with email alice@example.com and phone 415-555-1212. "
            "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890 "
        ),
        help="Sentence to repeat for synthetic benchmark texts.",
    )
    parser.add_argument(
        "--sizes",
        default="10,50,100,300,600,1200",
        help="Comma-separated repeat counts.",
    )
    parser.add_argument(
        "--num-runs",
        type=int,
        default=30,
        help="Number of timed runs per size.",
    )
    parser.add_argument(
        "--include-cli",
        action="store_true",
        help="Also benchmark CLI subprocess startup overhead.",
    )
    parser.add_argument(
        "--cli-runs",
        type=int,
        default=5,
        help="Number of timed CLI subprocess runs per size.",
    )
    args = parser.parse_args()

    sizes = [int(value) for value in args.sizes.split(",")]
    texts = build_texts(args.base_text, sizes)
    system_info = get_system_info()
    results = [benchmark_text(text, args.num_runs) for _, text in texts]
    if args.include_cli:
        results.extend(benchmark_cli_text(text, args.cli_runs) for _, text in texts)
    print_markdown(results, system_info)
    if args.output:
        payload = {
            "system_info": system_info,
            "base_text": args.base_text,
            "num_runs": args.num_runs,
            "include_cli": args.include_cli,
            "cli_runs": args.cli_runs,
            "results": [asdict(result) for result in results],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"Wrote JSON results to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
