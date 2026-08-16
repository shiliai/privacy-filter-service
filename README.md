# Privacy Filter Service

本地 FastAPI 服务，包装 OPF (OpenAI Privacy Filter) 模型。提交代码前自动扫描暂存文件和提交信息中的 PII（个人身份信息），发现则阻止提交并生成 patch 供审查。所有推理在本地完成，数据不出机器。

---

## 快速开始

```bash
# 克隆
git clone git@github.com:shiliai/privacy-filter-service.git ~/project/docker/privacy-filter-service
cd ~/project/docker/privacy-filter-service

# 安装服务（创建 venv、部署配置、启动 systemd 用户服务）
bash install/install-service.sh

# 安装全局 git hooks
bash install/install-hooks.sh
```

验证：

```bash
curl -fsS http://127.0.0.1:8765/health | jq .
# → {"ready":true,"device":"cuda","uptime_s":...,"version":"0.1.0"}

curl -fsS -X POST http://127.0.0.1:8765/redact/text \
  -H 'Content-Type: application/json' \
  -d '{"text":"Email alice@example.com"}'
# → Email <PRIVATE_EMAIL>
```

---

## 工作原理

```
┌──────────────────────┐        HTTP POST        ┌──────────────────────────┐
│   git pre-commit     │  ─────────────────────>  │  Privacy Filter Service  │
│   git commit-msg     │  /redact  /redact/text   │  FastAPI + OPF model     │
└──────────────────────┘  /redact/batch           │  单 worker :8765         │
         │                                        └──────────────────────────┘
         │ 阻止提交 + 生成 patch                              │
         v                                                   v
   .git/privacy-filter/                          /mnt/LLM/OpenAI/privacy_filter
   redact-<ts>-<pid>.patch                       (RTX 3090 GPU)
```

**pre-commit hook**: 扫描暂存文件 → 发现 PII → 生成 `.patch` 文件 → 阻止提交 → 用户审查后 `git apply --index` 应用。

**commit-msg hook**: 自动改写提交信息中的 PII（如 `alice@example.com` → `<PRIVATE_EMAIL>`）。始终 exit 0，不阻止提交。

**Fail-closed**: 服务不可用时先使用本地 fallback；无法完成脱敏验证时默认阻止提交。只有显式设置 `PRIVACY_FILTER_FAIL_OPEN=1` 才放行。

---

## 配置

配置文件: `~/.config/privacy-filter/config.toml`

```toml
[service]
host = "0.0.0.0"           # 监听地址
port = 8765                 # 监听端口 (1-65535)
device = "cuda"             # "cuda" 或 "cpu"
output_mode = "typed"       # "typed" (带标签) 或 "redacted" (折叠)
decode_mode = "viterbi"     # "viterbi" 或 "argmax"
decode_backend = "upstream" # "upstream" 或 "jit_gpu"
model_path = ""             # 必填 — OPF 模型路径 (或设 OPF_CHECKPOINT 环境变量)
log_level = "INFO"          # Python 日志级别

[hook]
base_url = "http://127.0.0.1:8765"  # hook 调用的服务地址
request_timeout_s = 5.0             # hook HTTP 超时 (1-60 秒)
max_file_bytes = 262144             # hook 发送的最大文件大小 (≤ 1MB)
max_inflight_warns_per_5min = 1     # 警告频率限制
```

推荐按部署环境选择以下三种配置：

| 场景 | `device` | `decode_backend` | `max_file_bytes` | 说明 |
|---|---|---|---:|---|
| 当前/本地 GPU host | `cuda` | `upstream` | `262144` | GPU forward + upstream CPU Viterbi，RTX 3090 本机最快 |
| 多租户 GPU host | `cuda` | `jit_gpu` | `262144` | GPU forward + GPU JIT Viterbi，用于避免 A6000/VLLM 上的 CPU decode 尾延迟 |
| CPU-only host | `cpu` | `upstream` | `1024` | 全 CPU 推理很慢，服务启动时强制 `max_file_bytes <= 1024` |

### 部署前检查

