# 🌐 action-web-server — Build and publish a web app to S3

[![CI][ci-badge]][ci-url]
[![License: MIT][license-badge]][license-url]

> **GitHub Action** to build a web app and publish it to S3 with cache-aware grace pruning.

Authenticates to AWS via OIDC (no long-lived keys), loads the build environment from SSM Parameter Store into `.env`, runs the build command, syncs the output to S3 with per-file cache headers, and prunes objects that have been absent from the build for a grace period.

## Contents

- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Permissions](#permissions)
- [Architecture](#architecture)
- [How it works](#how-it-works)
- [Notes](#notes)
- [License](#license)

## Usage

```yaml
name: Deploy Web

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7

      - uses: pnpm/action-setup@v6

      - uses: actions/setup-node@v7
        with:
          node-version-file: .node-version
          cache: pnpm

      - name: Install dependencies
        shell: bash
        run: pnpm install --frozen-lockfile

      - name: Build and publish
        uses: heronlabs/action-web-server@v1
        with:
          AWS_ROLE_TO_ASSUME: ${{ secrets.AWS_ROLE_ARN }}
          AWS_REGION: us-east-1
          AWS_ROLE_DURATION_SECONDS: 900
          AWS_ENV_PATH: /my-app/prod/
          BUCKET_NAME: my-static-site
          APP_DIR: apps/my-app
          BUILD_COMMAND: pnpm --filter my-app build
          BUILD_FOLDER: dist
```

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `AWS_ROLE_TO_ASSUME` | ARN of the IAM role to assume via OIDC | Yes | — |
| `AWS_REGION` | AWS region where the S3 bucket and SSM parameters live | Yes | — |
| `AWS_ROLE_DURATION_SECONDS` | Duration in seconds for each assumed role session | Yes | — |
| `AWS_ENV_PATH` | SSM parameter path prefix holding the build environment (e.g. `/my-app/prod/`) | Yes | — |
| `BUCKET_NAME` | Destination S3 bucket name | Yes | — |
| `APP_DIR` | Directory (relative to the repo root) that receives `.env` and where `BUILD_COMMAND` runs | No | `.` |
| `BUILD_COMMAND` | Shell command that builds the app, run inside `APP_DIR` | No | `pnpm build` |
| `BUILD_FOLDER` | Build output folder (relative to `APP_DIR`) whose contents are published | No | `dist` |
| `PRUNE_GRACE_DAYS` | Positive integer; objects absent from the build are deleted once absent for at least this many days | No | `7` |
| `NO_CACHE_PATTERNS` | Comma-separated `aws s3 sync` patterns (relative to `BUILD_FOLDER`) published with `cache-control no-cache`, added to the built-in `*.html`, `sw.js`, `manifest.webmanifest` | No | — |

## Outputs

This action produces no outputs.

## Permissions

```yaml
permissions:
  id-token: write
  contents: read
```

<details><summary>AWS IAM policy</summary>

The assumed role must allow reading the SSM path and syncing and pruning the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<bucket-name>"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<bucket-name>/*"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:GetParametersByPath",
      "Resource": "arn:aws:ssm:<region>:<account-id>:parameter<aws-env-path>"
    }
  ]
}
```

</details>

## Architecture

Bash shell scripts wrapped by a composite GitHub Action.

```
├── action.yml                    # Composite action definition
├── core/
│   ├── ssm/
│   │   └── env.sh                # SSM parameters -> APP_DIR/.env (from action-ssm-env-build)
│   ├── build/
│   │   └── run.sh                # Runs BUILD_COMMAND inside APP_DIR
│   └── s3/
│       └── publish.sh            # Two-pass S3 sync + grace-period prune (from action-s3-publish)
├── tests/
│   ├── __mocks__/
│   │   ├── aws                   # AWS CLI stub (records invocations)
│   │   ├── node                  # No-op node stub
│   │   └── npx                   # npx stub (records argv, prints dotenv)
│   ├── ssm.bats                  # BATS tests — core/ssm/env.sh
│   ├── build.bats                # BATS tests — core/build/run.sh
│   └── s3.bats                   # BATS tests — core/s3/publish.sh
├── Makefile                      # test (bats) + lint (shellcheck)
└── version.txt                   # Current version
```

## How it works

`action.yml` defines five composite steps:

1. **Configure AWS credentials** — `aws-actions/configure-aws-credentials@v6` assumes the OIDC role with the requested duration.
2. **Create .env from SSM** — `core/ssm/env.sh` runs `@heronlabs/env-ssm` (pinned, via `npx`) and writes every parameter under `AWS_ENV_PATH` to `APP_DIR/.env` in dotenv format.
3. **Build** — `core/build/run.sh` runs `BUILD_COMMAND` inside `APP_DIR`.
4. **Configure AWS credentials (again)** — a second `aws-actions/configure-aws-credentials@v6` call refreshes the session so a long build cannot expire the credentials used for publishing.
5. **Publish to S3** — `core/s3/publish.sh` syncs `APP_DIR/BUILD_FOLDER` to the bucket in two passes (long-lived cache for hashed assets, `no-cache` for entry points), then runs the grace-period prune.

## Notes

- **Cache strategy.** `*.html`, `sw.js`, `manifest.webmanifest` and every `NO_CACHE_PATTERNS` entry are published with `cache-control no-cache`; everything else gets `max-age=31536000,public` (one year, immutable). Build output must therefore use content-hashed filenames for assets.
- **Grace prune and ledger.** The bucket is never wiped and `aws s3 sync --delete` is never used. Objects present in the bucket but absent from the build are recorded in `.s3-publish/stale.tsv` (`key<TAB>stale-since-epoch`) and deleted only once they have been absent for `PRUNE_GRACE_DAYS`, so in-flight clients keep finding the assets of the previous release. The first run deletes nothing; cleanup happens only at deploy time; keys present in the build are never deleted.
- **Two role sessions.** Credentials are assumed before the SSM read and again before publishing, so `AWS_ROLE_DURATION_SECONDS` only needs to cover the longer of the two halves, not the whole build.
- **Requires `node` on `PATH`.** `@heronlabs/env-ssm` runs via `npx`; the consumer's toolchain setup (`actions/setup-node`) must run before this action.
- **CloudFront is not touched.** `*.html`, `sw.js` and `manifest.webmanifest` are served `no-cache` from the origin and hashed assets never change, so no invalidation is needed.
- Replaces `heronlabs/action-ssm-env-build` and `heronlabs/action-s3-publish` for web apps served by the cloud-iac `web-server` stack.
- Requires an OIDC trust relationship configured on the AWS account.

## License

MIT

[ci-badge]: https://github.com/heronlabs/action-web-server/actions/workflows/continuous-integration.yml/badge.svg
[ci-url]: https://github.com/heronlabs/action-web-server/actions/workflows/continuous-integration.yml
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg
[license-url]: ./LICENSE
