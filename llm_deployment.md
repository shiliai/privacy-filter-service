# Privacy Filter Service — LLM Agent 部署指南

> 本文档供 AI Agent 使用，指导客户部署 Privacy Filter Service。
> Agent 必须先询问客户两个关键问题，再根据回答选择对应的部署路径。

---

## 前置确认（MUST ASK FIRST）

在开始任何部署操作之前，**必须**向客户确认以下两个问题：

### 问题 1：是否已有运行中的 OPF 服务？

```
您的环境中是否已经部署了 Privacy Filter Service（OPF 服务）？
可以通过以下命令验证：
  curl -fsS http://127.0.0.1:8765/health

- 如果返回 {"ready": true, ...} → 已有服务，跳过服务部署步骤
- 如果连接失败 → 需要部署服务
- 如果有服务但在不同地址/端口 → 需要确认地址
```

**选项**：
- **A) 已有服务** — 仅安装 git hooks，配置 `hook.base_url` 指向现有服务地址
- **B) 没有服务** — 完整部署（服务 + hooks）
- **C) 有服务但地址不同** — 仅安装 hooks，配置自定义 `hook.base_url`

### 问题 2：Git Hooks 作用范围？

```
您希望 Privacy Filter 的 git hooks 作用于：

A) 全局（所有 git 仓库）— 通过 core.hooksPath 实现
   - 优点：一次安装，所有仓库受保护
   - 缺点：会覆盖已有的全局 hooks（如 Husky、Lefthook 的全局配置）
   - 适合：个人开发机、无其他全局 hook 管理器的环境

B) 指定仓库 — 将 hooks 复制到仓库的 .git/hooks/
   - 优点：不影响其他仓库，与 Husky/Lefthook 共存
   - 缺点：每个仓库需单独安装
   - 适合：已有全局 hook 管理器、或只想保护特定仓库
```

---

## 系统要求

