# Spec: Devbox User-Level Configuration & AI Workflow

## Objective

给 devbox 增加用户级配置层，并定义 AI agent 使用 devbox 的标准工作流。

**设计原则：**
- Devbox 管容器生命周期，不管具体工具安装
- AI 读规范文档 + 分析项目，生成容器配置方案
- AI 每次出方案等用户确认，不自动执行
- 项目通过 host-side `.devbox/runtime/container-init.sh` 定义容器创建后的初始化编排
- 默认使用指定 Docker image 直接创建容器，不要求项目本地 Dockerfile
- 容器完全独立，不挂载宿主机 HOME 等用户目录
- 用户通过 `~/.agents/devbox-norms.md` 记录个人偏好

**用户痛点：**
- 每次 `devbox init` 都要手动指定 `--image`、`--type`
- 容器里没有 AI 工具，每次都要手动装
- 不同项目的容器配置不一致
- AI 配置容器时不知道用户的习惯

**成功标准：**
1. 用户只需 `devbox enter / stop / rebuild`，不用关心配置细节
2. AI 读规范文档，自动应用用户偏好
3. AI 每次出方案等用户确认
4. 容器首次创建/重建并启动后自动执行 host-side `container-init.sh`
5. 默认 image mode 不生成/不要求项目 Dockerfile
6. 容器完全独立，不挂载宿主机 HOME 等用户目录
7. AI 观察重复行为，建议更新规范文档

## Commands

```bash
# 用户日常使用（不需要 AI）
devbox enter      # 进入容器
devbox stop       # 停止容器
devbox rebuild    # 重建容器
devbox status     # 查看状态
devbox verify     # 验证容器可用

# AI 配置时使用
devbox init       # AI 调用，生成 .devbox/ 配置
devbox config     # 查看当前配置
```

> **Note:** `devbox defaults show/set/reset` 是用户级配置接口，属于未来计划（v2），当前 v1 不实现。用户偏好通过 `~/.agents/devbox-norms.md` 文档记录，由 AI 读取和应用。

## Architecture

### 三层文档结构

```
Skill 层（skill 作者维护）
├── SKILL.md              # 教 AI 怎么用 devbox CLI

用户层（用户维护，AI 辅助更新）
└── ~/.agents/
    └── devbox-norms.md   # 用户的 devbox 使用规范

项目层（AI 生成，提交到 git）
└── .devbox/
    ├── config.json               # 项目级配置，记录 image/mode/name 等
    ├── docker-compose.yml
    ├── runtime/
    │   └── container-init.sh      # 宿主机侧容器 bootstrap 编排脚本
    └── image/                    # 可选：显式 build mode 才需要
        └── Dockerfile
```

### 各层职责

| 层 | 谁写 | 内容 |
|----|------|------|
| SKILL.md | skill 作者 | devbox CLI 用法、AI 工作流、验证标准 |
| devbox-norms.md | 用户（AI 辅助） | 个人偏好：默认镜像、必装工具、配置同步习惯 |
| config.json | AI 生成 | 项目配置：镜像、类型、image/build mode |
| runtime/container-init.sh | AI/开发者生成 | 宿主机侧 bootstrap：docker cp、docker exec、复制策略、运行时配置 |
| image/Dockerfile | AI/开发者可选生成 | build-time 依赖：系统包、语言运行时、可缓存工具 |

## User Norms Document

位置：`~/.agents/devbox-norms.md`

这是一个 **Markdown 文档**，不是 JSON 配置。AI 用自然语言理解它。

示例：

