# Benchmark

This directory contains a reproducible benchmark for comparing privacy-filter
redaction latency and accuracy across decode implementations.

## Running the benchmark

From the repository root (with the virtual environment activated):

```bash
PYTHONPATH=src python scripts/benchmark.py --output benchmarks/results.json
```

The script prints a Markdown table to stdout and writes a JSON report to the
path given by `--output`.

### Modes compared

| Mode | Description |
|---|---|
| `cpu_full` | Model forward and Viterbi decode on CPU. |
| `cuda_cpu_viterbi` | Model forward on GPU, then upstream OPF Viterbi on CPU. |
| `cuda_decode_many` | GPU batched Viterbi via OPF's `ViterbiCRFDecoder.decode_many`. |
| `cuda_jit` | JIT-compiled GPU Viterbi via `viterbi_decode_scan`. |

### Options

- `--base-text`: Sentence to repeat for synthetic inputs.
- `--gpu-sizes`: Repeat counts for GPU modes (default: `10,50,100,300,600,1200`).
- `--cpu-sizes`: Repeat counts for CPU mode (default: `10,50,100`). CPU mode is
  slow, so keep these small.
- `--skip-cpu`: Skip the CPU baseline to save time.

## Interpreting results

- `duration_ms`: Best of 3 runs after a warm-up pass.
- `span_count`: Number of detected PII spans.
- `accuracy_vs_cpu`: Fraction of `cpu_full` detected spans also found by the
  compared mode when that repeat count was run on CPU. A value of `1.0` means
  all baseline spans were recovered.

## Latest results

See [`benchmarks/results.json`](./results.json) for the most recent run on the
current host, including system configuration (CPU, GPU, PyTorch/CUDA versions).
