#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVBOX="$ROOT/scripts/devbox"
INSTALL="$ROOT/install.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/p1/same" "$tmp/p2/same" "$tmp/manual" "$tmp/ops" "$tmp/failops" "$tmp/conflict" "$tmp/volumeonly" "$tmp/badinspect"

cat > "$tmp/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${DEVBOX_FAKE_DOCKER_STATE:?}"

config_file() {
  if [ -f .devbox/config.json ]; then printf '%s\n' .devbox/config.json; return 0; fi
  if [ -f config.json ] && [ "$(basename "$PWD")" = .devbox ]; then printf '%s\n' config.json; return 0; fi
  return 1
}

state_has() { [ -f "$state_dir/$1" ] && grep -Fxq "$2" "$state_dir/$1"; }
state_add() { mkdir -p "$state_dir"; touch "$state_dir/$1"; state_has "$1" "$2" || printf '%s
' "$2" >> "$state_dir/$1"; }
state_del() { [ -f "$state_dir/$1" ] && grep -Fxv "$2" "$state_dir/$1" > "$state_dir/$1.tmp" && mv "$state_dir/$1.tmp" "$state_dir/$1" || true; }

owned_container() {
  { [ -n "${DEVBOX_FAKE_OWNED_NAME:-}" ] && [ "$1" = "${DEVBOX_FAKE_OWNED_NAME}-dev" ]; } || state_has containers "$1"
}

owned_volume() {
  { [ -n "${DEVBOX_FAKE_OWNED_NAME:-}" ] && [ "$1" = "${DEVBOX_FAKE_OWNED_NAME}-dev-home" ]; } || state_has volumes "$1"
}

label_value() {
  local label="$1" cfg
  cfg="$(config_file)" || { echo ""; return 0; }
  case "$label" in
    devbox.managed) echo true ;;
    devbox.version) echo 1 ;;
    devbox.name) jq -r .name "$cfg" ;;
    devbox.owner_uid) jq -r .identity.ownerUid "$cfg" ;;
    devbox.identity_hash) jq -r .identity.identityHash "$cfg" ;;
    *) echo "" ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  info) exit 0 ;;
  context)
    [ "${1:-}" = show ] && { echo "${DEVBOX_FAKE_CONTEXT:-default}"; exit 0; }
    ;;
  compose)
    if [ "${1:-}" = version ]; then echo "Docker Compose version v2.0.0"; exit 0; fi
    if [ "${1:-}" = -p ]; then
      echo "compose $*" >> "$state_dir/compose.log"
      if [[ " $* " == *" up "* ]]; then
        cfg="$(config_file || true)"
        if [ -n "$cfg" ]; then
          state_add containers "$(jq -r .container "$cfg")"
          state_add volumes "$(jq -r .volumeName "$cfg")"
        fi
      fi
      exit 0
    fi
    ;;
  container)
    if [ "${1:-}" = inspect ]; then
      name="${2:-}"
      case "$name" in
        conflict-dev) echo '{}' ; exit 0 ;;
        badinspect-dev) echo 'permission denied' >&2; exit 2 ;;
        *) owned_container "$name" && { echo '{}'; exit 0; } || { echo "Error: No such container: $name" >&2; exit 1; } ;;
      esac
    fi
    ;;
  volume)
    if [ "${1:-}" = inspect ]; then
      if [ "${2:-}" = -f ]; then
        fmt="${3:-}"; name="${4:-}"
        if [[ "$fmt" =~ index[[:space:]]+\.Labels[[:space:]]+\"([^\"]+)\" ]]; then
          owned_volume "$name" && label_value "${BASH_REMATCH[1]}" || echo ""
          exit 0
        fi
      fi
      name="${2:-}"
      case "$name" in
        conflict-dev-home|volumeonly-dev-home) echo '{}' ; exit 0 ;;
        badinspect-dev-home) echo 'permission denied' >&2; exit 2 ;;
        *) owned_volume "$name" && { echo '{}'; exit 0; } || { echo "Error: No such volume: $name" >&2; exit 1; } ;;
      esac
    fi
    ;;
  inspect)
    if [ "${1:-}" = -f ]; then
      fmt="${2:-}"; resource="${3:-}"
      if [[ "$fmt" == *State.Running* ]]; then owned_container "$resource" && echo true || echo false; exit 0; fi
      if [[ "$fmt" =~ index[[:space:]]+\.Config\.Labels[[:space:]]+\"([^\"]+)\" ]]; then label_value "${BASH_REMATCH[1]}"; exit 0; fi
      echo ""; exit 0
    fi
    ;;
  ps) echo "CONTAINER ID   IMAGE   STATUS   PORTS"; exit 0 ;;
  start|stop|restart|rm)
    echo "$cmd $*" >> "$state_dir/docker.log"
    [ "${DEVBOX_FAKE_FAIL_DOCKER_CMD:-}" = "$cmd" ] && exit 42
    if [ "$cmd" = rm ]; then
      for arg in "$@"; do case "$arg" in -*) ;; *) state_del containers "$arg"; rm -f "$state_dir/marker-$arg" ;; esac; done
    fi
    exit 0
    ;;
  exec)
    echo "exec $*" >> "$state_dir/docker.log"
    [ "${DEVBOX_FAKE_FAIL_DOCKER_CMD:-}" = exec ] && exit 42
    container="${1:-}"; shift || true
    if [ "${1:-}" = test ] && [ "${2:-}" = -f ] && [ "${3:-}" = /tmp/.container-init-executed ]; then
      [ -f "$state_dir/marker-$container" ] && exit 0 || exit 1
    fi
    if [ "${1:-}" = touch ] && [ "${2:-}" = /tmp/.container-init-executed ]; then
      : > "$state_dir/marker-$container"; exit 0
    fi
    if [ "${1:-}" = sh ] && [ "${2:-}" = -c ]; then
      case "${3:-}" in
        *'/tmp/.container-init-executed'*) : > "$state_dir/marker-$container" ;;
      esac
      echo 0
    fi
    exit 0
    ;;
  *) ;;
