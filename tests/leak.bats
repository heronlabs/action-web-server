#!/usr/bin/env bats
# bats tests for core/leak/check.sh
#
# Builds a throwaway cwd with a build folder and a .env, points an `aws` stub at
# PATH, runs the action script, and asserts on the exit code, the logged aws
# calls and what the failure output does (and does not) contain.
# No network, no real AWS.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../core/leak/check.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/__mocks__"   # contains the `aws` stub
  FIX_DIR="$(mktemp -d)"
  FIX_PARAMS="$FIX_DIR/params.txt"; : >"$FIX_PARAMS"  # SecureString names, one per line
  RUN_BUILD_DIR="dist"                                # build folder under cwd; empty = none
  RUN_ENV_DIR="."                                     # dir holding .env; empty = no .env
  RUN_ENV_LINES=()                                    # dotenv lines written to .env
  RUN_DIST_FILES=()                                   # "relative/path=contents" entries
}

teardown() {
  rm -rf "$FIX_DIR"
}

# seed_param /full/ssm/name ...
seed_param() { printf '%s\n' "$@" >>"$FIX_PARAMS"; }

# Run core/leak/check.sh inside a throwaway cwd.
# Usage: run_check [VAR=value ...]
# Sets RUN_RC / RUN_OUT and leaves the aws call log at RUN_AWSLOG.
run_check() {
  local cwd; cwd="$(mktemp -d)"
  RUN_AWSLOG="$(mktemp)"
  : >"$RUN_AWSLOG"

  if [ -n "$RUN_BUILD_DIR" ]; then
    mkdir -p "$cwd/$RUN_BUILD_DIR"
    printf '<!doctype html>\n' >"$cwd/$RUN_BUILD_DIR/index.html"
    local entry rel body
    for entry in ${RUN_DIST_FILES[@]+"${RUN_DIST_FILES[@]}"}; do
      rel="${entry%%=*}"
      body="${entry#*=}"
      mkdir -p "$cwd/$RUN_BUILD_DIR/$(dirname "$rel")"
      printf '%s\n' "$body" >"$cwd/$RUN_BUILD_DIR/$rel"
    done
  fi

  if [ -n "$RUN_ENV_DIR" ]; then
    mkdir -p "$cwd/$RUN_ENV_DIR"
    : >"$cwd/$RUN_ENV_DIR/.env"
    local line
    for line in ${RUN_ENV_LINES[@]+"${RUN_ENV_LINES[@]}"}; do
      printf '%s\n' "$line" >>"$cwd/$RUN_ENV_DIR/.env"
    done
  fi

  set +e
  RUN_OUT="$(
    cd "$cwd" &&
    env PATH="$STUB_DIR:$PATH" \
        AWS_LOG="$RUN_AWSLOG" \
        AWS_SECURE_PARAMS_FILE="$FIX_PARAMS" \
        "$@" \
        bash "$SCRIPT" 2>&1
  )"
  RUN_RC=$?
  set -e
  rm -rf "$cwd"
}

# ---------------------------------------------------------------- tests

@test "leak found: long SecureString value in the bundle fails the build" {
  seed_param /my-app/SENTRY_AUTH_TOKEN
  RUN_ENV_LINES=("SENTRY_AUTH_TOKEN='sntrys_0123456789abcdef'")
  RUN_DIST_FILES=("assets/index-a1b2c3.js=const t='sntrys_0123456789abcdef';")

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -eq 1 ]
  echo "$RUN_OUT" | grep -q 'SENTRY_AUTH_TOKEN'
  echo "$RUN_OUT" | grep -q 'assets/index-a1b2c3.js'

  rm -f "$RUN_AWSLOG"
}