部署或改配置前先确认当前环境，不要直接覆盖已有配置：

```bash
systemctl --user is-active privacy-filter.service || true
test -f ~/.config/privacy-filter/config.toml && sed -n '1,80p' ~/.config/privacy-filter/config.toml
curl -fsS http://127.0.0.1:8765/model-info 2>/dev/null | jq '{device, decode_mode, decode_backend}' || true
nvidia-smi || true
```

选择配置时遵循：

- 没有可用 CUDA GPU：使用 CPU-only profile，并保持 `max_file_bytes = 1024`。
- 共享 GPU / VLLM / hook 尾延迟敏感 host：优先测试 `decode_backend = "jit_gpu"`。
- 独占或本地 GPU host：先用默认 `decode_backend = "upstream"`，只有 benchmark 显示尾延迟风险时再切 JIT。

`install/install-service.sh` 会按顺序查找模型路径：`PRIVACY_FILTER_MODEL_PATH`、`OPF_CHECKPOINT`、已有 `config.toml` 的 `service.model_path`、`/mnt/LLM/OpenAI/privacy_filter`、`~/.opf/privacy_filter`。新装配置会自动写入解析到的路径；如果模型不在这些位置，先设置环境变量或编辑配置再启动服务。安装脚本默认等待服务健康最多 120 秒，可用 `PRIVACY_FILTER_INSTALL_HEALTH_TIMEOUT_S` 覆盖。

安装或修改配置后，确认功能和性能：

```bash
curl -fsS http://127.0.0.1:8765/health | jq .
curl -fsS http://127.0.0.1:8765/model-info | jq '{device, decode_mode, decode_backend}'
curl -fsS -X POST http://127.0.0.1:8765/redact/text \
  -H 'Content-Type: application/json' \
  -d '{"text":"Email alice@example.com or call 555-123-4567"}'
```

GPU host 可跑小 benchmark：

```bash
PYTHONPATH=src .venv/bin/python scripts/benchmark.py \
  --skip-cpu --gpu-sizes 10,50,100 \
  --output /tmp/privacy-filter-benchmark.json
```

共享 GPU host 再补尾延迟 benchmark：

```bash
PYTHONPATH=src .venv/bin/python scripts/benchmark_tail_latency.py \
  --sizes 10,50,100 --num-runs 10 \
  --output /tmp/privacy-filter-tail-latency.json
```

CPU-only host 不要跑 GPU benchmark；只用小文本 HTTP smoke，并验证超过 `max_file_bytes` 的请求会快速返回 413。

### 环境变量覆盖

任何配置项都可通过环境变量覆盖。复制 `config/env.example` 到 `~/.config/privacy-filter/env`，取消注释需要的行。systemd unit 自动加载此文件。

| 环境变量 | 对应配置项 | 类型 |
|---------|-----------|------|
| `PRIVACY_FILTER_LISTEN_HOST` | `service.host` | str |
| `PRIVACY_FILTER_LISTEN_PORT` | `service.port` | int |
| `PRIVACY_FILTER_DEVICE` | `service.device` | str |
| `PRIVACY_FILTER_OUTPUT_MODE` | `service.output_mode` | str |
| `PRIVACY_FILTER_DECODE_MODE` | `service.decode_mode` | str |
| `PRIVACY_FILTER_DECODE_BACKEND` | `service.decode_backend` | str |
| `PRIVACY_FILTER_MODEL_PATH` | `service.model_path` | str |
| `PRIVACY_FILTER_LOG_LEVEL` | `service.log_level` | str |
| `PRIVACY_FILTER_URL` | `hook.base_url` | str |
| `PRIVACY_FILTER_TIMEOUT_S` | `hook.request_timeout_s` | float |
| `PRIVACY_FILTER_MAX_FILE_BYTES` | `hook.max_file_bytes` | int |
| `OPF_CHECKPOINT` | `service.model_path` (后备) | str |

加载优先级: TOML → `PRIVACY_FILTER_*` 环境变量 → `OPF_CHECKPOINT` 后备。

---

## 服务管理