esac
echo "fake docker unsupported: $cmd $*" >&2
exit 99
DOCKER_EOF
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"
export DEVBOX_FAKE_DOCKER_STATE="$tmp"

(cd "$tmp/p1/same" && "$DEVBOX" init >/dev/null && "$DEVBOX" config >/dev/null)
jq -e '
  .version == 1
  and .identity.strategy == "full-path-hash-v1"
  and (.identity.projectRoot == .displayName)
  and (.identity.identityHash | test("^sha256:[0-9a-f]{64}$"))
  and (.name | test("^[a-z0-9-]+-[0-9a-f]{10}$"))
  and (.container == (.name + "-dev"))
  and (.composeProject == .name)
  and (.imageName == (.name + ":dev"))
  and (.volumeName == (.name + "-dev-home"))
  and (has("projectRootHash") | not)
  and (.identity | has("projectRootHash") | not)
' "$tmp/p1/same/.devbox/config.json" >/dev/null
grep -q 'devbox.managed: "true"' "$tmp/p1/same/.devbox/docker-compose.yml"
grep -q 'devbox.identity_hash: "sha256:' "$tmp/p1/same/.devbox/docker-compose.yml"
grep -q 'image: ghcr.io/cncsmonster/dotfiles:latest' "$tmp/p1/same/.devbox/docker-compose.yml"
# shellcheck disable=SC2251
! grep -q '^    build:' "$tmp/p1/same/.devbox/docker-compose.yml"
# shellcheck disable=SC2251
! grep -q 'dockerfile: .devbox/runtime/Dockerfile' "$tmp/p1/same/.devbox/docker-compose.yml"
# shellcheck disable=SC2251
! [ -e "$tmp/p1/same/.devbox/runtime/Dockerfile" ]
# shellcheck disable=SC2251
! [ -e "$tmp/p1/same/.devbox/runtime/entrypoint.sh" ]
grep -q 'Host-side devbox container bootstrap script' "$tmp/p1/same/.devbox/runtime/container-init.sh"
# shellcheck disable=SC2251
! grep -q '/host-config/codex' "$tmp/p1/same/.devbox/docker-compose.yml"
grep -q "name: $(jq -r .volumeName "$tmp/p1/same/.devbox/config.json")" "$tmp/p1/same/.devbox/docker-compose.yml"