```markdown
# 我的 Devbox 规范

## 基础镜像
- 默认使用 ghcr.io/cncsmonster/dotfiles:stable
- Python 项目用 --type python
- Node 项目用 --type node

## 必装工具
每次配置容器时默认安装：
- codex（AI 编码助手，npm 包名 @openai/codex）
- pi（AI coding agent，npm 包名 @mariozechner/pi-coding-agent）

## 配置同步
从宿主机复制以下内容到容器：
- ~/.agents/skills → ~/.agents/skills（用 cp -aL 解析符号链接）
- ~/.codex → ~/.codex（复制后把 localhost 改为 host.docker.internal）

## 不要做的事
- 不要安装 claude-code（我不用）
- 不要挂载宿主机 HOME 目录（我只要特定目录复制）
```

## AI Workflow

### 核心原则

1. **每次出方案** — AI 分析项目后，输出配置方案，等用户确认
2. **不自动执行** — 除非用户明确说"可以"、"就这样"
3. **读规范文档** — 每次都读 `~/.agents/devbox-norms.md`
4. **学习机制** — 观察重复行为，建议更新规范

### 标准流程

```
用户：帮我给这个项目配置容器环境
         ↓
AI 读取：
  - SKILL.md（知道怎么用 devbox）
  - ~/.agents/devbox-norms.md（知道用户的习惯）
  - 扫描项目结构（pyproject.toml? package.json?）
         ↓
AI 输出方案：
         ↓
┌─────────────────────────────────────────────┐
│ 容器配置方案                                  │
│                                               │
│ 基础镜像: ghcr.io/cncsmonster/dotfiles:stable │
│ 项目类型: python                              │
│                                               │
│ 安装工具:                                     │
│   - codex (@openai/codex)                     │
│   - pi (@mariozechner/pi-coding-agent)        │
│                                               │
│ 宿主机复制:                                   │
│   - ~/.agents/skills → ~/.agents/skills       │
│   - ~/.codex → ~/.codex                       │
│                                               │
│ 项目特定:                                     │
│   - 创建 Python venv                          │
│   - 安装 pytest                               │
└─────────────────────────────────────────────┘
         ↓
AI：这个方案可以吗？需要调整什么？
         ↓
用户：加上 qwen 配置复制，去掉 claude-code
         ↓
AI 更新方案，确认后执行
  - devbox init
  - 编辑 .devbox/runtime/container-init.sh（宿主机侧 bootstrap）
  - devbox enter → 验证
```

### AI 学习机制

```
AI 观察：用户连续 3 次手动在 container-init.sh 里加了 claude-code
         ↓
AI 建议：你最近 3 个项目都装了 claude-code，
         要不要把它加到 ~/.agents/devbox-norms.md 的"必装工具"里？
         ↓
用户：好
         ↓
AI 更新 devbox-norms.md
         ↓
以后自动应用
```

## Container Init Script

### 概述

`.devbox/runtime/container-init.sh` 是 **宿主机侧** 容器 bootstrap 脚本。

- **运行位置：宿主机** — 不是在镜像构建阶段运行，也不是由容器 entrypoint 自动运行
- **运行时机：容器创建/重建并启动后** — 此时脚本可以通过 `docker cp` 和 `docker exec` 初始化容器
- **由 AI 或开发者编辑** — 根据项目需求和用户规范决定复制哪些宿主机文件、是否跨软链接、是否覆盖、是否执行容器内命令
- **一次性 bootstrap** — 用容器内标记文件 `/tmp/.container-init-executed` 防重复；标记属于容器生命周期，rebuild 后消失

### 为什么是宿主机侧脚本

容器内脚本不能直接访问宿主机路径；如果先把文件复制进容器，又需要 CLI 硬编码复制规则，devbox 就会变成特定工具的同步器。宿主机侧脚本更适合做初始化编排：

```bash
# runs on host
.devbox/runtime/container-init.sh <container-name>
```

脚本可以自由选择：

```bash
# 保留 symlink
docker cp "$HOME/.codex" "$container:/tmp/host-codex"

# 跨越 symlink：先在宿主机 staging，再 docker cp
tmp="$(mktemp -d)"
cp -aL "$HOME/.agents/skills/." "$tmp/skills/"
docker cp "$tmp/skills" "$container:/tmp/host-skills"

# 容器内落位或运行命令
docker exec "$container" bash -lc 'mkdir -p ~/.agents/skills && cp -a /tmp/host-skills/. ~/.agents/skills/'
```

