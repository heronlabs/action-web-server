#!/usr/bin/env bash

set -euo pipefail

: "${DISTRIBUTION_ID:?DISTRIBUTION_ID is required}"

invalidation_id="$(aws cloudfront create-invalidation \
  --distribution-id "${DISTRIBUTION_ID}" \
  --paths "/*" \
  --query 'Invalidation.Id' \
  --output text)"

aws cloudfront wait invalidation-completed \
  --distribution-id "${DISTRIBUTION_ID}" \
  --id "${invalidation_id}"
