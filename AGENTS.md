# AGENTS.md — Privacy Filter Service

> Instructions for AI agents working on this codebase.
> Read this file first before making any changes.

---

## Project Identity

**Privacy Filter Service** wraps the [OpenAI Privacy Filter (OPF)](https://github.com/openai/privacy-filter) model in a FastAPI microservice. It detects and redacts PII from text. The primary consumer is a pair of global git hooks that block commits containing PII and auto-redact commit messages.

- **Language**: Python 3.10
- **Framework**: FastAPI + uvicorn (single worker)
- **Model**: OPF checkpoint at `/mnt/LLM/OpenAI/privacy_filter`
- **GPU**: RTX 3090, CUDA 11.8, PyTorch 2.7.1
- **Package manager**: `uv` (NOT pip directly)
- **Service manager**: systemd user unit (`systemctl --user`)
- **Hook mechanism**: `git config --global core.hooksPath ~/.config/git/hooks`

---

## Directory Layout

```
~/project/docker/privacy-filter-service/    ← THIS PROJECT
├── src/privacy_filter_service/
│   ├── app.py              # FastAPI factory, routes, entrypoint
│   ├── config.py           # TOML + env var config loader (Pydantic)
│   ├── models.py           # Request/response Pydantic models
│   ├── opf_engine.py       # Async OPF wrapper with asyncio.Lock
│   └── logging_setup.py    # Sanitized JSON logging + request ID middleware
├── hooks/
│   ├── _lib.sh             # Shared bash library (HTTP, file detection, fail-open)
│   ├── pre-commit          # Pre-commit hook (scan staged files, generate patch)
│   └── commit-msg          # Commit-msg hook (auto-redact PII in message)
├── install/
│   ├── install-service.sh  # Service installer (venv, config, systemd)
│   ├── install-hooks.sh    # Hook installer (core.hooksPath)
│   └── uninstall.sh        # Uninstaller (preserves user config)
├── systemd/
│   └── privacy-filter.service  # systemd user unit template
├── config/
│   └── env.example         # Environment variable template
├── tests/
│   ├── test_*.py           # pytest unit tests (no GPU required)
│   ├── integration/        # Bash integration tests (isolated /tmp repos)
│   │   ├── run_all.sh      # Test runner (13 tests)
│   │   └── test_*.sh       # Individual test scripts
│   └── e2e/
│       └── smoke.sh        # End-to-end smoke test (7 scenarios)
├── docs/
│   └── llms-full.txt       # Complete API reference for agents
├── config.toml.example     # Config template
├── pyproject.toml          # Build config, dependencies
├── uv.lock                 # Locked dependencies
└── README.md               # User documentation
```

**Sibling project** (OPF library, consumed as editable dependency):
```
~/project/docker/privacy-filter/            ← OPF library
```

---

## Runtime Architecture

```
┌─────────────────────┐        HTTP POST        ┌──────────────────────────┐
│   git pre-commit    │  ─────────────────────>  │  Privacy Filter Service  │
│   git commit-msg    │  /redact  /redact/text   │  FastAPI + uvicorn       │
└─────────────────────┘  /redact/batch           │  Single worker on :8765  │
         │                                       └──────────────────────────┘
         │ blocks commit                                     │
         │ writes .patch                                     │ OPF model (CUDA)
         v                                                   v
   .git/privacy-filter/                         /mnt/LLM/OpenAI/privacy_filter
```

**Key properties**:
- Single uvicorn worker (model not validated for concurrency)
- All requests serialized via `asyncio.Lock` in `OPFEngine`
- Fail-open: service down → warn + exit 0, never block developer
- Sanitized logging: no raw text in journald

---

## Development

### Setup

```bash
cd ~/project/docker/privacy-filter-service

# Create venv (Python 3.10)
uv venv .venv --python 3.10

# Install in editable mode with dev deps
uv pip install -e ".[dev]"
```

### Running tests

```bash
# Unit tests (no GPU required)
uv run pytest -q

# GPU-specific tests
uv run pytest -q -m gpu

# Linting
uv run ruff check src/

# Integration tests (isolated /tmp repos, requires service running)
bash tests/integration/run_all.sh

# End-to-end smoke (full lifecycle, requires service running)
bash tests/e2e/smoke.sh
```

### Starting the service locally (for development)

```bash
# Via uvicorn directly (foreground, for debugging)
OPF_CHECKPOINT=/mnt/LLM/OpenAI/privacy_filter \
  PRIVACY_FILTER_CONFIG=/path/to/config.toml \
  uvicorn privacy_filter_service.app:create_app --factory --host 127.0.0.1 --port 8765

# Via systemd (background, production-like)
systemctl --user start privacy-filter
systemctl --user restart privacy-filter  # after config changes
journalctl --user -u privacy-filter -f   # follow logs
```

### Verifying the service

```bash
# Health check
curl -fsS http://127.0.0.1:8765/health | jq .

# Model info (no checkpoint path leaked)
curl -fsS http://127.0.0.1:8765/model-info | jq .

# Test redaction
curl -fsS -X POST http://127.0.0.1:8765/redact/text \
  -H 'Content-Type: application/json' \
  -d '{"text":"Email alice@example.com or call 555-123-4567"}'
```

---

## Configuration

### Config file

`~/.config/privacy-filter/config.toml` — created by `install/install-service.sh`.

Override path with `PRIVACY_FILTER_CONFIG` env var.

### Config schema (actual code defaults)

```toml
[service]
host = "0.0.0.0"
port = 8765
device = "cuda"             # "cuda" or "cpu"
output_mode = "typed"       # "typed" or "redacted"
decode_mode = "viterbi"     # "viterbi" or "argmax"
model_path = ""             # REQUIRED (or set OPF_CHECKPOINT env)
log_level = "INFO"

[hook]
base_url = "http://127.0.0.1:8765"
request_timeout_s = 5.0     # 1-60
max_file_bytes = 262144     # <= 1048576
max_inflight_warns_per_5min = 1
```

### Environment variable overrides

| Env var | Maps to | Type |
|---------|---------|------|
| `PRIVACY_FILTER_LISTEN_HOST` | `service.host` | str |
| `PRIVACY_FILTER_LISTEN_PORT` | `service.port` | int |
| `PRIVACY_FILTER_DEVICE` | `service.device` | str |
| `PRIVACY_FILTER_OUTPUT_MODE` | `service.output_mode` | str |
| `PRIVACY_FILTER_DECODE_MODE` | `service.decode_mode` | str |
| `PRIVACY_FILTER_MODEL_PATH` | `service.model_path` | str |
| `PRIVACY_FILTER_LOG_LEVEL` | `service.log_level` | str |
| `PRIVACY_FILTER_URL` | `hook.base_url` | str |
| `PRIVACY_FILTER_TIMEOUT_S` | `hook.request_timeout_s` | float |
| `PRIVACY_FILTER_MAX_FILE_BYTES` | `hook.max_file_bytes` | int |
| `PRIVACY_FILTER_MAX_INFLIGHT_WARNS` | `hook.max_inflight_warns_per_5min` | int |
| `OPF_CHECKPOINT` | `service.model_path` (fallback) | str |

Resolution: TOML → `PRIVACY_FILTER_*` env → `OPF_CHECKPOINT` fallback.

### Validation

- `port`: 1–65535
- `device`: `cuda` or `cpu` (no silent fallback to cpu)
- `output_mode`: `typed` or `redacted`
- `decode_mode`: `viterbi` or `argmax`
- `max_file_bytes`: ≤ 1MB
- `request_timeout_s`: 1–60
- `model_path`: **required** — crashes with `SystemExit` on missing/invalid config

---

## API Endpoints

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/health` | — | `HealthResponse` (200/503) | Readiness probe |
| GET | `/model-info` | — | `ModelInfoResponse` (200/503) | Model metadata (no model_path) |
| POST | `/redact` | `RedactRequest` | `RedactionResult` (200/413/503) | Full redaction with spans |
| POST | `/redact/text` | `RedactRequest` | plain text (200/413/503) | Redacted text only |
| POST | `/redact/batch` | `RedactBatchRequest` | `list[RedactionResult]` (200/413/422/503) | Batch redaction |

Full API reference: `docs/llms-full.txt`

---

## PII Labels (8 types)

| Label | Description | Example |
|-------|-------------|---------|
| `account_number` | Bank/account numbers | `1234567890` |
| `private_address` | Physical addresses | `123 Main St` |
| `private_email` | Email addresses | `alice@example.com` |
| `private_person` | Person names | `Alice Smith` |
| `private_phone` | Phone numbers | `555-123-4567` |
| `private_url` | URLs | `https://example.com` |
| `private_date` | Dates (birth, etc.) | `1990-01-02` |
| `secret` | API keys, passwords | `sk-abc123...` |

---

## Git Hooks

### Pre-commit (`hooks/pre-commit`)

Scans fully-staged text files for PII. On detection:
- Generates `.git/privacy-filter/redact-<ts>-<pid>.patch`
- Blocks commit (exit 1) with apply instructions
- User reviews patch, applies with `git apply --index`

**Skips**: binary, symlink, submodule, LFS pointer, oversized (>256KB), non-UTF-8, partially-staged files.

### Commit-msg (`hooks/commit-msg`)

Auto-redacts PII in commit message body. Preserves `#` comments and `------ >8 ------` verbose section. Always exits 0 (non-fatal).

### Shared library (`hooks/_lib.sh`)

Key functions: `pf_url`, `pf_skip_active`, `pf_is_text_file`, `pf_is_lfs_pointer`, `pf_too_large`, `pf_post_json`, `pf_warn_once`, `pf_fail_open`, `pf_ensure_dir`, `pf_service_ready`, `pf_cleanup_old_patches`.

### Bypass

```bash
PRIVACY_FILTER_SKIP=1 git commit -m "skip"   # env var
git commit --no-verify -m "skip"              # git flag
```

---

## Testing

### Test pyramid

| Level | Command | Count | GPU | Isolation |
|-------|---------|-------|-----|-----------|
| Unit (pytest) | `uv run pytest -q` | 68 | No | In-process |
| GPU (pytest) | `uv run pytest -q -m gpu` | 1 | Yes | In-process |
| Integration | `bash tests/integration/run_all.sh` | 13 | No | `/tmp` repos |
| E2E | `bash tests/e2e/smoke.sh` | 7 | No | Full lifecycle |

### Integration test details

Each test creates an isolated repo in `/tmp/pf-it-<name>-<rand>/` with its own `GIT_CONFIG_GLOBAL` (no pollution of real `~/.gitconfig`). Tests cover: clean commit, PII commit + patch apply, partial staging abort, binary skip, oversize skip, LFS pointer skip, commit-msg redact/clean/comment, service-down fail-open, skip bypass, no-verify bypass, concurrent commits, installer collision/force/uninstall.

### Writing new tests

- pytest tests: add to `tests/test_*.py`, use `httpx.AsyncClient` with `ASGITransport` for in-process testing. Mock `OPFEngine` to avoid GPU dependency.
- Integration tests: add to `tests/integration/test_*.sh`, source `common.sh` for helpers, use `GIT_CONFIG_GLOBAL` isolation.
- Mark GPU tests with `@pytest.mark.gpu`.

---

## Deployment

### Install service

```bash
cd ~/project/docker/privacy-filter-service
bash install/install-service.sh
```

This: validates prereqs → creates venv → installs deps → deploys config.toml + env → installs systemd unit → starts service → waits for health → offers `loginctl enable-linger`.

### Install hooks

```bash
bash install/install-hooks.sh
```

This: checks `core.hooksPath` collision → copies hooks → sets `core.hooksPath`. Use `--force` to override existing path.

### Current deployment state

```
Service:   systemctl --user is-active privacy-filter.service → active
Config:    ~/.config/privacy-filter/config.toml (device=cuda, output_mode=typed)
Env:       ~/.config/privacy-filter/env (all commented = using toml defaults)
Unit:      ~/.config/systemd/user/privacy-filter.service
Hooks:     ~/.config/git/hooks/{pre-commit, commit-msg, _lib.sh}
hooksPath: /home/chriswang/.config/git/hooks
Model:     /mnt/LLM/OpenAI/privacy_filter (RTX 3090)
```

### Operate

```bash
systemctl --user start privacy-filter
systemctl --user stop privacy-filter
systemctl --user restart privacy-filter
systemctl --user status privacy-filter
journalctl --user -u privacy-filter -f
journalctl --user -u privacy-filter --since '5 minutes ago'
```

### Uninstall

```bash
bash install/uninstall.sh
```

Preserves `~/.config/privacy-filter/config.toml` and `env`.

---

## Error Handling

| Status | Meaning | When |
|--------|---------|------|
| 200 | Success | Normal |
| 413 | Payload too large | Text > `max_file_bytes` or batch > 100 |
| 422 | Validation error | Invalid JSON, missing fields, batch > 100 |
| 503 | Not ready | Engine warming up or startup failure |

Hook fail-open: connection refused / timeout / 5xx / malformed JSON → warn + exit 0.

---

## Logging

Structured JSON to stdout. Fields: `timestamp`, `level`, `logger`, `request_id`, `msg`, `span_count`, `duration_ms`.

Redacted fields (replaced with `<REDACTED>`): `text`, `message`, `content`, `payload`, `redacted_text`, `detected_spans`, `placeholder`.

Uvicorn access log: disabled. Exception tracebacks: redacted.

---

## Rules for Agents

1. **Never hardcode runtime parameters** in source code. Load from `config.toml` or env vars.
2. **Use `uv`** for package management, not raw `pip`.
3. **Single uvicorn worker** — model not validated for concurrency.
4. **No raw text in logs** — use `RedactFilter`, never `log.info(text)`.
5. **Fail-open** — service down should never block developer workflow.
6. **No `model_path` in API responses** — security: avoid leaking filesystem layout.
7. **`model_path` is required** — no silent fallback to `~/.opf/`.
8. **CUDA validation** — fail-fast at startup, not per-request.
9. **Test isolation** — integration tests use `GIT_CONFIG_GLOBAL` + `/tmp` repos.
10. **`PRIVACY_FILTER_SKIP=1`** — always support bypass mechanism.
