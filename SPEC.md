# Spec: devbox safe readable naming and Docker ownership labels

## Objective

完善 `devbox` Agent Skill + CLI，使它可以为项目生成更安全、可读、低冲突的 Docker 开发容器配置。

核心目标：

1. 默认项目名不再只使用当前目录名。
2. 默认项目名使用完整绝对路径的可读 slug，并在结尾追加 hash。
3. Docker 资源名保持可读，同时通过 hash 降低跨项目、跨用户、跨 Docker context 冲突概率。
4. 项目本地 `.devbox/config.json` 记录身份信息。
5. 生成的 Docker container 和 volume 带 `devbox.*` labels，用于证明资源归属。
6. 用户手动指定短名字时，也要检测 Docker 资源冲突。
7. 遇到无 labels 的资源时拒绝操作，确保资源归属安全。


## Product Shape

Devbox v1 has two deliverables:

1. A terminal-first `devbox` CLI application.
2. A `devbox` Agent Skill that teaches agents how to install, configure, and use the CLI safely.

The CLI is the execution and safety boundary. It must remain safe when used directly by humans without an agent and when invoked incorrectly by an agent.

The Agent Skill is a guidance layer. It may help choose configuration, explain workflows, and guide agents through project setup, but it must not be the only place where safety-critical behavior is specified.

All safety-critical behavior, including Docker availability checks, config validation, ownership checks, rebuild semantics, and destructive cleanup confirmation, must be enforced by the CLI.

The CLI-owned config schema is the shared contract between humans and agents. Agents should use the CLI to create or update `.devbox/` so their container setup conforms to the same schema and behavior that humans later use through `devbox enter`, `devbox rebuild`, `devbox status`, and related commands.

A devbox environment configured by an agent must remain operable by a human through the CLI without requiring the original agent session. Human handoff means operational usability, not full understanding of devbox internals.

Humans should be able to use common commands such as `devbox enter`, `devbox rebuild`, `devbox status`, `devbox stop`, and `devbox config` without understanding Docker labels, identity hashes, Docker image modes, or generated runtime files.

## Normative Behavior

本节是强制行为契约。若本文其他说明与本节冲突，以本节为准。

### Primary user workflows

Devbox v1 optimizes for three user-facing workflows. Users should not need to recognize, choose, or manage Docker/Compose resource names in normal use.

1. Simple setup:

   ```bash
   devbox init
   devbox enter
   ```

   The user initializes the project and enters a working development environment.

2. Agent-assisted setup:

   The user asks an AI agent to use this skill and CLI to configure the project-specific devbox environment. The agent may inspect the project structure and choose appropriate devbox options such as base image with user approval when needed.

   **The agent must verify the setup works before reporting success.** Verification steps:

   1. Run `devbox init` and confirm config files exist.
   2. Run `devbox config` and confirm valid v1 config.
   3. Start/create the container through `devbox enter` when a TTY is available, or through the generated Compose file plus the same bootstrap step that `devbox enter` would perform when running non-interactively.
   4. Run `devbox verify` and confirm all checks pass.

   After verification passes, the user enters with:

   ```bash
   devbox enter
   ```

3. Rebuild after environment breakage:

   If the container environment is broken, the user exits the container with `exit` and runs one rebuild command from the host. Rebuilding must recreate the dev container while preserving persistent project HOME contents stored in the devbox-managed HOME volume.

   ```bash
   devbox rebuild
   ```

`--name` is not part of the normal user workflow. It is an advanced escape hatch for generated Docker/Compose names that are too long, not meaningful, or inconvenient in Docker CLI/UI. Most users should run `devbox init` without `--name`.

### Container rebuild semantics

`devbox rebuild` is the dedicated command for recreating the dev container after the container environment is broken.

In v1, “rebuild” means recreating the dev container from the current `.devbox/` configuration, starting the new container, and running the host-side container bootstrap script if the container is not yet bootstrapped. It does not mean updating, pulling, or rebuilding the configured base image as a required user-facing operation.

`devbox rebuild` must preserve the devbox-managed project HOME volume by default. It must not remove the project HOME volume and must not use Docker or Docker Compose volume deletion semantics such as `down -v`.

The configured `image` is an input selected by the user or by an AI agent with user approval when needed. Devbox records and uses this image, but image content maintenance is not a core v1 responsibility.

`devbox rebuild` must not attach a shell by default. After a successful rebuild, users enter with `devbox enter`, which should normally only attach because the recreated container has already been bootstrapped.

### Configured image handoff

Devbox v1 does not own the project development image build lifecycle. It records and uses a configured image tag.