### 与 Dockerfile 的边界

需要在镜像构建阶段表达的内容应进入可选 `.devbox/image/Dockerfile`：

- 系统包
- 语言运行时
- 可缓存的全局工具
- 不含宿主机私密文件的项目依赖

需要容器创建后才能完成的内容应进入 host-side `container-init.sh`：

- 复制选定宿主机文件到容器
- 写入 devbox HOME volume
- 根据当前容器名执行 `docker exec`
- 处理 `localhost` 到 `host.docker.internal` 的运行时重写

### 执行语义

| 场景 | copy/exec bootstrap | 说明 |
|------|---------------------|------|
| `enter` 且容器不存在 | ✅ | create/start 后执行 host-side `container-init.sh`，再进入 shell |
| `enter` 且容器已 bootstrap | ❌ | 只 start/reuse 并进入 shell，不再复制宿主机内容 |
| `enter` 且容器存在但 marker 缺失 | ✅ | 视为 bootstrap 未完成，重试脚本 |
| `rebuild` | ✅ | 删除并重建容器、启动、执行 bootstrap；保留 HOME volume；不自动进入 shell |
| `restart` 且 marker 存在 | ❌ | 重启并进入 shell |
| `restart` 且 marker 缺失 | ✅ | 重启后补 bootstrap，再进入 shell |

### host-side 脚本模板

```bash
#!/usr/bin/env bash
set -euo pipefail

# Host-side script. Runs on the host after the dev container is created/start.
# Args:
#   $1: container name
# Use docker cp/docker exec to initialize the container.

container="${1:?container name required}"
marker="/tmp/.container-init-executed"

if docker exec "$container" test -f "$marker" 2>/dev/null; then
  echo "Container already initialized: $container"
  exit 0
fi

echo "Initializing container: $container"

# Example: copy host files while preserving symlinks.
# if [ -d "$HOME/.codex" ]; then
#   docker cp "$HOME/.codex" "$container:/tmp/host-codex"
#   docker exec "$container" bash -lc '
#     mkdir -p "$HOME/.codex"
#     cp -a /tmp/host-codex/. "$HOME/.codex/"
#     rm -rf /tmp/host-codex
#   '
# fi

# Example: dereference symlinks on the host before docker cp.
# if [ -d "$HOME/.agents/skills" ]; then
#   tmp="$(mktemp -d)"
#   trap 'rm -rf "$tmp"' EXIT
#   mkdir -p "$tmp/skills"
#   cp -aL "$HOME/.agents/skills/." "$tmp/skills/"
#   docker cp "$tmp/skills" "$container:/tmp/host-skills"
#   docker exec "$container" bash -lc '
#     mkdir -p "$HOME/.agents/skills"
#     cp -a /tmp/host-skills/. "$HOME/.agents/skills/"
#     rm -rf /tmp/host-skills
#   '
# fi

docker exec "$container" touch "$marker"
echo "Container initialization complete: $container"
```

## Docker Compose

默认采用 **image mode**：Docker 容器必须使用某个 image，但项目不需要本地 Dockerfile。`devbox init --image <image>` 生成的 compose 直接引用该 image。

```yaml
name: ${name}

services:
  dev:
    image: ${image}
    container_name: ${container}
    working_dir: /app
    labels:
      devbox.managed: "true"
      devbox.version: "1"
      devbox.name: "${name}"
      devbox.owner_uid: "${uid}"
      devbox.identity_hash: "${hash}"
    env_file:
      - path: ../.env
        required: false
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      PATH: ...
    volumes:
      - ..:/app
      - dev-home:/root
      - /app/.devbox
    stdin_open: true
    tty: true
    command: sleep infinity

volumes:
  dev-home:
    name: ${volume_name}
    labels: ...
```