```bash
systemctl --user start privacy-filter      # 启动
systemctl --user stop privacy-filter       # 停止
systemctl --user restart privacy-filter    # 重启（改配置后）
systemctl --user status privacy-filter     # 状态
journalctl --user -u privacy-filter -f     # 跟踪日志
journalctl --user -u privacy-filter --since '5 minutes ago'  # 最近日志
```

开机自启（可选）:

```bash
loginctl enable-linger $USER
```

---

## API

### GET /health

```bash
curl -fsS http://127.0.0.1:8765/health
```

```json
{"ready": true, "device": "cuda", "uptime_s": 42.15, "version": "0.1.0"}
```

服务启动期间（模型加载约 20s）返回 503 + `{"ready": false}`。

### GET /model-info

```bash
curl -fsS http://127.0.0.1:8765/model-info
```

```json
{
  "device": "cuda",
  "labels": ["account_number", "private_address", "private_email", "private_person", "private_phone", "private_url", "private_date", "secret"],
  "output_mode": "typed",
  "decode_mode": "viterbi",
  "decode_backend": "upstream",
  "version": "0.1.0"
}
```

注意: 响应不包含 `model_path`（安全考虑）。

### POST /redact

返回完整结构化结果（含检测到的 span）。

```bash
curl -fsS -X POST http://127.0.0.1:8765/redact \
  -H 'Content-Type: application/json' \
  -d '{"text":"Email alice@example.com or call 555-123-4567"}'
```

```json
{
  "text": "Email alice@example.com or call 555-123-4567",
  "redacted_text": "Email <PRIVATE_EMAIL> or call <PRIVATE_PHONE>",
  "detected_spans": [
    {"label": "private_email", "start": 6, "end": 23, "text": "alice@example.com", "placeholder": "<PRIVATE_EMAIL>"},
    {"label": "private_phone", "start": 32, "end": 44, "text": "555-123-4567", "placeholder": "<PRIVATE_PHONE>"}
  ],
  "summary": {"output_mode": "typed", "span_count": 2, "by_label": {"private_email": 1, "private_phone": 1}, "decoded_mismatch": false},
  "schema_version": 1,
  "warning": null
}
```

### POST /redact/text

只返回脱敏后的纯文本。Hook 使用此端点。

```bash
curl -fsS -X POST http://127.0.0.1:8765/redact/text \
  -H 'Content-Type: application/json' \
  -d '{"text":"Alice was born 1990-01-02"}'
```

```
<PRIVATE_PERSON> was born <PRIVATE_DATE>
```

### POST /redact/batch

批量处理，返回结果数组（顺序与输入一致）。最多 100 条。

```bash
curl -fsS -X POST http://127.0.0.1:8765/redact/batch \
  -H 'Content-Type: application/json' \
  -d '{"texts":["Hello","alice@example.com","555-123-4567"]}'
```

### 错误码

| 状态码 | 含义 | 场景 |
|--------|------|------|
| 200 | 成功 | 正常 |
| 413 | 超大 | 文本 > max_file_bytes 或 batch > 100 |
| 422 | 验证失败 | JSON 格式错误、缺少字段 |
| 503 | 未就绪 | 模型加载中 |

---

## PII 标签

模型检测并脱敏以下 8 类 PII:

| 标签 | 说明 | 示例 |
|------|------|------|
| `account_number` | 银行/账号 | `1234567890` |
| `private_address` | 物理地址 | `123 Main St, Springfield` |
| `private_email` | 邮箱 | `alice@example.com` |
| `private_person` | 人名 | `Alice Smith` |
| `private_phone` | 电话 | `555-123-4567` |
| `private_url` | URL | `https://example.com/profile` |
| `private_date` | 日期（生日等） | `1990-01-02` |
| `secret` | 密钥、密码 | `sk-abc123...` |

---

## 跳过检查

单次跳过:

```bash
PRIVACY_FILTER_SKIP=1 git commit -m "紧急修复"
```

完全绕过 git hooks:

```bash
git commit --no-verify -m "紧急修复"
```

---

## 故障排除

