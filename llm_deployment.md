# Privacy Filter Service — LLM Agent 部署指南

> 本文档供 AI Agent / 用户使用，指导部署 Privacy Filter 的 git hooks。
> 部署分**两条独立轨道**；先确定走哪条，再按步骤执行。

---

## 总览：两条安装轨道

隐私过滤 = **主引擎（脱敏主力）** + **本地兜底（安全网）**。安装拆成两条轨道：

```
Track 1 · 服务端安装 (install/install-service.sh)       Track 2 · 本地 Git Hook 端安装 (install/install-hooks.sh)
─────────────────────────────────────────────           ─────────────────────────────────────────────────────
· 跑 OPF 模型, 出 /redact HTTP                           · git hooks: pre-commit / commit-msg
· 唯一口味: GPU 模型版 (device=cuda, NVIDIA, Linux)      · _lib.sh (主→备 failover)
· 两种"拥有"方式:                                         · 【默认内置】CPU 非模型兜底脚本 (进程内·纯 stdlib
   1a) 用现成远程服务器 (只需 URL, 不在本机装)             ·    ·无 daemon/systemd/launchd·Mac/Linux 通用)
   1b) 本机装服务端 (systemd, 仅 Linux+GPU)              · PRIVACY_FILTER_URL = Track 1 的 URL
```

**角色 × 场景**

| 角色 | Track 1 服务端 | Track 2 Hook 端 |
|------|----------------|-----------------|
| 服务器管理员（架设共享 GPU 服务器） | 1b 装在服务器 | （服务器一般不装） |
| macOS 开发者（无 CUDA） | 1a 用远程（Mac 不装服务端） | 装 hooks + 内置兜底（零 daemon） |
| Linux+GPU 开发者 | 1b 本机 GPU / 或 1a 远程 | 装 hooks + 兜底，URL=127.0.0.1:8765 |
| 离线 / 无服务器 | 无（不配 URL） | 装 hooks + 兜底 → 兜底即主引擎 |

**运行时数据流**

```
git commit ─► Hook(pre-commit / commit-msg)
  SKIP=1 ? ───────────────────────────────► 放行
  主引擎 = PRIVACY_FILTER_URL (Track1 远程 或 本机 GPU daemon)
    探测 /health(2s)
    ├ ready ──► /redact (模型·高精度)
    └ 不可达 ─►【进程内 CPU 非模型兜底】(Track2 内置)
                 正则→同构 JSON→复用 patch 逻辑
                 ├ 命中 PII ─► 生成 patch + 阻断(exit 1)
                 └ 干净 ────► 放行
  主+兜底都无(未配 URL 且兜底失败/禁用): 默认阻断 (PRIVACY_FILTER_FAIL_OPEN=1 可放行)
```

> **安全设计**：远程服务不可达时，hook **不再**静默放行（旧版 fail-open 会让 PII 漏过）。
> 现在自动切到本地非模型兜底；连兜底都没有时**默认阻断**提交（`PRIVACY_FILTER_FAIL_OPEN=1` 可显式放行）。

---

## 前置确认（MUST ASK FIRST）

开始前确认两件事：

### 问题 1：主引擎用哪个？（决定 Track 1 怎么走）

```
您打算用哪种脱敏引擎？
  A) 远程 OPF 服务（别人已架设，给你一个地址，如 http://192.168.88.75:8765）
     → Track 1a：本机不装服务端，只需 URL。macOS 只能选这条。
  B) 本机安装模型服务（要 NVIDIA GPU + Linux + systemd）
     → Track 1b：跑 install/install-service.sh。脚本会探测 GPU；没有 GPU 会拒绝并建议改走 A。
  C) 都不要（离线 / 无服务器）
     → 不配 PRIVACY_FILTER_URL，Track 2 的内置非模型兜底即主引擎。
```

验证现有服务：

```bash
curl -fsS http://<HOST>:8765/health | jq .
# {"ready": true, ...} → 可用作主引擎
```

### 问题 2：Git Hooks 作用范围？（Track 2 的细节）

```
A) 全局（所有 git 仓库）— core.hooksPath
   - 一次安装，所有仓库受保护；会覆盖已有全局 hooks（Husky/Lefthook）
B) 指定仓库 — 复制到 .git/hooks/
   - 不影响其他仓库；每个仓库单独装
```

---

## 系统要求