如果项目显式需要 build-time 定制，可以 opt into build mode，生成/使用 `.devbox/image/Dockerfile`。build mode 是可选能力，不是默认要求。

**不挂载宿主机 HOME 或用户配置目录。** 需要复制的内容由 host-side `container-init.sh` 在 bootstrap 阶段通过 `docker cp` 显式完成。

**对比旧设计：**
- ❌ ~~`${HOME}/.codex:/host-codex:ro`~~ — 不挂载宿主机配置目录
- ❌ ~~`${HOME}/.agents/skills:/host-skills:ro`~~ — 不挂载宿主机配置目录
- ❌ CLI 硬编码复制 Codex/skills — 不做，交给项目 bootstrap 脚本
- ✅ host-side `container-init.sh` 按项目需要使用 `docker cp` / `docker exec`

## User-Level Config Schema

`~/.devbox/config.json` — 只存机器级默认值（可选）

```json
{
  "version": 1,
  "defaults": {
    "image": "ghcr.io/cncsmonster/dotfiles:stable",
    "type": "python",
    "shell": "zsh"
  }
}
```

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `defaults.image` | (CLI 内置 `ghcr.io/cncsmonster/dotfiles:latest`) | 默认基础镜像 |
| `defaults.type` | (CLI 内置 `python`) | 默认项目类型 |
| `defaults.shell` | (CLI 内置 `zsh`) | 默认 shell |

**注意：** 这个配置只存简单的默认值。复杂的偏好（装什么工具、怎么复制）放在 `devbox-norms.md` 里，由 AI 理解和执行。

## Project Config Schema

`.devbox/config.json` — 项目级配置（AI 生成）

```json
{
  "version": 1,
  "name": "home-alice-work-myproject-a1b2c3d4e5",
  "displayName": "/home/alice/work/myproject",
  "container": "home-alice-work-myproject-a1b2c3d4e5-dev",
  "composeProject": "home-alice-work-myproject-a1b2c3d4e5",
  "imageName": "home-alice-work-myproject-a1b2c3d4e5:dev",
  "volumeName": "home-alice-work-myproject-a1b2c3d4e5-dev-home",
  "image": "ghcr.io/cncsmonster/dotfiles:stable",
  "type": "python",
  "shell": "zsh",
  "identity": { ... },
  "createdAt": "2026-05-27T15:00:00+08:00"
}
```

## Config Merge Logic

`devbox init` 时的配置合并优先级：

```
命令行参数 (--image, --type, --shell)
    ↓ 覆盖
项目级 .devbox/config.json (已存在时)
    ↓ 覆盖
用户级 ~/.devbox/config.json
    ↓ 覆盖
CLI 内置默认值
```

## devbox enter / rebuild 流程

### `devbox enter`

```bash
cmd_enter() {
  cfg="$(load_valid_config)"
  container="$(jq -r '.container' <<<"$cfg")"
  project="$(jq -r '.composeProject' <<<"$cfg")"
  shell="$(jq -r '.shell // "zsh"' <<<"$cfg")"

  if container_exists "$container"; then
    docker start "$container"  # no-op if already running is acceptable
  else
    compose_up "$project" -d   # image mode; build flags only if project opted into build mode
  fi

  ensure_bootstrapped "$container"
  docker exec -it "$container" "$shell"
}
```

`ensure_bootstrapped` 的语义：

```bash
ensure_bootstrapped() {
  local container="$1"
  local marker="/tmp/.container-init-executed"

  if docker exec "$container" test -f "$marker" 2>/dev/null; then
    return 0
  fi

  if [ -x .devbox/runtime/container-init.sh ]; then
    .devbox/runtime/container-init.sh "$container"
  fi

  docker exec "$container" test -f "$marker"
}
```

注意：CLI 不硬编码复制哪些宿主机文件。复制逻辑由 `.devbox/runtime/container-init.sh` 决定。