### 服务启动失败

```bash
journalctl --user -u privacy-filter -n 50
```

常见原因:
- **模型目录不存在** — 确认 `/mnt/LLM/OpenAI/privacy_filter` 存在
- **CUDA 不可用** — 改 `device = "cpu"` 或检查 GPU 驱动
- **CPU 配置过大** — `device = "cpu"` 时必须设置 `max_file_bytes <= 1024`
- **配置文件不存在** — 重新运行 `install/install-service.sh`

### Hook 完整性与冲突

`install/install-hooks.sh` 使用独立的 `~/.config/privacy-filter/git-hooks` 作为全局 dispatcher root。OPF 始终先执行，随后按原退出码执行安装前 `core.hooksPath` 中的同名 hook（Lefthook、Husky 或 pre-commit）。如果 delegate 改变 staged tree 或 commit message，dispatcher 会再运行一次 OPF。原目录不会被覆盖。安装后 dispatcher root 为只读/可执行，普通 postinstall 对该目录的写入会失败而不是静默替换 OPF。后装工具不会自动加入组合；应把它的 hook 安装或恢复到 state/doctor 显示的 delegate 路径，再用干净提交验证两者执行。若保留的自定义 wrapper 本身也调用 OPF，installer 和 doctor 会警告；该 wrapper 会导致 OPF 重复执行，系统不会尝试剥离任意自定义逻辑。

```bash
bash install/install-hooks.sh --doctor
```

doctor 会检查有效的（包含仓库本地/worktree 配置）`core.hooksPath`、文件校验和及目录权限，并输出当前 delegate 路径。重装可修复受损 dispatcher；卸载会恢复先前的全局 hooksPath，且不会删除原 hook 目录。相对 delegate 按每个仓库根目录解析，因此 host 级 doctor 只能报告该路径，不能断言每个仓库都存在它。

这不是特权安全边界：`git commit --no-verify`、仓库本地 `core.hooksPath`，或能够 `chmod` 该目录的同一用户仍可绕过 hook。应将 doctor 纳入主机巡检。

```bash
install/install-hooks.sh --doctor  # 检查 dispatcher 未被绕过或修改
PRIVACY_FILTER_SKIP=1 git commit   # 在那些仓库跳过 privacy-filter
```

### 三台主机的受控 hooks 自更新

以下流程只更新 hooks，不更新服务、依赖、unit 或服务配置。它只适用于已获准的维护窗口；当前未批准时不执行。按 `host-a`（canary）→ `host-b` → `host-c` 的顺序执行，任何一步的停止条件触发时，不再继续下一台。

1. 在每台主机开始前记录并固定回退 revision，并备份现有 hook 配置和受管 state：

   ```bash
   prior_revision="$(git rev-parse HEAD)"
   if [ -n "$(git status --porcelain)" ]; then
     printf 'ERROR: worktree is not clean; stopping hooks rollout\n' >&2
     exit 1
   fi
   git rev-parse HEAD > ~/.config/privacy-filter/previous-revision
   git config --global --get core.hooksPath > ~/.config/privacy-filter/previous-hooks-path 2>/dev/null || true
   cp ~/.config/privacy-filter/git-hooks/.privacy-filter-hooks-state ~/.config/privacy-filter/hooks-state.backup 2>/dev/null || true
   ```

2. 检出经审查的 revision，只安装 hooks，再逐项验证：

   ```bash
   git checkout <approved-revision>
   bash install/install-hooks.sh
   bash install/install-hooks.sh --doctor
   ```

