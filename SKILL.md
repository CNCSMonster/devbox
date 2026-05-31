---
name: devbox
description: 为项目配置 Docker 开发容器环境。当用户通过 /devbox 调用时激活。覆盖：初始化、进入、重建、验证容器环境。读取用户规范文档，出方案等确认后执行。
---

# Devbox — image-first 开发容器脚手架

项目本地 Docker 开发容器。`devbox init` 生成 `.devbox/` 脚手架；默认直接使用指定 Docker image，不要求项目本地 Dockerfile。容器创建后的项目/用户初始化由宿主机侧 `.devbox/runtime/container-init.sh` 编排。

**调用方式：** 用户主动 `/devbox <任务描述>`。不要自动加载此 skill。

## 何时使用

- 用户要求配置/搭建 Docker 开发容器环境
- 用户说“用 devbox”或 `/devbox`
- 用户要求进入、停止、重建、验证容器

**主动发现：** 如果项目有源码但没有 `.devbox/`，可以提示用户：
> “这个项目还没有配置容器开发环境。你可以用 `/devbox` 来配置一个。”

不要自动初始化，必须等用户主动调用。

## 设计边界

- Docker 容器必须有 image；项目本地 Dockerfile 不必须有。
- 默认 **image mode**：`devbox init --image <image>` 生成 compose，直接使用该 image。
- 只有明确需要 build-time 定制时，AI/开发者才建议新增 `.devbox/image/Dockerfile`。
- `.devbox/runtime/container-init.sh` 是 **宿主机侧 bootstrap 脚本**，在容器创建/启动后执行，可用 `docker cp` / `docker exec` 初始化容器。
- Devbox CLI 管生命周期，不硬编码安装 Codex、skills、SSH、npm、Python 等具体工具逻辑。

## AI 工作流

### 核心原则

1. **每次出方案** — 分析项目后输出配置方案，等用户确认。
2. **不自动执行** — 除非用户明确说“可以”、“就这样”。
3. **读规范文档** — 每次读取 `~/.agents/devbox-norms.md`（如果存在）。
4. **扫描项目结构** — 判断建议的 `--type`、image、是否需要 bootstrap 或 Dockerfile。
5. **初始化逻辑写脚本** — 根据用户确认，编辑 `.devbox/runtime/container-init.sh`，不要让 CLI 硬编码。
6. **观察重复行为** — 发现用户反复做同样的事，建议更新规范文档。

### 标准流程

```
用户：/devbox 帮我配置这个项目的容器环境
         ↓
读取配置：
  - ~/.agents/devbox-norms.md（用户偏好，如果存在）
  - 扫描项目结构（pyproject.toml? package.json?）
  - 检查是否需要 build-time 定制（系统包/语言运行时/重型依赖）
         ↓
输出方案：
┌─────────────────────────────────────────────┐
│ 容器配置方案                                  │
│                                               │
│ 模式: image mode（默认，无项目 Dockerfile）    │
│ Image: ghcr.io/cncsmonster/dotfiles:latest    │  ← 可通过 devbox-norms.md 覆盖
│ 项目类型: python                              │
│                                               │
│ Host-side bootstrap:                          │
│   - 首次创建/重建后执行                         │
│   - 可 docker cp 指定宿主机文件                 │
│   - 可 docker exec 容器内命令                   │
└─────────────────────────────────────────────┘
         ↓
这个方案可以吗？需要调整什么？
         ↓
用户确认后执行：
  1. devbox init --type <detected> --image <image>
  2. 按方案编辑 .devbox/runtime/container-init.sh（如需要）
  3. devbox enter（首次 create/start/bootstrap/attach；后续只 attach）
  4. devbox verify
```

## Host-side container-init.sh

位置：`.devbox/runtime/container-init.sh`

运行位置：宿主机。第一个参数是容器名。

执行语义：

| 场景 | bootstrap script | 说明 |
|------|------------------|------|
| `enter` 且容器不存在 | ✅ | 创建并启动容器后执行，再进入 shell |
| `enter` 且容器已初始化 | ❌ | 只启动/复用并进入，不复制宿主机内容 |
| `enter` 且 marker 缺失 | ✅ | 视为初始化未完成，重试 |
| `rebuild` | ✅ | 重建、启动并 bootstrap；保留 HOME volume；不自动进入 shell |