If a human or AI agent builds a project-specific development image outside devbox, the handoff to devbox is the resulting image tag. The agent or human must configure devbox to use that tag through the CLI-owned config schema, for example by setting `config.image`.

`devbox enter` and `devbox rebuild` use the configured image settings to create or recreate the dev container. They must not treat building, pulling, updating, or provenance reconstruction of the configured project image as their core user-facing behavior.

### Image mode, optional Dockerfile, and container bootstrap boundary

Devbox v1 distinguishes two image-related concepts:

1. The configured Docker image tag, stored as `config.image`. A Docker container must always be created from an image. This image tag is the required handoff used to create the dev container.
2. An optional devbox-specific image recipe, which may be prepared by a human or AI for advanced/project-specific build-time setup.

A project-local Dockerfile is **not required**. The default and simplest mode is **image mode**: `devbox init --image <image>` records an existing image tag and the generated Compose file uses that image directly. This keeps `devbox init` a lightweight scaffold operation.

If a project needs build-time customization, a human or AI may opt into a devbox-specific Dockerfile. The recommended location is:

```text
.devbox/image/Dockerfile
```

This optional file is distinct from existing project Dockerfiles, which may be production, CI, test, service, or devcontainer files and must not be assumed to be suitable for devbox.

Build-time image concerns belong in the optional Dockerfile, for example system packages, language runtimes, globally installed tools, and cacheable project dependencies. Runtime/container-lifecycle concerns belong in the host-side container bootstrap script, for example copying selected host files, writing into the devbox HOME volume, or running `docker exec` commands after the container exists.

`devbox enter` and `devbox rebuild` use the configured image settings to create or recreate the dev container. They must not require a project-local Dockerfile, and they must not treat building, pulling, updating, or reconstructing the configured project image as core user-facing lifecycle behavior unless the project explicitly opted into build mode.

### Host-side container bootstrap script

`devbox init` should create a minimal, editable host-side bootstrap script at:

```text
.devbox/runtime/container-init.sh
```

Despite the name, this script runs on the **host**, after the dev container has been created and started. It receives the container name as its first argument and may use `docker cp`, `docker exec`, and ordinary host shell commands to initialize the container. This lets AI agents or human developers decide exactly which host files to copy and whether to preserve or dereference symlinks (`cp -a` vs `cp -aL`).

The script is the project/user customization point. Devbox CLI must not hard-code specific tool installation or host configuration synchronization such as Codex, skills, SSH, npm, or Python setup. Those choices belong in the bootstrap script or the optional Dockerfile.

Container bootstrap is guarded by a marker inside the container filesystem, for example `/tmp/.container-init-executed`. The marker follows the container lifecycle, not the project checkout. Therefore rebuilding the container removes the marker while preserving the devbox HOME volume.

### Docker availability during initialization

`devbox init` must require Docker CLI and a reachable Docker daemon because it must check candidate Docker container and volume ownership before writing local `.devbox/` files.

If Docker is unavailable, the daemon cannot be reached, or required Docker inspection commands fail, `devbox init` must fail without creating or modifying `.devbox/`.

This version does not support offline initialization.

### Force initialization semantics

`--force` only permits overwriting local `.devbox/` files generated by devbox.

`--force` must not bypass Docker resource ownership checks. Existing Docker containers or volumes with missing or mismatched `devbox.*` labels must always block initialization, even when `--force` is provided.

This version does not support taking ownership of unlabeled or mismatched Docker containers or volumes. Users must manually remove or rename those resources outside devbox if they want to reuse the name.

### Fixed v1 identity model

Devbox v1 has exactly one identity strategy. It is an internal implementation contract, not a user-facing option. Users must not be asked to choose hash algorithms, identity input fields, identity strategies, label field names, or default name generation modes.

The v1 identity strategy is fixed as:

```text
identity input = host + ":" + ownerUid + ":" + dockerContext + ":" + absoluteProjectRoot
hash algorithm = sha256
identityHash = "sha256:" + 64 lowercase hex characters
default name suffix = first 10 lowercase hex characters of identityHash, without the "sha256:" prefix
```

`absoluteProjectRoot` must be the canonical physical absolute path of the project root, equivalent to `realpath "$PWD"` on POSIX systems.

The project config must store this digest as `identity.identityHash`. Docker labels must store this digest as `devbox.identity_hash`.

The term `projectRootHash` must not be used in v1 config or labels because the digest covers host, owner UID, Docker context, and project root, not only the project root.

Manual names provided with `devbox init --name <name>` only replace the human-readable Docker/Compose resource name prefix, stored as `config.name`. They must not change the identity input, `identityHash`, ownership labels, or ownership checks.

