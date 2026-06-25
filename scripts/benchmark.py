#!/usr/bin/env python3
"""Benchmark privacy-filter-service redaction latency and accuracy.

This script compares three decode configurations on the local host:

1. ``cpu`` - original OPF CPU Viterbi decode (ground truth).
2. ``decode_many`` - GPU batched Viterbi via OPF's decode_many.
3. ``jit`` - JIT-compiled GPU Viterbi via viterbi_decode_scan.

Run from the repo root with the virtual environment activated:

    PYTHONPATH=src python scripts/benchmark.py --output benchmarks/results.json

If no ``--output`` is given, results are printed to stdout as Markdown.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

import torch

# Ensure project src is importable when run from repo root.
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "src"))

from opf._api import OPF
from opf._core.runtime import predict_text as predict_text_cpu
from privacy_filter_service.config import load_settings
from privacy_filter_service.fast_predict import predict_text_gpu_decode


MODES = ("cpu", "decode_many", "jit")
Mode = Literal["cpu", "decode_many", "jit"]


@dataclass
class BenchmarkResult:
    mode: str
    text_chars: int
    text_tokens: int
    duration_ms: float
    span_count: int
    accuracy_vs_cpu: float | None


def get_text(base: str, repeats: int) -> str:
    return base * repeats


def get_system_info() -> dict:
    """Collect CPU/GPU/OS information for reproducibility."""
    info: dict = {
        "cpu": {},
        "gpu": {},
        "memory_gb": {},
        "os": {},
    }

    # CPU info
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

    # Memory info
    try:
        mem = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines() if ":" in line)
        total_kb = int(mem.get("MemTotal", "0 kB").split()[0])
        info["memory_gb"]["total"] = round(total_kb / 1024 / 1024, 2)
    except Exception:
        pass

    # GPU info
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

    # PyTorch / CUDA info
    info["pytorch"] = {
        "torch_version": torch.__version__,
        "cuda_available": torch.cuda.is_available(),
        "cuda_version": torch.version.cuda,
    }
    if torch.cuda.is_available():
        info["pytorch"]["device_name"] = torch.cuda.get_device_name(0)
        info["pytorch"]["device_count"] = torch.cuda.device_count()

    # OS info
    try:
        info["os"]["kernel"] = os.uname().release
        info["os"]["hostname"] = os.uname().nodename
    except Exception:
        pass

    return info


def benchmark_mode(
    mode: Mode,
    texts: list[tuple[int, str]],
    opf_gpu: OPF,
    opf_cpu: OPF | None,
    cpu_results: dict[int, list[tuple[int, int, str]]] | None,
    num_runs: int = 3,
    warmup: bool = True,
) -> list[BenchmarkResult]:
    """Run benchmark for one decode mode."""
    runtime, decoder = opf_gpu.get_prediction_components()

    if mode == "cpu":
        if opf_cpu is None:
            raise RuntimeError("CPU OPF instance required for cpu mode")
        runtime_cpu, decoder_cpu = opf_cpu.get_prediction_components()

    results: list[BenchmarkResult] = []

    for repeats, text in texts:
        tokens = tuple(int(tok) for tok in runtime.encoding.encode(text, allowed_special="all"))
        token_count = len(tokens)

        if warmup:
            # Dry run to warm caches.
            if mode == "cpu":
                predict_text_cpu(runtime_cpu, text, decoder=decoder_cpu)
            else:
                predict_text_gpu_decode(runtime, text, decoder=decoder, use_jit=(mode == "jit"))

        # Timed runs.
        durations: list[float] = []
        spans: list[tuple[int, int, str]] = []
        for _ in range(num_runs):
            t0 = time.monotonic()
            if mode == "cpu":
                pred = predict_text_cpu(runtime_cpu, text, decoder=decoder_cpu)
            else:
                pred = predict_text_gpu_decode(
                    runtime, text, decoder=decoder, use_jit=(mode == "jit")
                )
            if torch.cuda.is_available():
                torch.cuda.synchronize()
            durations.append((time.monotonic() - t0) * 1000)
            spans = [(s.start, s.end, s.label) for s in pred.spans]

        duration_ms = min(durations)  # Report best of N.
        span_count = len(spans)

        accuracy: float | None = None
        if cpu_results is not None and repeats in cpu_results:
            cpu_spans = set(cpu_results[repeats])
            gpu_spans = set(spans)
            if len(cpu_spans) == 0:
                accuracy = 1.0 if len(gpu_spans) == 0 else 0.0
            else:
                accuracy = len(cpu_spans & gpu_spans) / len(cpu_spans)

        results.append(
            BenchmarkResult(
                mode=mode,
                text_chars=len(text),
                text_tokens=token_count,
                duration_ms=duration_ms,
                span_count=span_count,
                accuracy_vs_cpu=accuracy,
            )
        )

    return results


def build_texts(base: str, sizes: list[int]) -> list[tuple[int, str]]:
    return [(n, get_text(base, n)) for n in sizes]


def print_markdown(results: list[BenchmarkResult], system_info: dict) -> None:
    print("# Privacy Filter Benchmark Results\n")

    print("## System Info\n")
    print(f"- CPU: {system_info['cpu'].get('model', 'unknown')}")
    print(f"- CPU cores: {system_info['cpu'].get('logical_cores', 'unknown')}")
    print(f"- Memory: {system_info['memory_gb'].get('total', 'unknown')} GB")
    gpu = system_info.get("gpu", {})
    if gpu:
        print(f"- GPU: {gpu.get('name', 'unknown')}")
        print(f"- GPU driver: {gpu.get('driver', 'unknown')}")
        print(f"- GPU memory: {gpu.get('memory_used_mb', 'unknown')} / {gpu.get('memory_total_mb', 'unknown')} MB")
    print(f"- PyTorch: {system_info['pytorch'].get('torch_version', 'unknown')}")
    print(f"- CUDA available: {system_info['pytorch'].get('cuda_available', 'unknown')}")
    print(f"- CUDA version: {system_info['pytorch'].get('cuda_version', 'unknown')}")
    if "device_name" in system_info["pytorch"]:
        print(f"- CUDA device: {system_info['pytorch']['device_name']}")
    print()

    print("## Latency & Accuracy\n")
    print("| mode | chars | tokens | duration_ms | span_count | accuracy_vs_cpu |")
    print("|---|---|---|---|---|---|")
    for r in results:
        acc = f"{r.accuracy_vs_cpu:.4f}" if r.accuracy_vs_cpu is not None else "n/a"
        print(
            f"| {r.mode} | {r.text_chars} | {r.text_tokens} | {r.duration_ms:.2f} | {r.span_count} | {acc} |"
        )
    print()


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark privacy-filter decode modes")
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
        "--gpu-sizes",
        default="10,50,100,300,600,1200",
        help="Comma-separated repeat counts for GPU modes",
    )
    parser.add_argument(
        "--cpu-sizes",
        default="10,50,100",
        help="Comma-separated repeat counts for CPU mode (CPU is slow)",
    )
    parser.add_argument(
        "--skip-cpu",
        action="store_true",
        help="Skip CPU baseline (saves time if already verified)",
    )
    args = parser.parse_args()

    settings = load_settings()

    gpu_sizes = [int(x) for x in args.gpu_sizes.split(",")]
    cpu_sizes = [int(x) for x in args.cpu_sizes.split(",")]

    gpu_texts = build_texts(args.base_text, gpu_sizes)
    cpu_texts = build_texts(args.base_text, cpu_sizes)

    # CPU baseline as ground truth.
    opf_cpu: OPF | None = None
    cpu_results: dict[int, list[tuple[int, int, str]]] = {}
    if not args.skip_cpu:
        print("Warming up CPU baseline...", file=sys.stderr)
        opf_cpu = OPF(
            model=settings.service.model_path,
            device="cpu",
            output_mode="typed",
            decode_mode="viterbi",
        )
        runtime_cpu, decoder_cpu = opf_cpu.get_prediction_components()
        # Ensure tiktoken cache is loaded.
        predict_text_cpu(runtime_cpu, args.base_text, decoder=decoder_cpu)

    # GPU instance is used for both decode_many and jit modes.
    print("Warming up GPU instance...", file=sys.stderr)
    opf_gpu = OPF(
        model=settings.service.model_path,
        device="cuda",
        output_mode="typed",
        decode_mode="viterbi",
    )

    all_results: list[BenchmarkResult] = []

    if not args.skip_cpu:
        print("Benchmarking CPU baseline...", file=sys.stderr)
        cpu_results_list = benchmark_mode(
            "cpu", cpu_texts, opf_gpu, opf_cpu, cpu_results=None, num_runs=1, warmup=False
        )
        for (repeats, text), r in zip(cpu_texts, cpu_results_list):
            # Store spans for accuracy comparison.
            runtime_cpu, decoder_cpu = opf_cpu.get_prediction_components()
            pred = predict_text_cpu(runtime_cpu, text, decoder=decoder_cpu)
            cpu_results[repeats] = [(s.start, s.end, s.label) for s in pred.spans]
        all_results.extend(cpu_results_list)

    for mode in ("decode_many", "jit"):
        print(f"Benchmarking {mode}...", file=sys.stderr)
        results = benchmark_mode(
            mode, gpu_texts, opf_gpu, opf_cpu, cpu_results=cpu_results, num_runs=3, warmup=True
        )
        all_results.extend(results)

    system_info = get_system_info()

    print_markdown(all_results, system_info)

    if args.output:
        payload = {
            "system_info": system_info,
            "base_text": args.base_text,
            "results": [asdict(r) for r in all_results],
        }
        args.output.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nWrote JSON results to {args.output}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
