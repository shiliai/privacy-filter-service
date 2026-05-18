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

**Fail-open**: 服务不可用时，hook 打印警告并放行，不会阻塞开发流程。

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
model_path = ""             # 必填 — OPF 模型路径 (或设 OPF_CHECKPOINT 环境变量)
log_level = "INFO"          # Python 日志级别

[hook]
base_url = "http://127.0.0.1:8765"  # hook 调用的服务地址
request_timeout_s = 5.0             # hook HTTP 超时 (1-60 秒)
max_file_bytes = 262144             # hook 发送的最大文件大小 (≤ 1MB)
max_inflight_warns_per_5min = 1     # 警告频率限制
```

### 环境变量覆盖

任何配置项都可通过环境变量覆盖。复制 `config/env.example` 到 `~/.config/privacy-filter/env`，取消注释需要的行。systemd unit 自动加载此文件。

| 环境变量 | 对应配置项 | 类型 |
|---------|-----------|------|
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
- **配置文件不存在** — 重新运行 `install/install-service.sh`

### Hook 冲突

如果某些仓库已使用 Husky、pre-commit 或 Lefthook，全局 `core.hooksPath` 会覆盖它们的 hooks。解决方案:

```bash
install/install-hooks.sh --force   # 备份旧路径并切换
PRIVACY_FILTER_SKIP=1 git commit   # 在那些仓库跳过 privacy-filter
```

### Fail-open 警告

服务不可用时，hook 打印警告并放行提交。这是设计行为，不会阻塞你的工作。检查 `journalctl` 了解原因。

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
```

停止服务、删除 unit 文件、取消 `core.hooksPath`、删除 hooks。保留 `~/.config/privacy-filter/config.toml` 和 `env`。

---

## 许可证

MIT