3. 在临时仓库做不产生提交的 secret smoke。下面的提交必须被阻止，随后检查 `HEAD` 仍不存在：

   ```bash
   (
     set -euo pipefail
     smoke_dir="$(mktemp -d)"
     trap 'rm -rf "$smoke_dir"' EXIT
     smoke_log="$smoke_dir/commit.log"
     git -C "$smoke_dir" init
     git -C "$smoke_dir" config user.name smoke
     git -C "$smoke_dir" config user.email smoke@example.invalid
     printf 'token = "AKIAFAKEFAKEFAKEFAKE"\n' > "$smoke_dir/secret.txt"  # fake fixture
     git -C "$smoke_dir" add secret.txt
     if git -C "$smoke_dir" commit -m 'secret smoke' >"$smoke_log" 2>&1; then
       printf 'ERROR: privacy-filter allowed the fake secret smoke\n' >&2
       exit 1
     fi
     if ! grep -qF '[privacy-filter] blocked commit: detected PII' "$smoke_log"; then
       cat "$smoke_log" >&2
       printf 'ERROR: commit failed without the privacy-filter PII block marker\n' >&2
       exit 1
     fi
     if ! find "$smoke_dir/.git/privacy-filter" -type f -name 'redact-*.patch' -print -quit | grep -q .; then
       printf 'ERROR: privacy-filter did not generate a redaction patch\n' >&2
       exit 1
     fi
     if git -C "$smoke_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
       printf 'ERROR: secret smoke unexpectedly created HEAD\n' >&2
       exit 1
     fi
   )
   ```

停止条件：clean-worktree 断言或 doctor 失败、secret smoke 创建了提交、delegate 未按 doctor 输出运行、或 hooks 安装修改了未预期文件。发生时立即停止后续主机，并在当前主机执行已验证的 hooks-only 回退：

```bash
bash install/uninstall.sh --hooks-only
test "$(git config --global --get core.hooksPath 2>/dev/null || true)" = "$(cat ~/.config/privacy-filter/previous-hooks-path 2>/dev/null || true)"
git checkout "$(cat ~/.config/privacy-filter/previous-revision)"
```

回退后确认 hooks-only 命令返回成功、全局 hooksPath 已恢复，并保留上面创建的外部 backup/state 副本供排查。只有 canary 的全部检查通过，才按同一 pinned revision 推进到下一台主机。

### 服务不可用

服务不可用时，hook 默认使用本地 fallback 并 fail-closed，不会静默放行未验证的提交。只有显式设置 `PRIVACY_FILTER_FAIL_OPEN=1` 才会允许未脱敏提交；`PRIVACY_FILTER_SKIP=1` 是另一种显式绕过。检查 `journalctl` 了解原因。

### Partial staging 错误

不支持部分暂存的文件。如果文件同时有暂存和未暂存的更改:

```
Partial staging not supported in v1. Either fully stage (git add <file>) or unstage (git restore --staged <file>).
```

---

## 已知限制

- **仅 UTF-8** — 通过 `file --mime-encoding` 检测，非 utf-8/us-ascii 的文件被跳过
- **不支持部分暂存** — 必须完全暂存或完全取消暂存
- **仅 CLI 测试** — hooks 仅在 git CLI 测试过，GUI 客户端行为可能不同
- **单进程** — 服务运行单个 worker，请求串行处理
- **256KB 文件限制** — 超过 `max_file_bytes`（默认 262144）的文件被跳过
- **CPU-only 限制** — `device = "cpu"` 时 `max_file_bytes` 最高为 1024 bytes

---

## 开发

```bash
cd ~/project/docker/privacy-filter-service

# 创建 venv
uv venv .venv --python 3.10

# 安装依赖
uv pip install -e ".[dev]"

# 运行测试
uv run pytest -q                    # 68 个测试，不需要 GPU
uv run pytest -q -m gpu             # 1 个 GPU 测试
uv run ruff check src/              # lint

# 本地启动服务
OPF_CHECKPOINT=/mnt/LLM/OpenAI/privacy_filter \
  uvicorn privacy_filter_service.app:create_app --factory --host 127.0.0.1 --port 8765
```

---

## 卸载

```bash
bash install/uninstall.sh
# 仅回滚 hooks，保持 privacy-filter 服务运行
bash install/uninstall.sh --hooks-only
```

完整卸载会停止服务、删除 unit，并恢复安装前的全局 `core.hooksPath`；`--hooks-only` 只恢复 hook 配置和受管文件。两者都保留原 delegate 目录、`config.toml` 和 `env`。

---

## 许可证

MIT
