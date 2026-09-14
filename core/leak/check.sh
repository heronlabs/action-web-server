#!/usr/bin/env bash

set -euo pipefail

LEAK_CHECK="${LEAK_CHECK:-true}"

if [ "${LEAK_CHECK}" != "true" ]; then
    echo "leak check skipped (LEAK_CHECK='${LEAK_CHECK}')"
    exit 0
fi

: "${AWS_ENV_PATH:?AWS_ENV_PATH is required}"
APP_DIR="${APP_DIR:-.}"
BUILD_FOLDER="${BUILD_FOLDER:-dist}"
BUILD_DIR="${APP_DIR}/${BUILD_FOLDER}"
ENV_FILE="${APP_DIR}/.env"

# Values shorter than this are structurally public (GTM container ids, Clarity
# project ids, short flags) and would only produce false positives.
MIN_SECRET_LENGTH=16

if [ ! -d "${BUILD_DIR}" ]; then
    echo "build folder '${BUILD_DIR}' is not a directory" >&2
    exit 1
fi

if [ ! -f "${ENV_FILE}" ]; then
    echo "env file '${ENV_FILE}' not found" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Names of the SecureString parameters one level under AWS_ENV_PATH — the same
# level core/ssm/env.sh reads. Names only, no --with-decryption: the values come
# from the .env that step already wrote, so nothing is decrypted twice and no
# secret is ever passed on a command line.
# shellcheck disable=SC2016  # the backticks are JMESPath literal quoting, not a subshell
aws ssm get-parameters-by-path \
  --path "${AWS_ENV_PATH}" \
  --query 'Parameters[?Type==`SecureString`].Name' \
  --output text >"${WORK}/names.raw"

tr '\t' '\n' <"${WORK}/names.raw" \
  | sed 's|.*/||' \
  | grep -v -e '^None$' -e '^$' >"${WORK}/names.txt" || true

: >"${WORK}/report.txt"

# The .env is attacker-adjacent input: a parameter named PATH, BUILD_DIR, WORK or
# MIN_SECRET_LENGTH would otherwise silently hijack the scan below and turn a
# leak into a pass. Freezing them first turns a collision into a loud failure
# ("readonly variable" under set -e) instead of a false negative.
readonly PATH BUILD_DIR WORK MIN_SECRET_LENGTH

# Subshell: sourcing the build environment must not leak into the rest of the
# script. No `set -a` — indirect expansion reads shell variables, so there is no
# reason to export every secret into grep's environment. Only the report file
# crosses back out.
(
    # shellcheck disable=SC1090
    . "${ENV_FILE}"

    while IFS= read -r name; do
        # env-ssm only writes shell-safe names; anything else cannot be looked up
        # by indirect expansion and is not in the .env either.
        if ! [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            continue
        fi

        value="${!name-}"

        if [ -z "${value}" ] || [ "${#value}" -lt "${MIN_SECRET_LENGTH}" ]; then
            continue
        fi

        if hits="$(grep -rlF -- "${value}" "${BUILD_DIR}")"; then
            printf '%s\n' "${name}" >>"${WORK}/report.txt"
            printf '%s\n' "${hits}" | sed 's|^|    |' >>"${WORK}/report.txt"
        fi
    done <"${WORK}/names.txt"
)

if [ -s "${WORK}/report.txt" ]; then
    {
        echo "LEAK_CHECK failed: SecureString parameter values found in ${BUILD_DIR}"
        cat "${WORK}/report.txt"
        echo "Keep the value out of the bundle (a VITE_ prefixed variable and a \`define\` entry both reach it),"
        echo "or set LEAK_CHECK: 'false' on this app while the leak is being fixed."
    } >&2
    exit 1
fi

echo "LEAK_CHECK passed: no SecureString parameter value found in ${BUILD_DIR}"