### Docker and Compose naming terms

In this SPEC, “Docker/Compose resource names” means the visible names derived from `config.name` for the current project. These names include:

- Compose project name: `config.composeProject`
- Dev container name: `config.container`
- Dev image tag: `config.imageName`
- Project HOME volume name: `config.volumeName`
- Compose-created network name, typically derived from the Compose project name

The v1 ownership safety checks are mandatory for the two high-risk named Docker objects that devbox may directly reuse, stop, recreate, or remove:

- Dev container: `config.container`
- Project HOME volume: `config.volumeName`

`--name <name>` sets `config.name`, the human-readable Docker/Compose resource name prefix. It is used to derive the names above. It is not a project identity, not an ownership proof, and does not replace the fixed v1 identity model.

### Docker ownership metadata

Docker labels are internal ownership metadata written by devbox-generated Docker Compose files. Users do not configure these labels and should not be asked to understand or choose them.

Devbox uses ownership labels only to decide whether an existing Docker container or volume with the expected name is safe to reuse, stop, rebuild, or remove.

Generated Docker Compose files must attach fixed `devbox.*` ownership labels to both the dev container and the project HOME volume. At minimum, the labels must encode that the resource is managed by devbox v1, the devbox resource name, the owner UID, and the v1 identity hash.

If a same-name Docker container or volume exists but lacks matching devbox ownership labels, has mismatched labels, has unreadable labels, or cannot be inspected reliably, devbox must refuse to operate on it.

No command, including `init --force`, may take ownership of, relabel, delete, or otherwise modify unlabeled or mismatched Docker containers or volumes. Users who intentionally want to reuse a blocked name must manually remove or rename the conflicting Docker resources outside devbox, or choose a different `devbox init --name`.

## Current Project Structure

当前项目位于：

```text
~/my-skills/devbox/
```

结构：

```text
devbox/
├── README.md
├── SKILL.md
├── SPEC.md
├── install.sh
└── scripts/
    └── devbox
```

运行时链接：

```text
~/.agents/skills/devbox -> ~/my-skills/devbox
~/.local/bin/devbox -> ~/.agents/skills/devbox/scripts/devbox
```

## Commands

验证安装：

```bash
~/my-skills/devbox/install.sh
command -v devbox
devbox --help
```

在临时项目中验证初始化：

```bash
tmpdir="$(mktemp -d)"
cd "$tmpdir"
devbox init
devbox config
jq . .devbox/config.json
grep -n "labels:" .devbox/docker-compose.yml
```

默认不自动运行这些交互或破坏性命令：

```bash
devbox enter
devbox rebuild
devbox clean
```

除非用户明确要求。

## Naming Strategy

默认项目名使用：

```text
slug(完整绝对路径) + "-" + hash10
```

例如：

```text
/home/alice/work/client-a/backend
```

生成：

```text
home-alice-work-client-a-backend-a1b2c3d4e5
```

另一个例子：

```text
/mnt/data/project/backend
```

生成：

```text
mnt-data-project-backend-9f2e11aa33
```

### Slug rules

从完整绝对路径生成可读部分：

1. 去掉开头 `/`。
2. 转小写。
3. 非 `a-z0-9` 字符替换为 `-`。
4. 连续多个 `-` 合并成一个。
5. 去掉首尾 `-`。
6. 如果结果为空，使用 `project`。

只使用中横线，不使用下划线。

### Hash rules

hash 长度：

```text
10 位
```

hash 算法：

```text
sha256(hostname + uid + dockerContext + absolutePath)
```

伪代码：

```bash
abs_path="$(realpath "$PWD")"
host="$(hostname)"
uid="$(id -u)"
docker_context="$(docker context show 2>/dev/null || echo default)"

hash_input="${host}:${uid}:${docker_context}:${abs_path}"
hash="$(printf '%s' "$hash_input" | sha256sum | cut -c1-10)"
```

用户不需要自己计算 hash。`devbox init` 自动计算。

## Docker Resource Names

如果默认项目名是：

```text
home-alice-work-client-a-backend-a1b2c3d4e5
```

则派生资源名：

```text
composeProject = home-alice-work-client-a-backend-a1b2c3d4e5
container      = home-alice-work-client-a-backend-a1b2c3d4e5-dev
imageName      = home-alice-work-client-a-backend-a1b2c3d4e5:dev
volumeName     = home-alice-work-client-a-backend-a1b2c3d4e5-dev-home
network        = home-alice-work-client-a-backend-a1b2c3d4e5_default
```

Volume 名统一使用中横线：

```text
${name}-dev-home
```

不再使用旧格式：