(cd "$tmp/p2/same" && "$DEVBOX" init >/dev/null)
n1="$(jq -r .name "$tmp/p1/same/.devbox/config.json")"
n2="$(jq -r .name "$tmp/p2/same/.devbox/config.json")"
[ "$n1" != "$n2" ]

mkdir -p "$tmp/fakehome/.codex"
touch "$tmp/fakehome/.codex/config.toml" "$tmp/fakehome/.codex/model_catalog.json"
(cd "$tmp/manual" && HOME="$tmp/fakehome" "$DEVBOX" init --name 'My_Project!!' >/dev/null)
jq -e '.name == "my-project" and .container == "my-project-dev" and .volumeName == "my-project-dev-home" and .identity.strategy == "full-path-hash-v1"' "$tmp/manual/.devbox/config.json" >/dev/null


set +e
(cd "$tmp/conflict" && "$DEVBOX" init --name conflict --force) >"$tmp/conflict.out" 2>&1
conflict_rc=$?
set -e
[ "$conflict_rc" -ne 0 ]
grep -q 'not owned' "$tmp/conflict.out"
[ ! -e "$tmp/conflict/.devbox/config.json" ]

set +e
(cd "$tmp/volumeonly" && "$DEVBOX" init --name volumeonly --force) >"$tmp/volumeonly.out" 2>&1
volumeonly_rc=$?
set -e
[ "$volumeonly_rc" -ne 0 ]
grep -q 'Docker volume exists but is not owned' "$tmp/volumeonly.out"
[ ! -e "$tmp/volumeonly/.devbox/config.json" ]

set +e
(cd "$tmp/badinspect" && "$DEVBOX" init --name badinspect) >"$tmp/badinspect.out" 2>&1
badinspect_rc=$?
set -e
[ "$badinspect_rc" -ne 0 ]
grep -q 'Cannot reliably inspect Docker container' "$tmp/badinspect.out"
[ ! -e "$tmp/badinspect/.devbox/config.json" ]

(cd "$tmp/manual" && "$DEVBOX" update shell=bash >/dev/null)
jq -e '.shell == "bash" and (.updatedAt | type == "string") and (.identity.strategy == "full-path-hash-v1")' "$tmp/manual/.devbox/config.json" >/dev/null
before_update_config="$(sha256sum "$tmp/manual/.devbox/config.json" | awk '{print $1}')"
set +e
(cd "$tmp/manual" && "$DEVBOX" update image=) >"$tmp/update-empty-image.out" 2>&1
update_empty_image_rc=$?
(cd "$tmp/manual" && "$DEVBOX" update shell=) >"$tmp/update-empty-shell.out" 2>&1
update_empty_shell_rc=$?
set -e
[ "$update_empty_image_rc" -ne 0 ]
[ "$update_empty_shell_rc" -ne 0 ]
[ "$(sha256sum "$tmp/manual/.devbox/config.json" | awk '{print $1}')" = "$before_update_config" ]
grep -q 'Invalid image: value must be non-empty' "$tmp/update-empty-image.out"
grep -q 'Invalid shell: value must be non-empty' "$tmp/update-empty-shell.out"
jq -e '(.image | length > 0) and (.shell | length > 0)' "$tmp/manual/.devbox/config.json" >/dev/null

