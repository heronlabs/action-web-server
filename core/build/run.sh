#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${APP_DIR:-.}"
BUILD_COMMAND="${BUILD_COMMAND:-pnpm build}"

if [ ! -d "${APP_DIR}" ]; then
    echo "APP_DIR '${APP_DIR}' is not a directory" >&2
    exit 1
fi

(cd "${APP_DIR}" && bash -c "${BUILD_COMMAND}")