```text
${name}_dev-home
```

## Long Name Behavior

不自动截断长名字。

不在 `devbox init` 阶段预警长名字。

如果 Docker 或 Docker Compose 在 `devbox enter` / `devbox rebuild` 等阶段失败，错误提示中应包含建议：

```text
If this is caused by a very long generated Docker/Compose resource name,
try a shorter manual name:

  devbox init --name short-project --force
```

设计理由：

- 避免 init 阶段过度打扰用户。
- 不偷偷截断，保持默认名称和路径来源之间的可解释性。
- 只有真实失败时再提示用户手动指定短名字。

## Manual Name Behavior

用户可以手动指定短名字：

```bash
devbox init --name my-project
```

手动 name 也必须经过 slug 清洗。

如果手动指定短名字导致 Docker 资源冲突，CLI 必须警告或拒绝。

根据 name 派生并检查：

```text
container: ${name}-dev
image:     ${name}:dev
volume:    ${name}-dev-home
network:   ${name}_default
```

最重要的是检查：

```text
container
volume
```

如果已存在资源没有匹配的 `devbox.*` labels，应拒绝操作，因为无法证明它属于当前项目。

## Project Local Config

`.devbox/config.json` 应记录完整身份信息：

```json
{
  "version": 1,
  "name": "home-alice-work-client-a-backend-a1b2c3d4e5",
  "displayName": "/home/alice/work/client-a/backend",
  "container": "home-alice-work-client-a-backend-a1b2c3d4e5-dev",
  "composeProject": "home-alice-work-client-a-backend-a1b2c3d4e5",
  "imageName": "home-alice-work-client-a-backend-a1b2c3d4e5:dev",
  "volumeName": "home-alice-work-client-a-backend-a1b2c3d4e5-dev-home",
  "image": "ghcr.io/cncsmonster/dotfiles:latest",
  "shell": "zsh",
  "identity": {
    "strategy": "full-path-hash-v1",
    "projectRoot": "/home/alice/work/client-a/backend",
    "identityHash": "sha256:a1b2c3d4e5...",
    "ownerUid": "1000",
    "host": "hostname",
    "dockerContext": "default"
  },
  "createdAt": "2026-05-26T23:00:00+08:00"
}
```

完整路径记录在项目本地配置中。

## No User-Level Global Registry

本阶段不实现用户级全局配置或 registry。

不创建：

```text
~/.devbox/registry.json
~/.devbox/locks/
```

不新增：

```bash
devbox list
devbox prune
devbox doctor
```

原因：

1. 保持实现简单。
2. Docker 资源冲突最终必须以 Docker daemon 的真实状态为准。
3. 多用户共享 Docker daemon 时，各用户自己的 registry 看不到彼此资源。
4. 直接检查 Docker container/volume 并结合 labels 更可靠。

## Docker Labels

生成的 compose 应给 container 加 labels：

```yaml
labels:
  devbox.managed: "true"
  devbox.version: "1"
  devbox.name: "home-alice-work-client-a-backend-a1b2c3d4e5"
  devbox.owner_uid: "1000"
  devbox.identity_hash: "sha256:a1b2c3d4e5..."
```

Volume 也应加 labels：

```yaml
volumes:
  dev-home:
    name: home-alice-work-client-a-backend-a1b2c3d4e5-dev-home
    labels:
      devbox.managed: "true"
      devbox.version: "1"
      devbox.name: "home-alice-work-client-a-backend-a1b2c3d4e5"
      devbox.owner_uid: "1000"
      devbox.identity_hash: "sha256:a1b2c3d4e5..."
```

不默认把完整路径写入 Docker labels，避免在共享 Docker daemon 中泄露项目路径。

完整路径只写入：

```text
.devbox/config.json
```

## Conflict Detection

### During `devbox init`

在写入新配置前，检查候选 name 派生出的 Docker 资源是否已存在。

重点检查：

```text
container: ${name}-dev
volume:    ${name}-dev-home
```

如果资源不存在：允许初始化。

如果资源存在且 labels 匹配当前项目：允许复用。

如果资源存在但 labels 不匹配：拒绝。

如果资源存在但没有 labels：拒绝。

提示用户换名字：

```bash
devbox init --name short-unique-name
```

或在确实要重建当前项目时：

```bash
devbox init --name short-unique-name --force
```

### During container operations

这些命令操作已有 container 前必须检查 labels：

```bash
devbox enter
devbox stop
devbox restart
devbox rebuild
devbox clean
```

如果 labels 不匹配或不存在，拒绝操作。

理由：没有 labels 就不能证明资源属于当前项目。

## Code Style

项目主要是 Bash。

