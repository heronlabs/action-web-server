#!/usr/bin/env bats
# bats tests for core/cloudfront/invalidate.sh
# shellcheck disable=SC2030,SC2031  # each @bats test runs in its own subshell; DISTRIBUTION_ID is intentionally test-local

setup() {
  # Put the aws mock stub on PATH
  export PATH="$BATS_TEST_DIRNAME/__mocks__:$PATH"
  local log; log="$(mktemp)"
  export AWS_LOG="$log"
}

teardown() {
  rm -f "$AWS_LOG"
}

@test "happy path: invalidates distribution" {
  export DISTRIBUTION_ID=E123

  run bash "$BATS_TEST_DIRNAME/../core/cloudfront/invalidate.sh"

  [ "$status" -eq 0 ]
  grep 'cloudfront create-invalidation' "$AWS_LOG" | grep -- '--distribution-id E123' | grep -q -- '--paths /\*'
}

@test "happy path: waits for invalidation to complete with the returned id" {
  export DISTRIBUTION_ID=E123

  run bash "$BATS_TEST_DIRNAME/../core/cloudfront/invalidate.sh"

  [ "$status" -eq 0 ]
  grep 'cloudfront wait invalidation-completed' "$AWS_LOG" | grep -- '--distribution-id E123' | grep -q -- '--id I2EXAMPLE'

  local create_at wait_at
  create_at="$(grep -n 'cloudfront create-invalidation' "$AWS_LOG" | head -1 | cut -d: -f1)"
  wait_at="$(grep -n 'cloudfront wait' "$AWS_LOG" | head -1 | cut -d: -f1)"
  [ -n "$create_at" ] && [ -n "$wait_at" ] && [ "$create_at" -lt "$wait_at" ]
}

@test "missing distribution id: hard error, aws never invoked" {
  run bash "$BATS_TEST_DIRNAME/../core/cloudfront/invalidate.sh"

  [ "$status" -ne 0 ]
  [ ! -s "$AWS_LOG" ]
}
