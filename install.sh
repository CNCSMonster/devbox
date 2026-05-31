#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="devbox"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_FILE="${SOURCE_DIR}/SKILL.md"
CLI_FILE="${SOURCE_DIR}/scripts/devbox"
RUNTIME_DIR="${AGENT_SKILLS_DIR:-${HOME}/.agents/skills}"
BIN_DIR="${LOCAL_BIN_DIR:-${HOME}/.local/bin}"
SKILL_TARGET="${RUNTIME_DIR}/${SKILL_NAME}"
CLI_TARGET="${BIN_DIR}/devbox"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
err() { echo -e "${RED}✗${NC} $1" >&2; }

realpath_portable() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
  fi
}

link_or_replace_own_link() {
  local source="$1"
  local target="$2"
  local label="$3"

  mkdir -p "$(dirname "$target")"

  if [ -L "$target" ]; then
    local current
    current="$(readlink "$target")"
    local current_real source_real
    source_real="$(realpath_portable "$source")"
    if current_real="$(realpath_portable "$target" 2>/dev/null)" && [ "$current_real" = "$source_real" ]; then
      info "${label} already linked: ${target} -> ${current}"
    else
      warn "Replacing existing symlink for ${label}: ${target} -> ${current}"
      ln -sfn "$source" "$target"
      info "Linked ${label}: ${target} -> ${source}"
    fi
  elif [ -e "$target" ]; then
    err "Cannot install ${label}: target exists and is not a symlink: ${target}"
    echo "Move it away first or set a custom target directory with AGENT_SKILLS_DIR/LOCAL_BIN_DIR."
    return 1
  else
    ln -s "$source" "$target"
    info "Linked ${label}: ${target} -> ${source}"
  fi
}

check_command() {
  local cmd="$1"
  local hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    info "Found ${cmd}: $(command -v "$cmd")"
  else
    warn "Missing ${cmd}. ${hint}"
  fi
}

main() {
  if [ ! -f "$SKILL_FILE" ]; then
    err "SKILL.md not found at ${SKILL_FILE}. Run install.sh from a complete devbox skill folder."
    exit 1
  fi

  if [ ! -x "$CLI_FILE" ]; then
    if [ -f "$CLI_FILE" ]; then
      chmod +x "$CLI_FILE"
      info "Made CLI executable: ${CLI_FILE}"
    else
      err "CLI not found: ${CLI_FILE}"
      exit 1
    fi
  fi

  echo "==> Installing ${SKILL_NAME} skill from ${SOURCE_DIR}"
  link_or_replace_own_link "$SOURCE_DIR" "$SKILL_TARGET" "Agent Skill"
  link_or_replace_own_link "$CLI_FILE" "$CLI_TARGET" "devbox CLI"

  echo ""
  echo "==> Checking runtime dependencies"
  check_command bash "Install bash."
  check_command jq "Install jq before running devbox init/config/update."
  check_command docker "Install Docker Engine before using devbox containers."

  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      info "Found Docker Compose v2: $(docker compose version 2>/dev/null | head -1)"
    else
      warn "Missing Docker Compose v2. Ensure 'docker compose version' works."
    fi
  fi

  echo ""
  if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    warn "${BIN_DIR} is not in PATH for this shell. Add this to your shell profile:"
    echo "  export PATH=\"${BIN_DIR}:\$PATH\""
  else
    info "${BIN_DIR} is in PATH"
  fi

  echo ""
  echo "==> Verification"
  echo "  ${CLI_TARGET} --help"
  if command -v devbox >/dev/null 2>&1; then
    echo "  devbox --help"
  fi

  echo ""
  info "Installation complete. In a project root, run: devbox init"
}

main "$@"
