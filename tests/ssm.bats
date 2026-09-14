#!/usr/bin/env bats
# bats tests for core/ssm/env.sh
#
# Uses npx and node stubs. Each test runs the script in a throwaway sandbox
# with a controlled PATH and asserts on exit codes, .env content, and stub logs.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../core/ssm/env.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/__mocks__"
  BASH_BIN="$(command -v bash)"
  SANDBOX="$(mktemp -d)"
  NPX_LOG="$SANDBOX/npx.log"; : >"$NPX_LOG"

  # Read the pinned env-ssm version from the script itself for assertions
  ENV_SSM_VERSION="$(grep -oE 'ENV_SSM_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "$SCRIPT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  PINNED_SPEC="@heronlabs/env-ssm@${ENV_SSM_VERSION}"
}

teardown() {
  rm -rf "$SANDBOX"
}

# Run core/ssm/env.sh inside the sandbox with a controlled PATH.
# Usage: run_script <path> [VAR=value ...]
# Sets EXIT_CODE; stdout/stderr land in $SANDBOX/stdout and $SANDBOX/stderr.
run_script() {
  local path="$1"; shift
  set +e
  ( cd "$SANDBOX" \
    && env PATH="$path" NPX_LOG="$NPX_LOG" "$@" \
      "$BASH_BIN" "$SCRIPT" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" )
  EXIT_CODE=$?
  set -e
}

# ---------------------------------------------------------------- tests

@test "happy path: writes .env in cwd, invokes npx with pinned spec and --format=dotenv" {
  run_script "$STUB_DIR:$PATH" AWS_ENV_PATH=/some/path

  [ "$EXIT_CODE" -eq 0 ]
  [ -f "$SANDBOX/.env" ]
  grep -qxF "FOO='bar'" "$SANDBOX/.env"
  grep -qF -- "--yes $PINNED_SPEC --format=dotenv" "$NPX_LOG"
}

@test "app dir: writes .env inside APP_DIR" {
  mkdir -p "$SANDBOX/apps/web"
  run_script "$STUB_DIR:$PATH" AWS_ENV_PATH=/some/path APP_DIR=apps/web

  [ "$EXIT_CODE" -eq 0 ]
  [ -f "$SANDBOX/apps/web/.env" ]
  [ ! -e "$SANDBOX/.env" ]
  grep -qxF "FOO='bar'" "$SANDBOX/apps/web/.env"
}

@test "missing AWS_ENV_PATH: exits non-zero, npx not invoked, no .env" {
  run_script "$STUB_DIR:$PATH"

  [ "$EXIT_CODE" -ne 0 ]
  [ ! -s "$NPX_LOG" ]
  [ ! -e "$SANDBOX/.env" ]
}

@test "missing node: exits non-zero, stderr mentions node requirement, npx not invoked" {
  local npx_only_dir; npx_only_dir="$SANDBOX/npx-only"
  mkdir -p "$npx_only_dir"
  cp "$STUB_DIR/npx" "$npx_only_dir/npx"

  run_script "$npx_only_dir" AWS_ENV_PATH=/some/path

  [ "$EXIT_CODE" -ne 0 ]
  grep -qF "node is required" "$SANDBOX/stderr"
  [ ! -s "$NPX_LOG" ]
  [ ! -e "$SANDBOX/.env" ]
}

@test "APP_DIR not a directory: exits non-zero, npx not invoked" {
  run_script "$STUB_DIR:$PATH" AWS_ENV_PATH=/some/path APP_DIR=missing

  [ "$EXIT_CODE" -ne 0 ]
  grep -qF "not a directory" "$SANDBOX/stderr"
  [ ! -s "$NPX_LOG" ]
  [ ! -e "$SANDBOX/missing/.env" ]
}