### `devbox rebuild`

`devbox rebuild` 应：

1. 用户确认
2. 删除旧 container，保留 devbox HOME volume
3. 使用当前 config 重新创建并启动 container
4. 调用 `ensure_bootstrapped`
5. 不自动进入 shell

## Code Style

保持现有 bash 风格：

```bash
log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}!${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }
```

## Testing Strategy

### Smoke test

```bash
# 1. 创建测试规范文档
mkdir -p ~/.agents
cat > ~/.agents/devbox-norms.md <<'EOF'
# 我的规范
- 默认镜像: ghcr.io/cncsmonster/dotfiles:stable
- 必装: codex
EOF

# 2. 创建测试项目
tmpdir=$(mktemp -d)
cd "$tmpdir"

# 3. AI 流程（模拟）
devbox init --image ghcr.io/cncsmonster/dotfiles:stable --type generic

# 4. 创建 host-side container-init.sh
cat > .devbox/runtime/container-init.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
container="${1:?container required}"
if docker exec "$container" test -f /tmp/.container-init-executed 2>/dev/null; then
  echo "Already initialized"
  exit 0
fi
docker exec "$container" sh -c 'echo "Init executed!" > /tmp/init-ran && touch /tmp/.container-init-executed'
EOF
chmod +x .devbox/runtime/container-init.sh

# 5. 创建/进入并验证
devbox enter
devbox verify

# 6. 验证 container-init.sh 被执行
container=$(jq -r .container .devbox/config.json)
docker exec "$container" test -f /tmp/init-ran

# 7. 再次进入，验证不会重复执行 host-side init
devbox stop
devbox enter

# 8. rebuild，验证会重新执行 bootstrap
printf 'y\n' | devbox rebuild
# container-init.sh 应该重新执行，因为新容器没有 /tmp marker
```

## Boundaries

### Always do

- AI 每次出方案等用户确认
- AI 每次读 `~/.agents/devbox-norms.md`（如果存在）
- 用户级配置不存在时使用 CLI 内置默认值，不报错
- host-side container-init.sh 不存在时跳过执行，不报错
- container-init.sh 执行失败时不设标记，下次重试
- 标记文件放在容器内 `/tmp/.container-init-executed`
- 不挂载宿主机 HOME 或用户配置目录
- 默认 image mode 不要求 Dockerfile

### Ask first

- 修改用户规范文档
- 安装规范文档里没有的工具
- 在 host-side bootstrap 中复制规范文档里没有的宿主机目录
- 从 image mode 切换到 build mode 或新增 `.devbox/image/Dockerfile`

### Never do

- 不在 devbox CLI 里硬编码具体工具的安装或宿主机文件同步逻辑
- 不在 docker-compose.yml 里挂载宿主机 HOME 或用户配置目录
- 不自动执行配置，必须等用户确认
- 不读取 `.env` 内容
- 不自动修改宿主机文件（除了用户明确要求更新规范文档）

## Success Criteria

完成后应满足：

1. `devbox defaults show` 显示用户级默认值
2. `devbox defaults set` 正确写入 `~/.devbox/config.json`
3. `devbox init` 自动继承用户级默认值
4. 命令行参数覆盖用户级配置
5. 容器首次创建/重建并启动后执行 host-side `.devbox/runtime/container-init.sh`
6. container-init.sh 不存在时跳过，不报错
7. 再次 enter 已 bootstrap 容器时 container-init.sh 不执行（标记文件存在）
8. rebuild 后 container-init.sh 重新执行（标记文件在新容器 /tmp 中不存在）
9. 默认 image mode 不要求项目 Dockerfile
10. 容器不挂载宿主机 HOME 或用户配置目录，完全独立
11. AI 读 `~/.agents/devbox-norms.md` 并应用用户偏好
12. AI 每次出方案等用户确认
13. `devbox verify` 通过所有检查
