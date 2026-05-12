# Privacy Filter Service

A local FastAPI service that wraps the OPF privacy-filter model. It scans staged files and commit messages for PII before you commit, blocks the commit if anything is found, and writes a patch you can review and apply. Everything runs on your machine. No data leaves the box.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| GPU | Optional. CUDA is supported; CPU fallback works fine. |
| Python | 3.10 or newer |
| Package manager | [uv](https://docs.astral.sh/uv/) |
| OPF library | Installed as an editable dependency from `file:///home/chriswang/project/docker/privacy-filter` |
| Model checkpoint | `/mnt/LLM/OpenAI/privacy_filter` must exist |

---

## Install

```bash
# 1. Clone the repository
git clone <repo-url> ~/project/docker/privacy-filter-service
cd ~/project/docker/privacy-filter-service

# 2. Install the service (creates venv, deploys config, starts systemd user service)
bash install/install-service.sh

# 3. Install the git hooks globally
bash install/install-hooks.sh
```

---

## Verify

Check that the service is up:

```bash
curl -s http://127.0.0.1:8765/health | python3 -m json.tool
curl -s http://127.0.0.1:8765/model-info | python3 -m json.tool
```

Test the pre-commit hook with a real commit:

```bash
echo "my email is alice@example.com" > test.txt
git add test.txt
git commit -m "test commit"
```

The hook should block the commit, print a patch path, and tell you how to apply it.

---

## Configuration

The service reads `~/.config/privacy-filter/config.toml`. It is created for you during install if it does not exist.

| Section | Key | Default | Description |
|---------|-----|---------|-------------|
| `service` | `host` | `0.0.0.0` | Listen address |
| `service` | `port` | `8765` | Listen port (1-65535) |
| `service` | `device` | `cpu` | `cuda` or `cpu` |
| `service` | `output_mode` | `redacted` | `typed` or `redacted` |
| `service` | `decode_mode` | `viterbi` | `viterbi` or `argmax` |
| `service` | `model_path` | *(required)* | Path to OPF checkpoint |
| `service` | `log_level` | `INFO` | Python logging level |
| `hook` | `base_url` | `http://127.0.0.1:8765` | Service URL the hook calls |
| `hook` | `request_timeout_s` | `5.0` | Hook HTTP timeout (1-60) |
| `hook` | `max_file_bytes` | `262144` | Max file size the hook sends (<= 1 MB) |
| `hook` | `max_inflight_warns_per_5min` | `1` | Rate limit for inflight warnings |

You can also override any value with environment variables. Copy `config/env.example` to `~/.config/privacy-filter/env` and uncomment the lines you need. The systemd unit loads this file automatically.

Environment variable overrides are loaded from `~/.config/privacy-filter/env`.

---

## Operate

```bash
# Start the service
systemctl --user start privacy-filter

# Stop the service
systemctl --user stop privacy-filter

# Check status
systemctl --user status privacy-filter

# Restart after config changes
systemctl --user restart privacy-filter

# Follow logs
journalctl --user -u privacy-filter -f
```

---

## Bypass

Skip the hooks for a single command:

```bash
PRIVACY_FILTER_SKIP=1 git commit -m "emergency fix"
```

Or bypass git hooks entirely:

```bash
git commit --no-verify -m "emergency fix"
```

---

## Troubleshooting

### Service won't start

Run `journalctl --user -u privacy-filter -n 50` and look for:

- **Model directory not found** — make sure `/mnt/LLM/OpenAI/privacy_filter` exists.
- **CUDA requested but not available** — switch to `device = "cpu"` in `~/.config/privacy-filter/config.toml`.
- **Config file not found** — the install script should create it. Run `install/install-service.sh` again if needed.

### Hook collisions

If you already use Husky, pre-commit, or Lefthook in some repos, the global `core.hooksPath` may override per-repo hooks. The installer warns you when it detects these tools. You have two options:

1. Run `install/install-hooks.sh --force` to back up the old path and switch.
2. Skip the privacy-filter hook in those repos with `PRIVACY_FILTER_SKIP=1`.

### Fail-open warnings

If the service is down or not ready, the hook prints a warning and allows the commit. This is intentional so a broken service does not block your work. Check `journalctl` to see why the service is unhealthy.

### Partial-staging error

The hook does not support partially staged files. If a file has both staged and unstaged changes, the commit is rejected with:

```
Partial staging not supported in v1. Either fully stage (git add <file>) or unstage (git restore --staged <file>).
```

---

## Known Limitations

- **UTF-8 only** — Files are checked with `file --mime-encoding`. Anything that is not `utf-8` or `us-ascii` is skipped.
- **No partial staging** — You must fully stage or fully unstage a file.
- **No IDE or GUI testing** — Hooks are tested with the git CLI only. GUI clients may behave differently.
- **Single process** — The service runs one worker. Concurrent requests are serialized.
- **256 KB file limit** — Files larger than `max_file_bytes` (default 262144) are skipped.

---

## Uninstall

```bash
bash install/uninstall.sh
```

This stops and disables the systemd service, removes the unit file, unsets `core.hooksPath`, and deletes the hooks. Your `~/.config/privacy-filter/config.toml` and `~/.config/privacy-filter/env` files are preserved.

---

## PII Labels

The model detects and redacts the following 8 labels:

1. `account_number`
2. `private_address`
3. `private_email`
4. `private_person`
5. `private_phone`
6. `private_url`
7. `private_date`
8. `secret`

---

## Architecture

```
+------------------+        HTTP POST         +-------------------------+
|  git pre-commit  |  --------------------->  |  Privacy Filter Service |
|  git commit-msg  |  /redact  /redact/text   |  (FastAPI + OPF model)  |
+------------------+                          +-------------------------+
        |                                               |
        | blocks commit + writes patch                  | loads model at startup
        v                                               v
   redact-*.patch (in .git/privacy-filter/)      ~/.config/privacy-filter/config.toml
```

---

## License

MIT
