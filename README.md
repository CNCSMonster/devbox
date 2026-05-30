# devbox — Agent Skill + CLI for hidden project dev containers

`devbox` is an Agent Skill project plus a small CLI for project-local Docker development containers. Configuration lives in `.devbox/` and is hidden from inside the container.

## Core model

- Docker containers always need an image.
- Project-local Dockerfiles are optional.
- Default mode is **image mode**: `devbox init --image <image>` writes compose that directly uses that image.
- Container creation is separated from project/user bootstrap.
- `.devbox/runtime/container-init.sh` is a **host-side** bootstrap script. It runs after the container is created/start and can use `docker cp` / `docker exec`.

## What this package contains

```text
devbox/
├── README.md
├── SKILL.md
├── SPEC.md
├── SPEC-user-config.md
├── REFERENCE.md
├── install.sh
└── scripts/
    └── devbox
```

## Generated project layout

`devbox init` creates:

```text
project/
├── .devbox/
│   ├── config.json
│   ├── docker-compose.yml
│   ├── runtime/
│   │   └── container-init.sh     # host-side bootstrap script
│   └── image/                    # optional build-mode Dockerfile location
├── src/
└── tests/
```

Inside the container, `.devbox/` is hidden:

```text
/app/
├── src/
└── tests/
```

## Daily commands

```bash
devbox init      # initialize .devbox/ scaffold
devbox enter     # create/start, bootstrap if needed, attach shell
devbox stop      # stop the container
devbox restart   # restart and attach; bootstrap if needed
devbox status    # show container status
devbox config    # show .devbox/config.json
devbox rebuild   # recreate, start, and bootstrap; preserve HOME volume
devbox verify    # non-TTY health checks
devbox clean     # remove container and project HOME volume
```

## Requirements

- `bash`
- `jq`
- Docker Engine
- Docker Compose v2

The installer checks dependencies but does not install system packages.

## Install

```bash
cd /path/to/devbox
./install.sh
```

This links:

```text
~/.agents/skills/devbox -> /path/to/devbox
~/.local/bin/devbox     -> /path/to/devbox/scripts/devbox
```

## Project setup

```bash
cd /path/to/project

devbox init --image ghcr.io/cncsmonster/dotfiles:latest

devbox config

# Optional: customize host-side bootstrap
$EDITOR .devbox/runtime/container-init.sh

devbox enter
devbox verify
```

## Bootstrap script

`.devbox/runtime/container-init.sh` runs on the host and receives the container name:

```bash
.devbox/runtime/container-init.sh <container-name>
```

It should use `docker cp` / `docker exec` for runtime setup and touch `/tmp/.container-init-executed` inside the container after success. Subsequent `devbox enter` calls skip bootstrap while the marker exists.

## Safety model

- `devbox enter` is non-destructive for initialized containers.
- `devbox rebuild` recreates and bootstraps the container, preserving HOME volume.
- `devbox clean` removes container and HOME volume after confirmation.
- Docker ownership labels are checked before operating on existing resources.
- Unlabeled or mismatched resources are refused.
- Agents must not read or print `.env`, SSH keys, Codex config, or token/secret/key files.
