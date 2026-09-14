#!/usr/bin/env bats
# bats tests for core/build/run.sh
#
# Puts a fake `pnpm` on PATH that records its cwd and argv, runs the script in
# a throwaway sandbox, and asserts on exit codes and the recorded call.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../core/build/run.sh"
  BASH_BIN="$(command -v bash)"
  SANDBOX="$(mktemp -d)"
  PNPM_LOG="$SANDBOX/pnpm.log"; : >"$PNPM_LOG"

  # Fake pnpm: one line `<cwd> <argv>` per call.
  STUB_DIR="$SANDBOX/stubs"
  mkdir -p "$STUB_DIR"
  cat >"$STUB_DIR/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(pwd -P)" "$*" >>"$PNPM_LOG"
STUB
  chmod +x "$STUB_DIR/pnpm"
}

teardown() {
  rm -rf "$SANDBOX"
}

# Run core/build/run.sh inside the sandbox with the pnpm stub on PATH.
# Usage: run_script [VAR=value ...]
# Sets EXIT_CODE; stdout/stderr land in $SANDBOX/stdout and $SANDBOX/stderr.
run_script() {
  set +e
  ( cd "$SANDBOX" \
    && env PATH="$STUB_DIR:$PATH" PNPM_LOG="$PNPM_LOG" "$@" \
      "$BASH_BIN" "$SCRIPT" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" )
  EXIT_CODE=$?
  set -e
}

real_path() { (cd "$1" && pwd -P); }

# ---------------------------------------------------------------- tests

@test "default: runs 'pnpm build' in the current directory" {
  run_script

  [ "$EXIT_CODE" -eq 0 ]
  [ "$(cat "$PNPM_LOG")" = "$(real_path "$SANDBOX") build" ]
}

@test "app dir: runs the build command inside APP_DIR" {
  mkdir -p "$SANDBOX/apps/web"
  run_script APP_DIR=apps/web

  [ "$EXIT_CODE" -eq 0 ]
  [ "$(cat "$PNPM_LOG")" = "$(real_path "$SANDBOX/apps/web") build" ]
}

@test "custom BUILD_COMMAND: honoured verbatim" {
  run_script BUILD_COMMAND='pnpm --filter my-app build'

  [ "$EXIT_CODE" -eq 0 ]
  [ "$(cat "$PNPM_LOG")" = "$(real_path "$SANDBOX") --filter my-app build" ]
}

@test "empty BUILD_COMMAND: falls back to 'pnpm build'" {
  run_script BUILD_COMMAND=

  [ "$EXIT_CODE" -eq 0 ]
  [ "$(cat "$PNPM_LOG")" = "$(real_path "$SANDBOX") build" ]
}

@test "failing build command: exit code propagates" {
  run_script BUILD_COMMAND='exit 3'

  [ "$EXIT_CODE" -eq 3 ]
  [ ! -s "$PNPM_LOG" ]
}

@test "APP_DIR not a directory: exits non-zero, build never runs" {
  run_script APP_DIR=missing

  [ "$EXIT_CODE" -ne 0 ]
  grep -qF "not a directory" "$SANDBOX/stderr"
  [ ! -s "$PNPM_LOG" ]
}