| 项目 | Track 1 服务端（GPU 模型） | Track 2 Hook 端（含兜底） |
|------|---------------------------|---------------------------|
| OS | Linux（已验证 Ubuntu）。**macOS 不支持** | Linux + **macOS** 均可 |
| Python | 3.10 | 3.x（仅需 `python3`，纯 stdlib） |
| GPU | NVIDIA GPU + CUDA 11.8（必需，脚本自动探测） | 不需要 |
| 包管理器 | [uv](https://docs.astral.sh/uv/) | 不需要（hooks 是 bash + python3） |
| 服务管理 | systemd（用户会话） | 无（兜底是进程内脚本，零 daemon） |
| OPF 模型 | `/mnt/LLM/OpenAI/privacy_filter`（或自定义） | 不需要 |

> **macOS 用户**：只能走 Track 1a（远程服务）+ Track 2（hooks + 内置兜底）。详见下方 [macOS 专章](#macos-远程服务--内置非模型兜底)。

---

## 部署路径 A：完整部署（服务 + Hooks）— Track 1b + Track 2

适用于：**没有现有 OPF 服务** + **本机有 NVIDIA GPU（Linux）** + **全局或指定仓库 hooks**

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

> **为什么用 uv**：`uv venv` 创建独立虚拟环境，避免污染或与系统/已有的 Python 环境冲突（共享服务器上多版本 Python 共存时尤其重要）。未装 uv：`curl -LsSf https://astral.sh/uv/install.sh | sh`。
> **客户端模式（Track 2）不需要** uv / venv / GPU——hook 仅用系统 `python3`（纯 stdlib）+ bash。

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
cp "$HOOKS_SRC/pre-commit"    "$REPO_PATH/.git/hooks/pre-commit"
cp "$HOOKS_SRC/commit-msg"    "$REPO_PATH/.git/hooks/commit-msg"
cp "$HOOKS_SRC/_lib.sh"       "$REPO_PATH/.git/hooks/_lib.sh"
cp "$HOOKS_SRC/pf_fallback.py" "$REPO_PATH/.git/hooks/pf_fallback.py"
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

## 部署路径 B：仅安装 Hooks（已有 OPF 服务）— Track 1a + Track 2

适用于：**已有 OPF 服务（本机或同网段）** + 只需安装 hooks 并配置连接

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

如果 OPF 服务不在默认地址 `http://127.0.0.1:8765`，用下列任一方式告诉 hook 主引擎地址。**强烈推荐方式 A（git config）**——它在每次 git 调用时读取，对**非交互式环境（SSH / cron / CI）也可靠**；方式 B 的 `~/.bashrc` 只被交互式 shell 加载，非交互环境取不到会**静默回退**到本地兜底（仍安全，但丢失模型精度）。

**方式 A：git config（推荐，跨所有 shell 类型可靠）**

```bash
git config --global privacyfilter.url "http://<SERVICE_HOST>:<PORT>"
git config --global privacyfilter.timeout 15     # 远程建议 10-30s
```

`--global` 对当前用户所有仓库生效。出于安全考虑（主引擎地址即 PII 的去向），hook **只读 `--global` 配置，不读仓库级 `.git/config`**，避免仓库内脚本篡改地址把 PII 发到恶意服务器。单个仓库需要不同主引擎时，用环境变量（如 direnv）：`PRIVACY_FILTER_URL=... git commit`。

**方式 B：环境变量（仅交互式 shell 生效）**

在 `~/.bashrc` 或 `~/.zshrc` 中添加（仅交互式提交生效；SSH/cron/CI 等非交互环境请改用方式 A）：

```bash
export PRIVACY_FILTER_URL="http://<SERVICE_HOST>:<PORT>"
export PRIVACY_FILTER_TIMEOUT_S=15
```

环境变量优先级高于 git config（同时设置时以环境变量为准）。

**方式 C：修改 config.toml**

如果本机有配置文件：

```toml
[hook]
base_url = "http://<SERVICE_HOST>:<PORT>"
```

> 无论哪种方式，**未设置主引擎地址时不走主引擎**，自动使用 Track 2 内置的本地非模型兜底（见 [macOS 专章](#macos-远程服务--内置非模型兜底)）。

### 步骤 5：验证

同**步骤 6**。

---

## 部署路径 C：远程 OPF 服务 — Track 1a + Track 2

适用于：**OPF 服务部署在远程机器**（如共享 GPU 服务器 192.168.88.75）

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

## macOS：远程服务 + 内置非模型兜底

macOS（含 Apple Silicon）无 NVIDIA GPU、无 systemd，**不能**跑 Track 1 服务端。Mac 上的正确姿势是：

- **Track 1a**：用一台已架设好的远程 OPF 服务（如内网 `http://192.168.88.75:8765`）。
- **Track 2**：在本机安装 hooks + **内置非模型兜底**（纯 CPU，零 daemon）。

效果：日常走远程模型（高精度）；远程不可达时本机兜底自动接管，PII 仍被拦截——不会因网络/服务问题让 PII 漏过。

### 步骤 1：确认远程服务可达

```bash
curl -fsS http://192.168.88.75:8765/health | jq .
# {"ready": true, ...}
```

### 步骤 2：安装 hooks（含内置兜底）

```bash
git clone git@github.com:shiliai/privacy-filter-service.git ~/project/docker/privacy-filter-service
cd ~/project/docker/privacy-filter-service
bash install/install-hooks.sh          # 全局；或按路径 A 的"步骤 5b"复制到指定仓库
```

脚本会把 `pre-commit`、`commit-msg`、`_lib.sh`、`pf_fallback.py` 一起装到 `~/.config/git/hooks/`。

> `install-hooks.sh` 已兼容 macOS 自带的 bash 3.2（不使用 `mapfile` / `declare -A` 等 4.0+ 语法，也不依赖 GNU `head -z`）。

### 步骤 3：配置主引擎指向远程

推荐用 git config（对 SSH/cron 等非交互环境也可靠，见[部署路径 B 步骤 4](#步骤-4配置-hook-连接地址)）：

```bash
git config --global privacyfilter.url "http://192.168.88.75:8765"
git config --global privacyfilter.timeout 15     # 远程建议 10-30s
```

或在 `~/.zshrc` / `~/.bashrc` 中 `export PRIVACY_FILTER_URL=...`（仅交互式 shell 生效）。

### 步骤 4：验证

```bash
cd /path/to/your/repo
echo "contact = 'alice@example.com'" > test.txt
git add test.txt
git commit -m "test"
# 期望：被拦截 + 生成 patch（远程模型可用时走模型）

# 模拟远程不可达：临时指向死端口，本地兜底应仍拦截
PRIVACY_FILTER_URL="http://127.0.0.1:1" git commit -m "test"
# 期望：仍被本地兜底拦截（stderr 提示 using local non-model fallback）
```

> **Mac 上不需要**：systemd、CUDA/torch、模型 checkpoint。这些只在 Track 1 服务端需要。

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
| `hook.base_url` | `http://127.0.0.1:8765` | Hook 调用的服务地址 | `PRIVACY_FILTER_URL` |
| `hook.request_timeout_s` | `5.0` | HTTP 超时(秒) | `PRIVACY_FILTER_TIMEOUT_S` |
| `hook.max_file_bytes` | `262144` | 最大文件大小(≤1MB) | `PRIVACY_FILTER_MAX_FILE_BYTES` |

### Hook 行为环境变量（Track 2）

| 环境变量 | 默认 | 说明 |
|----------|------|------|
| `PRIVACY_FILTER_URL` | *(空)* | 主引擎服务地址（Track 1 的 URL）。**空 = 不走主引擎**，直接用本地非模型兜底。 |
| `PRIVACY_FILTER_TIMEOUT_S` | `5` | 主引擎 HTTP 超时（秒）。远程建议 10-30。 |
| `PRIVACY_FILTER_MAX_FILE_BYTES` | `262144` | 单文件最大字节数（≤1MB）。 |
| `PRIVACY_FILTER_SKIP` | `0` | `1` = 完全跳过 privacy-filter hook（单次绕过）。 |
| `PRIVACY_FILTER_NO_FALLBACK` | `0` | `1` = 禁用本地非模型兜底（主引擎不可达时直接走末位策略）。 |
| `PRIVACY_FILTER_FAIL_OPEN` | `0` | `1` = 主+兜底都无时**放行**（不脱敏，仅警告）。默认 `0` = **阻断**提交。 |

> **git config 等价项（跨 shell 类型可靠）**：`PRIVACY_FILTER_URL` → `git config privacyfilter.url`；`PRIVACY_FILTER_TIMEOUT_S` → `privacyfilter.timeout`。优先级：**环境变量 > git config > 默认值**。SSH/cron/CI 等非交互环境不会读 `~/.bashrc`，推荐用 `git config --global` 设置主引擎地址。其余行为开关（SKIP / NO_FALLBACK / FAIL_OPEN / MAX_FILE_BYTES）仅支持环境变量。

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

## 升级已部署的实例（软件升级）

仓库已部署、需要更新到最新版本时（获取新的脱敏规则 / hook 修复）：

### 1. 切到 main 并拉取最新代码

⚠️ **必须先切到 `main`**。如果 checkout 停在旧的 feature 分支，下一步重装 hooks 会装上**没有最新修复的旧版本**。

```bash
cd ~/project/docker/privacy-filter-service
git fetch origin
git checkout main            # 本地无 main 时：git checkout -b main origin/main
git pull --ff-only origin main
```

验证拿到了新代码：

```bash
git log --oneline -1
grep -nE 'AIza|sk_live' hooks/pf_fallback.py    # 例：确认新的 secret 规则已存在
```

### 2. 重装 hooks（覆盖为新版）

```bash
bash install/install-hooks.sh        # 全局；或按「部署路径 A 步骤 5b」重装到指定仓库
```

`core.hooksPath` 已指向同一目录时，脚本原地覆盖更新。主引擎地址若已用 `git config privacyfilter.url` 设置，**不受重装影响**（存于 git config，非仓库文件）。

### 3. 升级本机 GPU 服务端（仅 Track 1b）

本机跑 GPU 模型服务时，更新依赖并重启：

```bash
uv sync                              # 更新依赖（见上方 uv 说明）
systemctl --user restart privacy-filter.service
curl -fsS http://127.0.0.1:8765/health | jq .
```

### 4. 从「本机 GPU 服务」迁移到「纯客户端模式」

不再使用本机 GPU 服务（改用远程 OPF + 本地兜底）时，**必须停掉并禁用旧 systemd 服务**，否则重启 / 登录后旧服务会自动拉起、与远程主引擎冲突：

```bash
systemctl --user stop privacy-filter.service
systemctl --user disable privacy-filter.service
systemctl --user is-enabled privacy-filter.service    # 期望: disabled
```

unit 文件（`~/.config/systemd/user/privacy-filter.service`）与 `config.toml` 可保留以便日后复用，无需删除。随后按「部署路径 C」把 hooks 指向远程 OPF。

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

### Q: 服务不可用时，提交会怎样？

按优先级降级，绝不静默放行 PII：

1. **主引擎可用**（`PRIVACY_FILTER_URL` 指向的服务 `/health` ready）→ 走模型 `/redact`，高精度。
2. **主引擎不可达** → 自动切到 **本地非模型兜底**（`pf_fallback.py`，进程内正则，无需模型/GPU），命中 PII 照样拦截 + 生成 patch。
3. **主+兜底都没有**（未配 URL 且兜底被 `PRIVACY_FILTER_NO_FALLBACK=1` 禁用，或兜底也失败）→ **默认阻断**提交（exit 1）。需要放行时显式设置 `PRIVACY_FILTER_FAIL_OPEN=1`（会跳过脱敏，仅打印警告）。

> 旧版是纯 fail-open（服务挂了就放行不脱敏），有 PII 漏过风险。新版用本地兜底替代，安全优先。

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
                   部署 Privacy Filter
                          │
            ┌─────────────┴──────────────┐
            ▼                            ▼
     Track 1 服务端                 Track 2 Hook 端
     (跑 OPF 模型)                  (每台开发机必装)
            │                            │
   ┌────────┴────────┐                   │
   ▼                 ▼                   │
 1a 用现成远程      1b 本机装             │
 (只需 URL)        install-service.sh    │
   │              (Linux+GPU,自动探测)    │
   │              ── macOS/无GPU 拒绝 ──  │
   │                 │                   │
   └────────┬────────┘                   │
            ▼                            ▼
      PRIVACY_FILTER_URL ◄──── 指向 Track 1 的服务地址
            │                            │
            └─────────────┬──────────────┘
                          ▼
              安装 hooks + 内置非模型兜底
              (install/install-hooks.sh)
                          │
                          ▼
            问题2: 全局(core.hooksPath) / 指定仓库(.git/hooks)
                          │
                          ▼
                      功能验证
```

---

## Agent 操作检查清单

部署完成后，逐项确认：

- [ ] 服务健康检查通过：`curl -fsS http://127.0.0.1:8765/health` → `{"ready": true}`
- [ ] Hooks 已安装：对应目录下存在 `pre-commit`、`commit-msg`、`_lib.sh`、`pf_fallback.py`
- [ ] （全局模式）`git config --global core.hooksPath` 输出正确路径
- [ ] PII 检测功能正常：包含 PII 的提交被拦截
- [ ] commit-msg hook 正常：提交信息中的 PII 被自动脱敏
- [ ] Failover 正常：服务停止时，本地非模型兜底仍拦截 PII（不静默放行）
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
