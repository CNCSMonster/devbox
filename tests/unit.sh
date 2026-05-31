#!/usr/bin/env bash
set -euo pipefail

# Unit tests for devbox pure functions.
# Only requires bash + jq. No Docker needed.
#
# Run: bash tests/unit.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_SCRIPT="$SCRIPT_DIR/../scripts/devbox"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── Test framework ──────────────────────────────────────────────────────
TESTS=0 FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }
pass() { TESTS=$((TESTS + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass; else fail "$desc (expected '$expected', got '$actual')"; fi
}

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then pass; else fail "$desc (expected match '$pattern', got '$actual')"; fi
}

assert_ok() {
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then pass; else fail "$desc"; fi
}

assert_fail() {
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then fail "$desc"; else pass; fi
}

# ── Source devbox functions (mock overrides come AFTER) ─────────────────
DEVBOX_DIR="$tmp/.devbox"
CONFIG_FILE="$DEVBOX_DIR/config.json"
COMPOSE_FILE="$DEVBOX_DIR/docker-compose.yml"
RUNTIME_DIR="$DEVBOX_DIR/runtime"
RUNTIME_CONTAINER_INIT="$RUNTIME_DIR/container-init.sh"

source "$DEVBOX_SCRIPT"

# Re-apply mocks and variable overrides AFTER source (source replaces functions)
DEVBOX_DIR="$tmp/.devbox"
CONFIG_FILE="$DEVBOX_DIR/config.json"
COMPOSE_FILE="$DEVBOX_DIR/docker-compose.yml"
RUNTIME_DIR="$DEVBOX_DIR/runtime"
RUNTIME_CONTAINER_INIT="$RUNTIME_DIR/container-init.sh"
mkdir -p "$DEVBOX_DIR" "$RUNTIME_DIR"

docker() { return 0; }
identity_json() {
  jq -n --arg projectRoot "/test/project" \
        --arg identityHash "sha256:$(printf '%064d' 1)" \
        --arg ownerUid "1000" --arg host "testhost" \
        --arg dockerContext "default" --arg strategy "full-path-hash-v1" \
        '{strategy:$strategy,projectRoot:$projectRoot,identityHash:$identityHash,ownerUid:$ownerUid,host:$host,dockerContext:$dockerContext}'
}
canonical_project_root() { echo "/test/project"; }

# ── slugify ─────────────────────────────────────────────────────────────
echo "=== slugify ==="
assert_eq "simple path"     "home-user-project"  "$(slugify "/home/user/project")"
assert_eq "uppercase"       "my-project"          "$(slugify "My-Project")"
assert_eq "spaces"          "my-cool-project"     "$(slugify "my cool project")"
assert_eq "special chars"   "my-project"          "$(slugify 'my@#$%project')"
assert_eq "consecutive"     "a-b"                 "$(slugify "a--__b")"
assert_eq "leading dash"    "abc"                 "$(slugify "-abc")"
assert_eq "trailing dash"   "abc"                 "$(slugify "abc-")"
assert_eq "hash suffix"     "project-a1b2c3"      "$(slugify "project-a1b2c3")"
assert_eq "digits kept"     "v2-project-123"      "$(slugify "v2-project-123")"
assert_eq "empty → project" "project"             "$(slugify "")"
assert_eq "all special"     "project"             "$(slugify '@#$%^&*')"
assert_eq "dot separated"   "my-org-my-project"   "$(slugify "my-org/my-project")"

# ── candidate_json ──────────────────────────────────────────────────────
echo "=== candidate_json ==="
cfg="$(candidate_json "img:test" "")"
assert_eq "version" "1"        "$(jq -r '.version' <<<"$cfg")"
assert_eq "image"   "img:test" "$(jq -r '.image' <<<"$cfg")"
assert_eq "shell"   "zsh"      "$(jq -r '.shell' <<<"$cfg")"
assert_eq "name == composeProject" "" \
  "$(jq -r 'if .name == .composeProject then "" else "mismatch" end' <<<"$cfg")"
assert_eq "container = name-dev" "" \
  "$(jq -r 'if .container == .name + "-dev" then "" else "mismatch" end' <<<"$cfg")"
assert_eq "imageName = name:dev" "" \
  "$(jq -r 'if .imageName == .name + ":dev" then "" else "mismatch" end' <<<"$cfg")"
assert_eq "volumeName = name-dev-home" "" \
  "$(jq -r 'if .volumeName == .name + "-dev-home" then "" else "mismatch" end' <<<"$cfg")"
assert_eq "displayName = projectRoot" "/test/project" \
  "$(jq -r '.displayName' <<<"$cfg")"

cfg2="$(candidate_json "img:test" "My Project!")"
assert_eq "manual name slugified" "my-project" "$(jq -r '.name' <<<"$cfg2")"

for f in version name displayName container composeProject imageName volumeName image shell identity createdAt; do
  assert_ok "has field: $f" jq -e "has(\"$f\")" <<<"$cfg"
done

# ── config_is_valid ─────────────────────────────────────────────────────
echo "=== config_is_valid ==="

valid_cfg() {
  local name="${1:-myproject}" image="${2:-img:latest}"
  jq -n --argjson version 1 \
    --arg name "$name" --arg displayName "/test" \
    --arg container "${name}-dev" --arg composeProject "$name" \
    --arg imageName "${name}:dev" --arg volumeName "${name}-dev-home" \
    --arg image "$image" --arg shell "zsh" --arg createdAt "2026-01-01" \
    --arg strategy "full-path-hash-v1" --arg projectRoot "/test" \
    --arg identityHash "sha256:$(printf '%064d' 1)" \
    --arg ownerUid "1000" --arg host "h" --arg dockerContext "default" \
    '{version:$version,name:$name,displayName:$displayName,container:$container,composeProject:$composeProject,imageName:$imageName,volumeName:$volumeName,image:$image,shell:$shell,createdAt:$createdAt,identity:{strategy:$strategy,projectRoot:$projectRoot,identityHash:$identityHash,ownerUid:$ownerUid,host:$host,dockerContext:$dockerContext}}'
}

mkdir -p "$DEVBOX_DIR"
valid_cfg > "$CONFIG_FILE"
assert_ok "valid config" config_is_valid

rm -f "$CONFIG_FILE"
assert_fail "missing file" config_is_valid

jq '.name = "Has Space"' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "name with space" config_is_valid

jq '.name = "-bad"' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "leading dash" config_is_valid

jq '.name = "bad-"' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "trailing dash" config_is_valid

jq '.name = "UPPER"' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "uppercase" config_is_valid

jq '.image = ""' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "empty image" config_is_valid

jq '.shell = ""' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "empty shell" config_is_valid

jq '.identity.identityHash = "sha256:xyz"' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "bad hash format" config_is_valid

jq '.version = 2' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "wrong version" config_is_valid

jq '.container = "wrong-dev"' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "container mismatch" config_is_valid

jq '.projectRootHash = "abc123"' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "has projectRootHash (deprecated)" config_is_valid

jq '.identity.projectRootHash = "abc123"' <<<"$(valid_cfg)" > "$CONFIG_FILE"
assert_fail "identity has projectRootHash" config_is_valid

# ── validate_update_field ──────────────────────────────────────────────
echo "=== validate_update_field ==="
assert_ok   "image valid"  validate_update_field "image" "img:v2"
assert_ok   "shell valid"  validate_update_field "shell" "bash"
assert_fail "image empty"  validate_update_field "image" ""
assert_fail "shell empty"  validate_update_field "shell" ""

# ── identity_hash_hex10 ────────────────────────────────────────────────
echo "=== identity_hash_hex10 ==="
id_json='{"identityHash":"sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"}'
assert_eq "hex10 length" "10"         "$(printf '%s' "$(identity_hash_hex10 "$id_json")" | wc -c)"
assert_eq "hex10 value"  "abcdef1234" "$(identity_hash_hex10 "$id_json")"

# ── default_name_from_identity ─────────────────────────────────────────
echo "=== default_name_from_identity ==="
identity="$(identity_json)"
name="$(default_name_from_identity "$identity")"
assert_match "name has hash10 suffix" "[a-z0-9]+-[a-f0-9]{10}" "$name"
assert_match "name starts with slug"  "^test-project-" "$name"

# ── Results ─────────────────────────────────────────────────────────────
echo ""
echo "Results: $TESTS passed, $FAILURES failed (total: $((TESTS + FAILURES)))"
if [ "$FAILURES" -gt 0 ]; then exit 1; fi