保持当前风格：

```bash
set -euo pipefail

log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}!${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }
```

新增函数应保持简单、可读、可局部测试。

避免新增大型依赖。继续只依赖：

```text
bash
jq
docker
docker compose
coreutils
```

## Testing Strategy

第一阶段只做非破坏性 smoke test。

测试点：

1. `install.sh` 可重复执行。
2. `devbox --help` 正常。
3. 临时目录执行 `devbox init` 正常。
4. `.devbox/config.json` 包含：
   - `version`
   - `name`
   - `displayName`
   - `container`
   - `composeProject`
   - `imageName`
   - `volumeName`
   - `identity.strategy`
   - `identity.projectRoot`
   - `identity.identityHash`
   - `identity.ownerUid`
   - `identity.host`
   - `identity.dockerContext`
5. `.devbox/docker-compose.yml` 包含 container labels。
6. `.devbox/docker-compose.yml` 包含 volume labels。
7. volume name 使用中横线：`${name}-dev-home`。
8. 同名目录不同路径生成不同 name。
9. 手动 `--name` 时配置中使用清洗后的 name。
10. 在默认 image mode 下，生成的 Compose 文件直接使用 `config.image`，不要求 `.devbox/runtime/Dockerfile`。
11. 如项目显式 opt into build mode，生成的 Compose/Dockerfile 能成功构建并启动容器。
12. `devbox verify` 通过所有检查（entry 可用、.devbox 隐藏、已初始化容器有 bootstrap marker）。

默认不执行（需要用户明确要求）：

```bash
devbox enter   # 需要 TTY，AI 无法执行
devbox rebuild # 有确认提示
devbox clean   # 破坏性操作
```

AI 使用 `devbox verify` 验证容器可用性，无需 TTY。

## Boundaries

### Always do

- 保持 `devbox enter` 对已 bootstrap 的容器非破坏式：只启动/复用并进入，不重新复制宿主机内容。
- 保持 `rebuild` / `clean` 需要用户确认。
- 保持 `devbox rebuild` 重建、启动并 bootstrap 容器，但不自动进入 shell。
- Docker 资源名前做 slug。
- config 里记录完整 identity。
- labels 里只放 hash，不默认放完整路径。
- 操作已有 container/volume 前检查 labels。
- Docker/Compose 失败时提示用户可以尝试 `--name` 指定短名字。

### Ask first

- 删除已有 `.devbox/`。
- 修改默认基础镜像。
- 从 image mode 切换到 build mode 或新增项目 Dockerfile。
- 改动具体工具/宿主机配置同步逻辑。
- 新增 `doctor`、`list`、`prune` 等新命令。
- 自动安装 Docker、jq、Compose 等系统依赖。

### Never do

- 不读取 `.env` 内容。
- 不读取 `~/.ssh/*`。
- 不读取 `~/.codex/*` 内容。
- 不在 devbox CLI 中硬编码 Codex、skills、SSH、npm、Python 等具体工具同步/安装逻辑；这些属于 bootstrap 脚本或可选 Dockerfile。
- 不自动运行 `devbox enter`（需要 TTY，AI 终端无法执行）。
- 不自动执行 `devbox clean`。
- 不自动删除 Docker volume。
- 不自动信任无 labels 的 Docker 资源。

### Always verify (AI)

- AI 配置 devbox 后，必须运行 `devbox verify` 验证容器可用。
- 只有 `devbox verify` 通过后才能报告“配置完成”。

## Success Criteria

完成后应满足：

1. `devbox init` 默认生成完整路径可读 slug + hash10 的 name。
2. 同名目录不同路径不会生成同一个 name。
3. 多用户共享 Docker daemon 时，默认 name 因为包含 UID hash，冲突概率大幅降低。
4. `.devbox/config.json` 能说明该 devbox 是在哪个路径、哪个用户、哪个 host、哪个 docker context 下生成的。
5. Docker compose 中 container 和 volume 都有 `devbox.*` labels。
6. 用户手动指定短名字时，仍会检查 container/volume 冲突。
7. 遇到无 labels 或 labels 不匹配的已有资源时拒绝操作。
8. 不实现用户级全局 registry。
9. 遇到无 labels 或 labels 不匹配的资源时拒绝操作，确保资源归属安全。
10. README 和 SKILL 说明与实际行为一致。
11. 默认 image mode 不要求项目本地 Dockerfile；只有显式 build mode 才生成/使用 devbox-specific Dockerfile。
12. `.devbox/runtime/container-init.sh` 被定义为 host-side bootstrap script，并只在容器尚未完成 bootstrap 或 rebuild 后执行。