| 项目 | 要求 |
|------|------|
| OS | Linux（已验证 Ubuntu） |
| Python | 3.10 |
| GPU（推荐） | NVIDIA GPU + CUDA 11.8（也可用 CPU，速度较慢） |
| 包管理器 | [uv](https://docs.astral.sh/uv/) |
| 服务管理 | systemd（用户会话） |
| OPF 模型 | `/mnt/LLM/OpenAI/privacy_filter`（或自定义路径） |

---

## 部署路径 A：完整部署（服务 + Hooks）

适用于：**没有现有 OPF 服务** + **全局或指定仓库 hooks**

### 步骤 1：获取项目

```bash
git clone git@github.com:shiliai/privacy-filter-service.git ~/project/docker/privacy-filter-service
cd ~/project/docker/privacy-filter-service
```

### 步骤 2：安装 Python 依赖

```bash
uv venv .venv --python 3.10
uv sync
```

验证：

```bash
.venv/bin/privacy-filter-service --help  # 确认可执行
```

### 步骤 3：部署服务配置

配置文件位置：`~/.config/privacy-filter/config.toml`

**方式 A：使用安装脚本（推荐）**

```bash
bash install/install-service.sh
```

脚本会自动：
- 检查 uv、systemd、模型目录
- 创建配置目录和 systemd unit
- 启动服务并等待健康检查通过
- 提示是否启用 `loginctl enable-linger`（开机自启）

**方式 B：手动配置**

```bash
mkdir -p ~/.config/privacy-filter
cp config.toml.example ~/.config/privacy-filter/config.toml
```

编辑 `~/.config/privacy-filter/config.toml`，**必须设置 `model_path`**：

```toml
[service]
host = "0.0.0.0"
port = 8765
device = "cuda"             # 无 GPU 改为 "cpu"
output_mode = "typed"
decode_mode = "viterbi"
model_path = "/mnt/LLM/OpenAI/privacy_filter"   # 必填！
log_level = "INFO"

[hook]
base_url = "http://127.0.0.1:8765"
request_timeout_s = 5.0
max_file_bytes = 262144
max_inflight_warns_per_5min = 1
```

环境变量覆盖（可选）：复制 `config/env.example` 到 `~/.config/privacy-filter/env`。

### 步骤 4：配置 systemd 并启动

```bash
# 安装 systemd unit（如果没用 install-service.sh）
mkdir -p ~/.config/systemd/user
sed "s|%h|$HOME|g" systemd/privacy-filter.service > ~/.config/systemd/user/privacy-filter.service
systemctl --user daemon-reload
systemctl --user enable --now privacy-filter.service
```

验证服务健康：

```bash
curl -fsS http://127.0.0.1:8765/health | jq .
# 期望: {"ready": true, "device": "cuda", "uptime_s": ..., "version": "0.1.0"}
```

> 首次启动模型加载约 20 秒，期间 `/health` 返回 `{"ready": false}` + HTTP 503。

（可选）开机自启：

```bash
loginctl enable-linger $USER
```

### 步骤 5：安装 Git Hooks

根据客户在**问题 2** 的回答选择：

#### 5a. 全局 Hooks（core.hooksPath）

```bash
cd ~/project/docker/privacy-filter-service
bash install/install-hooks.sh
```

脚本会：
- 检查 `core.hooksPath` 是否已被占用（如有 Husky 等会警告）
- 复制 hooks 到 `~/.config/git/hooks/`
- 设置 `git config --global core.hooksPath ~/.config/git/hooks`

如果已有 `core.hooksPath`：

```bash
bash install/install-hooks.sh --force   # 备份旧路径后覆盖
```

验证：

```bash
git config --global core.hooksPath
# 期望: /home/<user>/.config/git/hooks
```

#### 5b. 指定仓库 Hooks

```bash
REPO_PATH="/path/to/target-repo"
HOOKS_SRC="$HOME/project/docker/privacy-filter-service/hooks"

# 复制 hooks 到目标仓库
cp "$HOOKS_SRC/pre-commit" "$REPO_PATH/.git/hooks/pre-commit"
cp "$HOOKS_SRC/commit-msg" "$REPO_PATH/.git/hooks/commit-msg"
cp "$HOOKS_SRC/_lib.sh"    "$REPO_PATH/.git/hooks/_lib.sh"
chmod +x "$REPO_PATH/.git/hooks/pre-commit"
chmod +x "$REPO_PATH/.git/hooks/commit-msg"
```

验证：

```bash
ls -la "$REPO_PATH/.git/hooks/pre-commit"
ls -la "$REPO_PATH/.git/hooks/commit-msg"
```

> **注意**：指定仓库安装方式不走 `core.hooksPath`，不与其他全局 hook 管理器冲突。
> 但如果该仓库的 `.git/hooks/` 下已有同名 hook，会被覆盖。

### 步骤 6：功能验证

```bash
# 测试 PII 检测（在目标仓库中）
cd /path/to/target-repo
echo "Contact: user@example.com <PRIVATE_EMAIL>" > test-pii.txt
git add test-pii.txt
git commit -m "test PII"
# 期望: 被 pre-commit hook 拦截，生成 patch 文件

# 清理
git reset HEAD test-pii.txt
rm test-pii.txt
```

---

## 部署路径 B：仅安装 Hooks（已有 OPF 服务）

适用于：**客户已有 OPF 服务** + 需要配置连接

### 步骤 1：获取项目（仅需 hooks 目录）

```bash
git clone git@github.com:shiliai/privacy-filter-service.git ~/project/docker/privacy-filter-service
```

### 步骤 2：确认服务地址

```bash
# 确认客户提供的地址可达
curl -fsS http://<SERVICE_HOST>:<PORT>/health | jq .
```

### 步骤 3：安装 Hooks

同**步骤 5a** 或 **5b**，根据客户选择的范围。

### 步骤 4：配置 Hook 连接地址

如果 OPF 服务不在默认地址 `http://192.168.88.75:8765`：

**方式 A：环境变量（推荐）**

在 `~/.bashrc` 或 `~/.zshrc` 中添加：

```bash
export PRIVACY_FILTER_URL="http://<SERVICE_HOST>:<PORT>"
```

**方式 B：全局 git config**

hooks 通过 `_lib.sh` 的 `pf_url()` 读取环境变量 `PRIVACY_FILTER_URL`，默认值为 `http://192.168.88.75:8765`（远程 GPU 主机）。

**方式 C：修改 config.toml**

如果本机有配置文件：

```toml
[hook]
base_url = "http://<SERVICE_HOST>:<PORT>"
```

### 步骤 5：验证

同**步骤 6**。

---

## 部署路径 C：远程 OPF 服务

适用于：**OPF 服务部署在远程机器**（如共享 GPU 服务器）

### 步骤 1：确认网络连通性

```bash
# 从客户机器测试远程服务
curl -fsS http://<REMOTE_HOST>:8765/health | jq .
```

> 确保远程服务 `service.host = "0.0.0.0"`（非 `127.0.0.1`），防火墙开放对应端口。

### 步骤 2：安装 Hooks + 配置远程地址

同部署路径 B，设置 `PRIVACY_FILTER_URL` 指向远程地址。

### 步骤 3：调整超时

远程调用延迟更高，建议增加超时：

```bash
export PRIVACY_FILTER_TIMEOUT_S=15    # 默认 5s，远程建议 10-30s
```

---

## 本地规则 fallback 服务（推荐搭配远程 OPF）

当主 OPF 服务部署在远程 GPU 主机时，开发机本地可启动一个轻量 **规则 fallback
服务**，在远程 OPF 不可达（网络中断、主机宕机）时继续扫描提交，而不是直接 fail-open。

hook 通过 `_lib.sh` 的 `pf_active_backend()` 先探测主 OPF 的 `/health`；2 秒内
无响应则改用本地 fallback。两者都不可达才警告并放行（fail-open）。

### 启动 fallback

```bash
cd ~/project/docker/privacy-filter-service
PYTHONPATH=src .venv/bin/privacy-filter-fallback-service
# 或：PYTHONPATH=src .venv/bin/python -m privacy_filter_service.fallback_app
```

默认监听 `127.0.0.1:8766`，**不需要 GPU 或 OPF 模型**，只读取 `config.toml`
的 `[fallback]` 段（因此不需要 `model_path`）。

### 覆盖范围

fallback 只覆盖高置信规则：email、phone、URL/domain、JWT、private key、常见
secret（`sk-*` 等）。**不覆盖** person / date / address / account_number —— 这些
仍依赖 OPF 模型。返回结果带 `warning` 字段，说明是规则 fallback 而非模型结果。

### 配置 fallback 地址（可选）

默认值开箱即用。如需改端口，用环境变量或 `config.toml`：

```bash
export PRIVACY_FILTER_FALLBACK_HOST=127.0.0.1
export PRIVACY_FILTER_FALLBACK_PORT=8766
export PRIVACY_FILTER_FALLBACK_URL=http://127.0.0.1:8766
```

```toml
[fallback]
host = "127.0.0.1"
port = 8766
base_url = "http://127.0.0.1:8766"
```

### 验证

```bash
curl -fsS http://127.0.0.1:8766/health     # {"ready": true, "device": "local-rules", ...}
bash tests/e2e/remote_fallback.sh          # 远程 OPF 主 + 本地 fallback 端到端
```

> fallback 没有 systemd unit；如需常驻，用 tmux / 终端，或自建 user unit。
> 首次运行需先安装 Python 依赖：`uv venv .venv --python 3.10 && uv sync`
> （远程 GPU 主机已有完整环境；纯本地 fallback 主机也要装 `presidio-analyzer`、
> `detect-secrets`、`fastapi`、`uvicorn` 等）。

---

## 配置速查

### 服务配置（`~/.config/privacy-filter/config.toml`）

| 配置项 | 默认值 | 说明 | 环境变量 |
|--------|--------|------|----------|
| `service.host` | `0.0.0.0` | 监听地址 | `PRIVACY_FILTER_LISTEN_HOST` |
| `service.port` | `8765` | 监听端口 | `PRIVACY_FILTER_LISTEN_PORT` |
| `service.device` | `cuda` | 推理设备 | `PRIVACY_FILTER_DEVICE` |
| `service.model_path` | *(必填)* | OPF 模型路径 | `PRIVACY_FILTER_MODEL_PATH` / `OPF_CHECKPOINT` |
| `service.output_mode` | `typed` | 输出模式 | `PRIVACY_FILTER_OUTPUT_MODE` |
| `service.decode_mode` | `viterbi` | 解码模式 | `PRIVACY_FILTER_DECODE_MODE` |
| `service.log_level` | `INFO` | 日志级别 | `PRIVACY_FILTER_LOG_LEVEL` |
| `hook.base_url` | `http://192.168.88.75:8765` | Hook 调用的主 OPF 服务地址 | `PRIVACY_FILTER_URL` |
| `hook.request_timeout_s` | `5.0` | HTTP 超时(秒) | `PRIVACY_FILTER_TIMEOUT_S` |
| `hook.max_file_bytes` | `262144` | 最大文件大小(≤1MB) | `PRIVACY_FILTER_MAX_FILE_BYTES` |
| `fallback.host` | `127.0.0.1` | 本地规则 fallback 监听地址 | `PRIVACY_FILTER_FALLBACK_HOST` |
| `fallback.port` | `8766` | 本地规则 fallback 监听端口 | `PRIVACY_FILTER_FALLBACK_PORT` |
| `fallback.base_url` | `http://127.0.0.1:8766` | 主 OPF 不可用时调用的 fallback 地址 | `PRIVACY_FILTER_FALLBACK_URL` |

### 配置加载优先级

```
config.toml → PRIVACY_FILTER_* 环境变量 → OPF_CHECKPOINT 后备
```

---

## 服务运维

```bash
systemctl --user start privacy-filter       # 启动
systemctl --user stop privacy-filter        # 停止
systemctl --user restart privacy-filter     # 重启（改配置后）
systemctl --user status privacy-filter      # 状态
journalctl --user -u privacy-filter -f      # 跟踪日志
journalctl --user -u privacy-filter --since '5 minutes ago'  # 最近日志
```

---

## 跳过与绕过

```bash
# 单次跳过（推荐 — 仅跳过 privacy-filter）
PRIVACY_FILTER_SKIP=1 git commit -m "紧急修复"

# 完全绕过（跳过所有 hooks）
git commit --no-verify -m "紧急修复"
```

---

## 常见问题

### Q: 服务启动失败，日志提示模型目录不存在

确认模型路径存在且 `config.toml` 中 `model_path` 设置正确：

```bash
ls -la /mnt/LLM/OpenAI/privacy_filter
# 或在 config.toml 中修改 model_path
```

### Q: 服务启动失败，日志提示 CUDA 不可用

编辑 `~/.config/privacy-filter/config.toml`：

```toml
[service]
device = "cpu"   # 改为 CPU 推理
```

或检查 GPU 驱动：

```bash
nvidia-smi
```

### Q: 全局 hooks 与 Husky/Lefthook 冲突

全局 `core.hooksPath` 会覆盖仓库级别的 hooks。解决方案：

1. **使用指定仓库安装**（部署路径 5b）代替全局安装
2. 或在受影响仓库中 `PRIVACY_FILTER_SKIP=1 git commit`
3. 或使用 `install/install-hooks.sh --force` 备份旧 hooks 后切换

### Q: 服务不可用时，提交被警告但不被阻止？

这是 **fail-open** 设计。hook 检测到服务不可用时会打印警告并 exit 0，不会阻塞开发流程。检查 `journalctl` 了解服务状态。

### Q: 部分暂存（partial staging）报错

当前版本不支持部分暂存的文件。解决方式：

```bash
git add <file>             # 完全暂存
# 或
git restore --staged <file>  # 取消暂存
```

---

## 卸载

```bash
cd ~/project/docker/privacy-filter-service
bash install/uninstall.sh
```

卸载操作：
- 停止并禁用 systemd 服务
- 删除 systemd unit 文件
- 清除 `core.hooksPath`（仅当指向我们的目录时）
- 删除 hooks 文件
- **保留** `~/.config/privacy-filter/config.toml` 和 `env`

---

## 决策流程图

```
客户请求部署 Privacy Filter
         │
         ▼
  ┌──────────────────┐
  │ 问题1: 是否已有   │
  │ OPF 服务？       │
  └──────┬───────────┘
         │
    ┌────┼────────┐
    │    │        │
    ▼    ▼        ▼
  有   没有    有但地址不同
  │    │        │
  │    ▼        │
  │  完整部署    │
  │  (路径 A)   │
  │    │        │
    ┌──┴────────┘
    ▼
  ┌──────────────────┐
  │ 问题2: Hooks    │
  │ 全局还是指定仓库？│
  └──────┬───────────┘
         │
    ┌────┴────┐
    ▼         ▼
  全局       指定仓库
  (5a)       (5b)
  core.      .git/hooks/
  hooksPath
    │         │
    └────┬────┘
         ▼
     功能验证
```

---

## Agent 操作检查清单

部署完成后，逐项确认：

- [ ] 服务健康检查通过：`curl -fsS "${PRIVACY_FILTER_URL:-http://192.168.88.75:8765}/health"` → `{"ready": true}`
- [ ] Hooks 已安装：对应目录下存在 `pre-commit`、`commit-msg`、`_lib.sh`
- [ ] （全局模式）`git config --global core.hooksPath` 输出正确路径
- [ ] PII 检测功能正常：包含 PII 的提交被拦截
- [ ] commit-msg hook 正常：提交信息中的 PII 被自动脱敏
- [ ] Fail-open 正常：主服务和 fallback 都不可达时，`git commit` 不被阻塞（仅警告）
- [ ] （远程 OPF）本地 fallback 已启动：`curl -fsS "${PRIVACY_FILTER_FALLBACK_URL:-http://127.0.0.1:8766}/health"` → `{"ready": true, "device": "local-rules"}`
- [ ] （远程 OPF）Failover 正常：远程不可达时 hook 自动改用本地 fallback，stderr 提示 `local fallback used`
- [ ] Skip 机制正常：`PRIVACY_FILTER_SKIP=1 git commit` 可正常提交
- [ ] （远程服务）`PRIVACY_FILTER_URL` 已正确配置
- [ ] （远程服务）超时已根据网络延迟调整

---

## 部署后更新 OPF-for-agent 文档

完成部署后，**必须**根据实际部署情况更新 `OPF-for-agent.md`：

1. **更新服务地址**：将文档中的 `REMOTE_IP` 替换为实际的内网 IP 或主机名
2. **更新 GPU 信息**：如果 GPU 型号与文档不一致，更新 GPU 描述
3. **更新网络配置**：如果使用了非默认端口或 HTTPS，更新相关示例
4. **验证文档准确性**：确保所有 `curl` 示例和配置示例与实际部署一致

更新后的文档应提交到仓库：

```bash
git add OPF-for-agent.md
git commit -m "docs: update OPF-for-agent.md with actual deployment details"
git push
```