标记文件在容器内 `/tmp/.container-init-executed`。脚本失败时不应创建标记，下次 `enter` / `rebuild` 会重试。

示例：

```bash
#!/usr/bin/env bash
set -euo pipefail
container="${1:?container name required}"
marker="/tmp/.container-init-executed"

if docker exec "$container" test -f "$marker" 2>/dev/null; then
  exit 0
fi

# 保留 symlink 复制
if [ -d "$HOME/.codex" ]; then
  docker cp "$HOME/.codex" "$container:/tmp/host-codex"
  docker exec "$container" bash -lc '
    mkdir -p "$HOME/.codex"
    cp -a /tmp/host-codex/. "$HOME/.codex/"
    rm -rf /tmp/host-codex
  '
fi

# 跨越 symlink：宿主机 staging 后 docker cp
if [ -d "$HOME/.agents/skills" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/skills"
  cp -aL "$HOME/.agents/skills/." "$tmp/skills/"
  docker cp "$tmp/skills" "$container:/tmp/host-skills"
  docker exec "$container" bash -lc '
    mkdir -p "$HOME/.agents/skills"
    cp -a /tmp/host-skills/. "$HOME/.agents/skills/"
    rm -rf /tmp/host-skills
  '
fi

docker exec "$container" touch "$marker"
```

## container-init.sh 编写规则

编辑 container-init.sh 时，遵循以下规则：

### 防御性编程

**规则：复制到容器内路径前，先确保目标目录存在。**

```bash
# ❌ 错误：目标目录可能不存在
docker cp "$tmp/skills" "$container:/root/.agents/skills"

# ✅ 正确：先创建目标目录
docker exec "$container" mkdir -p /root/.agents/skills
docker cp "$tmp/skills/." "$container:/root/.agents/skills/"
```

**规则：任何 `docker cp` 到非根目录的路径，都先 `mkdir -p`。**

```bash
# 复制 codex 配置
docker exec "$container" mkdir -p /root/.codex
docker cp "$tmp/." "$container:/root/.codex/"

# 复制 agent skills
docker exec "$container" mkdir -p /root/.agents/skills
docker cp "$tmp/skills/." "$container:/root/.agents/skills/"
```

### 常用 Docker 命令模式

| 操作 | 命令 |
|------|------|
| 复制文件到容器 | `docker cp <src> <container>:<dst>` |
| 在容器内执行命令 | `docker exec <container> bash -lc '<cmd>'` |
| 检查容器内文件是否存在 | `docker exec <container> test -f <path>` |
| 在容器内创建目录 | `docker exec <container> mkdir -p <path>` |
| 容器内替换文本 | `docker exec <container> sed -i 's/old/new/g' <file>` |
| 跨 symlink 复制 | 宿主机 `cp -aL` staging 后再 `docker cp` |

