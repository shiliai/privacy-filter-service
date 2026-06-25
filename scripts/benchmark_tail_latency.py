#!/usr/bin/env python3
"""Tail-latency benchmark for privacy-filter decode paths.

Runs many iterations per text length and reports percentiles plus the number of
requests that exceed the hook timeout. Designed to test whether the current
deployment baseline (`cuda_cpu_viterbi`) has dangerous tail latency under a
shared GPU, while the JIT GPU path stays predictable.

Example:

    PYTHONPATH=src python scripts/benchmark_tail_latency.py \\
        --output benchmarks/tail_latency_results.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

import torch

from opf._api import OPF
from opf._core.runtime import predict_text as predict_text_upstream
from privacy_filter_service.config import load_settings
from privacy_filter_service.fast_predict import predict_text_gpu_decode


Mode = Literal["cuda_cpu_viterbi", "cuda_jit", "cuda_decode_many"]


@dataclass
class TailLatencyResult:
    mode: str
    text_chars: int
    text_tokens: int
    n: int
    p50_ms: float
    p95_ms: float
    p99_ms: float
    max_ms: float
    mean_ms: float
    std_ms: float
    over_timeout_ms: int
    timeout_ms: float


def get_system_info() -> dict:
    """Collect CPU/GPU/OS information for reproducibility."""
    info: dict = {
        "cpu": {},
        "gpu": {},
        "memory_gb": {},
        "os": {},
    }

    try:
        with open("/proc/cpuinfo", "r") as f:
            lines = f.readlines()
        model_name = "unknown"
        cpu_cores = 0
        for line in lines:
            if line.startswith("model name"):
                model_name = line.split(":", 1)[1].strip()
                cpu_cores += 1
        info["cpu"]["model"] = model_name
        info["cpu"]["logical_cores"] = cpu_cores
    except Exception:
        pass

    try:
        mem = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines() if ":" in line)
        total_kb = int(mem.get("MemTotal", "0 kB").split()[0])
        info["memory_gb"]["total"] = round(total_kb / 1024 / 1024, 2)
    except Exception:
        pass

    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, check=False, timeout=10
        )
        if result.returncode == 0:
            parts = [p.strip() for p in result.stdout.strip().split(",")]
            if len(parts) >= 5:
                info["gpu"] = {
                    "name": parts[0],
                    "driver": parts[1],
                    "memory_total_mb": int(float(parts[2])),
                    "memory_used_mb": int(float(parts[3])),
                    "utilization_percent": float(parts[4]),
                }
    except Exception:
        pass

    info["pytorch"] = {
        "torch_version": torch.__version__,
        "cuda_available": torch.cuda.is_available(),
        "cuda_version": torch.version.cuda,
    }
    if torch.cuda.is_available():
        info["pytorch"]["device_name"] = torch.cuda.get_device_name(0)
        info["pytorch"]["device_count"] = torch.cuda.device_count()

    try:
        info["os"]["kernel"] = os.uname().release
        info["os"]["hostname"] = os.uname().nodename
    except Exception:
        pass

    return info


def get_gpu_processes() -> list[dict]:
    """Return list of GPU compute processes from nvidia-smi."""
    processes: list[dict] = []
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, check=False, timeout=10
        )
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines():
                parts = [p.strip() for p in line.split(",")]
                if len(parts) >= 3:
                    processes.append({
                        "pid": parts[0],
                        "name": parts[1],
                        "used_memory_mb": int(float(parts[2])),
                    })
    except Exception:
        pass
    return processes


def build_texts(base: str, sizes: list[int]) -> list[tuple[int, str]]:
    return [(n, base * n) for n in sizes]


def percentile(sorted_values: list[float], p: float) -> float:
    """Linear interpolation percentile for sorted values."""
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return sorted_values[0]
    k = (len(sorted_values) - 1) * p
    f = int(math.floor(k))
    c = min(f + 1, len(sorted_values) - 1)
    return sorted_values[f] + (sorted_values[c] - sorted_values[f]) * (k - f)


def benchmark_tail_latency(
    mode: Mode,
    texts: list[tuple[int, str]],
    opf_gpu: OPF,
    num_runs: int,
    timeout_ms: float,
) -> list[TailLatencyResult]:
    """Run tail-latency benchmark for one decode mode."""
    runtime, decoder = opf_gpu.get_prediction_components()
    results: list[TailLatencyResult] = []

    for repeats, text in texts:
        tokens = tuple(int(tok) for tok in runtime.encoding.encode(text, allowed_special="all"))
        token_count = len(tokens)

        # Warm-up for this length/mode.
        if mode == "cuda_cpu_viterbi":
            predict_text_upstream(runtime, text, decoder=decoder)
        elif mode == "cuda_decode_many":
            predict_text_gpu_decode(runtime, text, decoder=decoder, use_jit=False)
        else:  # cuda_jit
            predict_text_gpu_decode(runtime, text, decoder=decoder, use_jit=True)
        if torch.cuda.is_available():
            torch.cuda.synchronize()

        durations: list[float] = []
        for _ in range(num_runs):
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            t0 = time.monotonic()
            if mode == "cuda_cpu_viterbi":
                predict_text_upstream(runtime, text, decoder=decoder)
            elif mode == "cuda_decode_many":
                predict_text_gpu_decode(runtime, text, decoder=decoder, use_jit=False)
            else:  # cuda_jit
                predict_text_gpu_decode(runtime, text, decoder=decoder, use_jit=True)
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            durations.append((time.monotonic() - t0) * 1000)

        durations.sort()
        mean = sum(durations) / len(durations)
        variance = sum((d - mean) ** 2 for d in durations) / len(durations)
        results.append(
            TailLatencyResult(
                mode=mode,
                text_chars=len(text),
                text_tokens=token_count,
                n=num_runs,
                p50_ms=percentile(durations, 0.50),
                p95_ms=percentile(durations, 0.95),
                p99_ms=percentile(durations, 0.99),
                max_ms=durations[-1],
                mean_ms=mean,
                std_ms=math.sqrt(variance),
                over_timeout_ms=sum(1 for d in durations if d > timeout_ms),
                timeout_ms=timeout_ms,
            )
        )

    return results


def print_markdown(results: list[TailLatencyResult], system_info: dict) -> None:
    print("# Privacy Filter Tail-Latency Benchmark\n")

    print("## System Info\n")
    print(f"- CPU: {system_info['cpu'].get('model', 'unknown')}")
    print(f"- CPU cores: {system_info['cpu'].get('logical_cores', 'unknown')}")
    print(f"- Memory: {system_info['memory_gb'].get('total', 'unknown')} GB")
    gpu = system_info.get("gpu", {})
    if gpu:
        print(f"- GPU: {gpu.get('name', 'unknown')}")
        print(f"- GPU driver: {gpu.get('driver', 'unknown')}")
        print(f"- GPU memory: {gpu.get('memory_used_mb', 'unknown')} / {gpu.get('memory_total_mb', 'unknown')} MB")
        print(f"- GPU utilization: {gpu.get('utilization_percent', 'unknown')}%")
    print(f"- PyTorch: {system_info['pytorch'].get('torch_version', 'unknown')}")
    print(f"- CUDA available: {system_info['pytorch'].get('cuda_available', 'unknown')}")
    print(f"- CUDA version: {system_info['pytorch'].get('cuda_version', 'unknown')}")
    print()

    print("## Tail Latency by Mode\n")
    print("| mode | chars | tokens | n | p50 | p95 | p99 | max | mean | >5s |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in results:
        print(
            f"| {r.mode} | {r.text_chars} | {r.text_tokens} | {r.n} | "
            f"{r.p50_ms:.2f} | {r.p95_ms:.2f} | {r.p99_ms:.2f} | {r.max_ms:.2f} | "
            f"{r.mean_ms:.2f} | {r.over_timeout_ms} |"
        )
    print()


def main() -> int:
    parser = argparse.ArgumentParser(description="Tail-latency benchmark for GPU decode paths")
    parser.add_argument(
        "--output",
        type=Path,
        help="Write JSON results to this file (also prints Markdown to stdout)",
    )
    parser.add_argument(
        "--base-text",
        default="Test doc with email <PRIVATE_EMAIL> and phone <PRIVATE_PHONE>. ",
        help="Sentence to repeat for synthetic benchmark texts",
    )
    parser.add_argument(
        "--sizes",
        default="10,50,100,300,600,1200",
        help="Comma-separated repeat counts",
    )
    parser.add_argument(
        "--modes",
        default="cuda_cpu_viterbi,cuda_jit",
        help="Comma-separated modes to benchmark",
    )
    parser.add_argument(
        "--num-runs",
        type=int,
        default=30,
        help="Number of timed runs per length/mode",
    )
    parser.add_argument(
        "--timeout-ms",
        type=float,
        default=5000.0,
        help="Hook timeout threshold in milliseconds",
    )
    args = parser.parse_args()

    settings = load_settings()
    sizes = [int(x) for x in args.sizes.split(",")]
    modes = [m.strip() for m in args.modes.split(",")]
    texts = build_texts(args.base_text, sizes)

    print("Loading GPU OPF instance...", file=sys.stderr)
    opf_gpu = OPF(
        model=settings.service.model_path,
        device="cuda",
        output_mode="typed",
        decode_mode="viterbi",
    )
    runtime, decoder = opf_gpu.get_prediction_components()

    # Global warm-up: run both prediction paths once so one mode does not pay
    # first-call costs for the other.
    print("Global warm-up for all modes...", file=sys.stderr)
    sample_text = args.base_text * 10
    predict_text_upstream(runtime, sample_text, decoder=decoder)
    if torch.cuda.is_available():
        torch.cuda.synchronize()
    predict_text_gpu_decode(runtime, sample_text, decoder=decoder, use_jit=False)
    if torch.cuda.is_available():
        torch.cuda.synchronize()
    predict_text_gpu_decode(runtime, sample_text, decoder=decoder, use_jit=True)
    if torch.cuda.is_available():
        torch.cuda.synchronize()

    system_info = get_system_info()
    system_info["gpu_processes"] = get_gpu_processes()

    all_results: list[TailLatencyResult] = []
    for mode in modes:
        print(f"Benchmarking {mode} ({args.num_runs} runs per length)...", file=sys.stderr)
        results = benchmark_tail_latency(mode, texts, opf_gpu, args.num_runs, args.timeout_ms)
        all_results.extend(results)

    print_markdown(all_results, system_info)

    if args.output:
        payload = {
            "system_info": system_info,
            "base_text": args.base_text,
            "timeout_ms": args.timeout_ms,
            "num_runs": args.num_runs,
            "results": [asdict(r) for r in all_results],
        }
        args.output.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nWrote JSON results to {args.output}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