# Host-side bootstrap runs only when marker is missing.
mkdir -p "$tmp/bootstrap"
(cd "$tmp/bootstrap" && "$DEVBOX" init --name boot >/dev/null)
cat > "$tmp/bootstrap/.devbox/runtime/container-init.sh" <<'BOOTEOF'
#!/usr/bin/env bash
set -euo pipefail
echo "bootstrap $1" >> "${DEVBOX_FAKE_DOCKER_STATE:?}/bootstrap.log"
docker exec "$1" touch /tmp/.container-init-executed
BOOTEOF
chmod +x "$tmp/bootstrap/.devbox/runtime/container-init.sh"
(cd "$tmp/bootstrap" && "$DEVBOX" enter >/dev/null)
grep -q 'bootstrap boot-dev' "$tmp/bootstrap.log"
[ "$(grep -c 'bootstrap boot-dev' "$tmp/bootstrap.log")" -eq 1 ]
(cd "$tmp/bootstrap" && "$DEVBOX" enter >/dev/null)
[ "$(grep -c 'bootstrap boot-dev' "$tmp/bootstrap.log")" -eq 1 ]
printf 'y
' | (cd "$tmp/bootstrap" && "$DEVBOX" rebuild >/dev/null)
[ "$(grep -c 'bootstrap boot-dev' "$tmp/bootstrap.log")" -eq 2 ]
# shellcheck disable=SC2251
! grep -q -- '--build' "$tmp/compose.log"

# Existing owned resources permit safe operations.
(cd "$tmp/ops" && "$DEVBOX" init --name ops >/dev/null)
export DEVBOX_FAKE_OWNED_NAME=ops
(cd "$tmp/ops" && "$DEVBOX" stop >/dev/null)
(cd "$tmp/ops" && "$DEVBOX" enter >/dev/null)
(cd "$tmp/ops" && "$DEVBOX" status >/dev/null)
printf 'y\n' | (cd "$tmp/ops" && "$DEVBOX" rebuild >/dev/null)
grep -q -- '--force-recreate' "$tmp/compose.log"
# shellcheck disable=SC2251
! grep -q -- ' down .* -v' "$tmp/compose.log"
printf 'n\n' | (cd "$tmp/ops" && "$DEVBOX" clean >/dev/null)
# shellcheck disable=SC2251
! grep -q -- ' down .* -v' "$tmp/compose.log"
unset DEVBOX_FAKE_OWNED_NAME

# Docker operation failures include the long-name recovery hint.
(cd "$tmp/failops" && "$DEVBOX" init --name failops >/dev/null)
export DEVBOX_FAKE_OWNED_NAME=failops
export DEVBOX_FAKE_FAIL_DOCKER_CMD=start
set +e
(cd "$tmp/failops" && "$DEVBOX" enter) >"$tmp/fail-enter.out" 2>&1
fail_enter_rc=$?
set -e
[ "$fail_enter_rc" -ne 0 ]
grep -q 'try a shorter manual name' "$tmp/fail-enter.out"
export DEVBOX_FAKE_FAIL_DOCKER_CMD=rm
set +e
printf 'y\n' | (cd "$tmp/failops" && "$DEVBOX" rebuild) >"$tmp/fail-rebuild.out" 2>&1
fail_rebuild_rc=$?
set -e
[ "$fail_rebuild_rc" -ne 0 ]
grep -q 'try a shorter manual name' "$tmp/fail-rebuild.out"
unset DEVBOX_FAKE_FAIL_DOCKER_CMD DEVBOX_FAKE_OWNED_NAME

# Installer repairs stale/broken symlinks instead of aborting under set -e.
mkdir -p "$tmp/install/skills" "$tmp/install/bin"
ln -s "$tmp/install/missing-skill-source" "$tmp/install/skills/devbox"
ln -s "$tmp/install/missing-cli-source" "$tmp/install/bin/devbox"
AGENT_SKILLS_DIR="$tmp/install/skills" LOCAL_BIN_DIR="$tmp/install/bin" "$INSTALL" >"$tmp/install.out" 2>&1
[ "$(readlink "$tmp/install/skills/devbox")" = "$ROOT" ]
[ "$(readlink "$tmp/install/bin/devbox")" = "$DEVBOX" ]
grep -q 'Replacing existing symlink for Agent Skill' "$tmp/install.out"
grep -q 'Replacing existing symlink for devbox CLI' "$tmp/install.out"

echo "devbox smoke tests passed"