**不确定的命令用法？** → 查 [Docker CLI 文档](https://docs.docker.com/reference/cli/docker/) 或 `docker <cmd> --help`

### 完整的 container-init.sh 标准模板

编辑 container-init.sh 时，以此为参考。根据 `~/.agents/devbox-norms.md` 的配置，决定哪些块需要保留：

```bash
#!/usr/bin/env bash
set -euo pipefail
container="${1:?container name required}"
marker="/tmp/.container-init-executed"

if docker exec "$container" test -f "$marker" 2>/dev/null; then
  echo "Container already initialized: $container"
  exit 0
fi

echo "Initializing container: $container"

# ── 1. 安装 AI CLI（根据规范文档决定是否需要）─────────────────
docker exec "$container" bash -lc 'command -v codex &>/dev/null || npm install -g @openai/codex'
docker exec "$container" bash -lc 'command -v pi &>/dev/null || npm install -g @mariozechner/pi-coding-agent'

# ── 2. 复制 Codex 配置 ─────────────────────────────────────────
if [ -d "$HOME/.codex" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  rsync -a --exclude='tmp/' --exclude='*.sqlite*' "$HOME/.codex/" "$tmp/"
  # 替换 localhost/127.0.0.1/0.0.0.0 为 host.docker.internal
  if [ -f "$tmp/config.toml" ]; then
    sed -i 's|http://127\.0\.0\.1|http://host.docker.internal|g' "$tmp/config.toml"
    sed -i 's|http://localhost|http://host.docker.internal|g' "$tmp/config.toml"
    sed -i 's|http://0\.0\.0\.0|http://host.docker.internal|g' "$tmp/config.toml"
  fi
  docker exec "$container" mkdir -p /root/.codex
  docker cp "$tmp/." "$container:/root/.codex/"
  # YOLO 权限（根据 devbox-norms.md）
  docker exec "$container" bash -lc '
    if ! grep -q "default_permissions" /root/.codex/config.toml 2>/dev/null; then
      cat >> /root/.codex/config.toml << '"'"'YOLOEOF'"'"'

default_permissions = "yolo"

[permissions.yolo]
approval_policy = "never"
sandbox_mode = "danger-full-access"

[permissions.yolo.network]
enabled = true
mode = "full"
YOLOEOF
    fi
  '
fi

# ── 3. 复制 Agent Skills（跨 symlink）──────────────────────────
if [ -d "$HOME/.agents/skills" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/skills"
  cp -aL "$HOME/.agents/skills/." "$tmp/skills/"
  docker exec "$container" mkdir -p /root/.agents/skills
  docker cp "$tmp/skills/." "$container:/root/.agents/skills/"
fi

# ── 4. 标记完成 ────────────────────────────────────────────────
docker exec "$container" touch "$marker"
echo "Container initialization complete: $container"
```

**编辑时只需增删块，不要重写命令结构。**

## 用户规范文档

位置：`~/.agents/devbox-norms.md`

用户维护的 Markdown 文档，记录个人 devbox 偏好。每次 `/devbox` 时读取。

示例：

```markdown
# 我的 Devbox 规范

## 基础镜像
- 默认使用 <your-registry>/<your-image>:<tag>
- Python 项目用 --type python
- Node 项目用 --type node

## 初始化偏好
- 安装工具：npm install -g <your-ai-cli>
- 如果需要复制 skills，使用 cp -aL 跨越符号链接
- 如果需要复制配置，复制后把 localhost 改为 host.docker.internal

## 不要做的事
- 不要挂载宿主机 HOME 目录
- 不要读取 `.env`、`~/.ssh` 等敏感文件
```

如果规范文档不存在，使用 CLI 内置默认值，不报错。

## Quick Start

```bash
command -v devbox || /path/to/devbox/install.sh

devbox init --type python --image ghcr.io/cncsmonster/dotfiles:latest  # 默认镜像
devbox config
devbox config show

# 如需项目/用户初始化，编辑 .devbox/runtime/container-init.sh

devbox enter
devbox verify
```

Init options: `--image <tag>`, `--type generic|python|node`, `--name <short>`.

## Daily Commands

| Command | Description |
|---------|-------------|
| `devbox init` | Initialize `.devbox/` scaffold |
| `devbox enter` | Start/reuse container, bootstrap if needed, attach shell |
| `devbox stop` | Stop container |
| `devbox restart` | Restart, bootstrap if needed, attach shell |
| `devbox status` | Show container state |
| `devbox config` | Show current config.json |
| `devbox config show` | Show config and bootstrap script path |
| `devbox verify` | Run health checks (no TTY needed) |
| `devbox update key=val` | Update mutable fields (image, type, shell) |
| `devbox rebuild` | Recreate, start, and bootstrap container; preserve HOME volume |
| `devbox clean` | Remove container + HOME volume (destructive) |

## 安全规则

- 不要读取 `.env`、`~/.ssh/*`、`~/.codex/*`，或文件名包含 token/secret/key 的文件。
- `devbox enter` 对已 bootstrap 容器是非破坏性操作；不会重新复制宿主机内容。
- `rebuild` 保留 HOME volume，但会重建并 bootstrap 新容器。
- `clean` 是破坏性操作，执行前需用户确认。
- 同名 Docker 资源没有匹配的 `devbox.*` 标签 → 拒绝操作。
- 不要在未经用户批准的情况下安装 Docker/jq/Compose。
- docker-compose.yml 中有 `env_file: ../.env`（`required: false`），容器启动时会自动加载 `.env` 中的环境变量；agent 不应主动读取或打印 `.env` 内容。
- 规范行为契约 → [SPEC.md](SPEC.md)
- 用户配置与 AI 工作流 → [SPEC-user-config.md](SPEC-user-config.md)
- 模板、标签、哈希算法 → [REFERENCE.md](REFERENCE.md)