@test "leak found: the failure output never prints the value itself" {
  seed_param /my-app/SENTRY_AUTH_TOKEN
  RUN_ENV_LINES=("SENTRY_AUTH_TOKEN='sntrys_0123456789abcdef'")
  RUN_DIST_FILES=("assets/index-a1b2c3.js=const t='sntrys_0123456789abcdef';")

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -eq 1 ]
  [ "$(echo "$RUN_OUT" | grep -c 'sntrys_0123456789abcdef')" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "clean build: long SecureString value absent from the bundle passes" {
  seed_param /my-app/SENTRY_AUTH_TOKEN
  RUN_ENV_LINES=("SENTRY_AUTH_TOKEN='sntrys_0123456789abcdef'")
  RUN_DIST_FILES=("assets/index-a1b2c3.js=const t='nothing to see';")

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "short values: a SecureString under 16 characters in the bundle is ignored" {
  seed_param /my-app/VITE_GTM_ID
  RUN_ENV_LINES=("VITE_GTM_ID='GTM-ABC1234'")
  RUN_DIST_FILES=("assets/index-a1b2c3.js=const g='GTM-ABC1234';")

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "scope: only SecureString parameters are requested from SSM" {
  seed_param /my-app/SENTRY_AUTH_TOKEN
  RUN_ENV_LINES=("SENTRY_AUTH_TOKEN='sntrys_0123456789abcdef'")

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -eq 0 ]
  grep -q -- '--path /my-app' "$RUN_AWSLOG"
  # shellcheck disable=SC2016  # the backticks are JMESPath literal quoting, not a subshell
  grep -qF -- 'Parameters[?Type==`SecureString`].Name' "$RUN_AWSLOG"
  [ "$(grep -c -- '--with-decryption' "$RUN_AWSLOG")" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "no SecureString parameters: nothing scanned, exits clean" {
  RUN_ENV_LINES=("SENTRY_ORG='heronlabs'")
  RUN_DIST_FILES=("assets/index-a1b2c3.js=const o='heronlabs';")

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "nested output: a leak in a subfolder is found" {
  seed_param /my-app/SENTRY_AUTH_TOKEN
  RUN_ENV_LINES=("SENTRY_AUTH_TOKEN='sntrys_0123456789abcdef'")
  RUN_DIST_FILES=("nested/deep/chunk-d4e5f6.js=const t='sntrys_0123456789abcdef';")

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -eq 1 ]
  echo "$RUN_OUT" | grep -q 'nested/deep/chunk-d4e5f6.js'

  rm -f "$RUN_AWSLOG"
}

@test "app dir: .env and build folder are resolved under APP_DIR" {
  seed_param /my-app/SENTRY_AUTH_TOKEN
  RUN_BUILD_DIR="apps/my-app/dist"
  RUN_ENV_DIR="apps/my-app"
  RUN_ENV_LINES=("SENTRY_AUTH_TOKEN='sntrys_0123456789abcdef'")
  RUN_DIST_FILES=("assets/index-a1b2c3.js=const t='sntrys_0123456789abcdef';")

  run_check AWS_ENV_PATH=/my-app APP_DIR=apps/my-app

  [ "$RUN_RC" -eq 1 ]
  echo "$RUN_OUT" | grep -q 'SENTRY_AUTH_TOKEN'

  rm -f "$RUN_AWSLOG"
}

@test "disabled: LEAK_CHECK=false skips everything, aws never invoked" {
  seed_param /my-app/SENTRY_AUTH_TOKEN
  RUN_ENV_LINES=("SENTRY_AUTH_TOKEN='sntrys_0123456789abcdef'")
  RUN_DIST_FILES=("assets/index-a1b2c3.js=const t='sntrys_0123456789abcdef';")

  run_check AWS_ENV_PATH=/my-app LEAK_CHECK=false

  [ "$RUN_RC" -eq 0 ]
  [ ! -s "$RUN_AWSLOG" ]

  rm -f "$RUN_AWSLOG"
}

@test "missing AWS_ENV_PATH: hard error, aws never invoked" {
  run_check

  [ "$RUN_RC" -ne 0 ]
  [ ! -s "$RUN_AWSLOG" ]

  rm -f "$RUN_AWSLOG"
}

@test "missing build folder: hard error, aws never invoked" {
  RUN_BUILD_DIR=""

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -ne 0 ]
  echo "$RUN_OUT" | grep -q 'not a directory'
  [ ! -s "$RUN_AWSLOG" ]

  rm -f "$RUN_AWSLOG"
}

@test "hijacked .env: a parameter shadowing PATH fails loudly instead of scanning clean" {
  seed_param /my-app/SENTRY_AUTH_TOKEN
  RUN_ENV_LINES=(
    "PATH='/nonexistent'"
    "SENTRY_AUTH_TOKEN='sntrys_0123456789abcdef'"
  )
  RUN_DIST_FILES=("assets/index-a1b2c3.js=const t='sntrys_0123456789abcdef';")

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -ne 0 ]
  echo "$RUN_OUT" | grep -q 'readonly variable'
  [ "$(echo "$RUN_OUT" | grep -c 'LEAK_CHECK passed')" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "missing .env: hard error, aws never invoked" {
  RUN_ENV_DIR=""

  run_check AWS_ENV_PATH=/my-app

  [ "$RUN_RC" -ne 0 ]
  echo "$RUN_OUT" | grep -q 'not found'
  [ ! -s "$RUN_AWSLOG" ]

  rm -f "$RUN_AWSLOG"
}
