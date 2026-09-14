# 🌐 action-web-server — Build, publish to S3, invalidate CloudFront

[![CI][ci-badge]][ci-url]
[![License: MIT][license-badge]][license-url]

> **GitHub Action** to build a web app, publish it to S3 with cache-aware grace pruning, and invalidate the CloudFront distribution in front of it.

Authenticates to AWS via OIDC (no long-lived keys), loads the build environment from SSM Parameter Store into `.env`, runs the build command, syncs the output to S3 with per-file cache headers, prunes objects that have been absent from the build for a grace period, and invalidates CloudFront so viewers pick up the new release.

## Contents

- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Permissions](#permissions)
- [One bucket per app](#one-bucket-per-app)
- [Unhashed files](#unhashed-files)
- [Adopting an existing bucket](#adopting-an-existing-bucket)
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
          DISTRIBUTION_ID: E1ABCDEF2GHIJK
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
| `DISTRIBUTION_ID` | CloudFront distribution ID to invalidate after publishing | Yes | — |
| `APP_DIR` | Directory (relative to the repo root) that receives `.env` and where `BUILD_COMMAND` runs | No | `.` |
| `BUILD_COMMAND` | Shell command that builds the app, run inside `APP_DIR` | No | `pnpm build` |
| `BUILD_FOLDER` | Build output folder (relative to `APP_DIR`) whose contents are published | No | `dist` |
| `PRUNE_GRACE_DAYS` | Positive integer; objects absent from the build are deleted once absent for at least this many days | No | `7` |
| `NO_CACHE_PATTERNS` | Comma-separated `aws s3 sync` patterns (relative to `BUILD_FOLDER`) published with `cache-control no-cache`, added to the built-in `*.html`, `sw.js`, `manifest.webmanifest` | No | — |
| `LEAK_CHECK` | `true` scans the build output for the values of the `SecureString` parameters under `AWS_ENV_PATH` that are 16 characters or longer, and fails the build on a match; any other value skips the scan | No | `true` |

## Outputs

This action produces no outputs.

## Permissions

```yaml
permissions:
  id-token: write
  contents: read
```

### Minimum IAM policy

This is the whole permission set the action consumes — no more, no less. The
`cloud-iac` `web-server` module grants exactly these; if you provision the
bucket by hand, this is the policy to attach to the OIDC role.

`s3:GetBucketLocation` is **not** required: the AWS CLI resolves the bucket
region from the configured region and, on a mismatch, falls back to
`HeadBucket`, which `s3:ListBucket` already covers.

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
      "Action": ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"],
      "Resource": "arn:aws:cloudfront::<account-id>:distribution/<distribution-id>"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:GetParametersByPath",
      "Resource": "arn:aws:ssm:<region>:<account-id>:parameter<aws-env-path>/*"
    }
  ]
}
```

## One bucket per app

**Precondition, not a recommendation.** The action syncs to the bucket root
(`s3://${BUCKET_NAME}`) and the grace prune lists the whole bucket. Two apps
sharing a bucket means one app's prune deletes the other's files as soon as its
grace window expires.

If two apps share a bucket today, split them before the first deploy with this
action.

## Unhashed files

Everything that is not matched by `NO_CACHE_PATTERNS` (or by the built-in
`*.html`, `sw.js`, `manifest.webmanifest`) is published with
`Cache-Control: max-age=31536000,public,immutable` — a one-year cache that
browsers will not revalidate.

That is correct for content-hashed filenames and wrong for everything else. Any
file reaching the build output **without** a content hash in its name must
therefore be handled one of two ways:

1. **Import it through `src/`** so the bundler hashes it. Preferred — the file
   then benefits from the one-year cache and updates take effect immediately.
   An asset referenced by an absolute URL (`url('/textures/hands.svg')` in CSS,
   `src="/og-image.png"` in HTML) is *not* processed and does *not* get a hash.
2. **List it in `NO_CACHE_PATTERNS`** so it is published with `no-cache`
   instead.

Typical unhashed files: anything copied verbatim from `public/`, and anything a
build plugin emits by fixed name (a `sitemap.xml` written in `generateBundle`,
for instance, never appears in `public/` and is easy to miss).

## Adopting an existing bucket

A bucket that has never been pruned holds years of orphans that are invisible
until the first prune. Work through these four steps before the grace window
expires.

**Precondition:** one bucket per app (above).

### Step 1 — stamping deploy

The first deploy with this action creates the ledger and stamps every object
that is absent from the build. **It deletes nothing** — every timestamp is
`now`.

### Step 2 — review the ledger, inside the window (mandatory gate)

> **The ledger is the dry run.** `.s3-publish/stale.tsv` is literally the
> pending deletion list, with dates. There is no `--dry-run` mode because none
> is needed, and the preview lasts for the whole grace window.

```bash
aws s3 cp s3://BUCKET_NAME/.s3-publish/stale.tsv - | sort
```

Look for anything that never comes from the build output: `.well-known/`,
domain-verification files, manual marketing uploads, assets belonging to another
app.

The bucket is not versioned, so there is no undo. This step is a gate, not a
recommendation.

### Step 3 — reconcile each survivor

- **Should be served** → bring it into the build (`public/` plus an entry in
  `NO_CACHE_PATTERNS` if it is unhashed). It leaves the stale set on the next
  deploy naturally.
- **Does not belong in this bucket** → move it out.

### Step 4 — confirm

Once the grace window expires, the next deploy deletes. Verify with a listing
diff.

### Timing semantics

- The clock starts when a file is **first absent from a build**, not when it was
  created.
- Changing `PRUNE_GRACE_DAYS` does not reset the clock; stamps are preserved and
  only the cutoff moves.
- The comparison is strict: deletion needs a deploy **more than**
  `PRUNE_GRACE_DAYS` after the stamp, not exactly at the boundary.
- The prune only runs during a deploy. An app with no deploys never prunes.

## Architecture

Bash shell scripts wrapped by a composite GitHub Action.

```
├── action.yml                    # Composite action definition
├── core/
│   ├── ssm/
│   │   └── env.sh                # SSM parameters -> APP_DIR/.env (from action-ssm-env-build)
│   ├── build/
│   │   └── run.sh                # Runs BUILD_COMMAND inside APP_DIR
│   ├── s3/
│   │   └── publish.sh            # Two-pass S3 sync + grace-period prune (from action-s3-publish)
│   ├── leak/
│   │   └── check.sh              # SecureString values must not reach the build output
│   └── cloudfront/
│       └── invalidate.sh         # CloudFront invalidation (from action-cloudfront-publish)
├── tests/
│   ├── __mocks__/
│   │   ├── aws                   # AWS CLI stub (records invocations)
│   │   ├── node                  # No-op node stub
│   │   └── npx                   # npx stub (records argv, prints dotenv)
│   ├── ssm.bats                  # BATS tests — core/ssm/env.sh
│   ├── build.bats                # BATS tests — core/build/run.sh
│   ├── s3.bats                   # BATS tests — core/s3/publish.sh
│   ├── leak.bats                 # BATS tests — core/leak/check.sh
│   └── cloudfront.bats           # BATS tests — core/cloudfront/invalidate.sh
├── Makefile                      # test (bats) + lint (shellcheck)
└── version.txt                   # Current version
```

## How it works

`action.yml` defines seven composite steps:

1. **Configure AWS credentials** — `aws-actions/configure-aws-credentials@v6` assumes the OIDC role with the requested duration.
2. **Create .env from SSM** — `core/ssm/env.sh` runs `@heronlabs/env-ssm` (pinned, via `npx`) and writes every parameter under `AWS_ENV_PATH` to `APP_DIR/.env` in dotenv format.
3. **Build** — `core/build/run.sh` runs `BUILD_COMMAND` inside `APP_DIR`.
4. **Configure AWS credentials (again)** — a second `aws-actions/configure-aws-credentials@v6` call refreshes the session so a long build cannot expire the credentials used for publishing and invalidation.
5. **Check for leaked secrets** — `core/leak/check.sh` reads the names of the `SecureString` parameters under `AWS_ENV_PATH` and greps `APP_DIR/BUILD_FOLDER` for each value of 16 characters or more. A match fails the build before anything is published. Set `LEAK_CHECK: 'false'` to skip it.
6. **Publish to S3** — `core/s3/publish.sh` syncs `APP_DIR/BUILD_FOLDER` to the bucket in two passes (long-lived cache for hashed assets, `no-cache` for entry points), then runs the grace-period prune.
7. **Invalidate CloudFront** — `core/cloudfront/invalidate.sh` calls `aws cloudfront create-invalidation --paths "/*"` and waits for it to complete.

## Notes

- **Cache strategy.** `*.html`, `sw.js`, `manifest.webmanifest` and every `NO_CACHE_PATTERNS` entry are published with `cache-control no-cache`; everything else gets `max-age=31536000,public,immutable` (one year, never revalidated). Build output must therefore use content-hashed filenames for assets — see [Unhashed files](#unhashed-files).
- **Grace prune and ledger.** The bucket is never wiped and `aws s3 sync --delete` is never used. Objects present in the bucket but absent from the build are recorded in `.s3-publish/stale.tsv` (`key<TAB>stale-since-epoch`) and deleted only once they have been absent for `PRUNE_GRACE_DAYS`, so in-flight clients keep finding the assets of the previous release. The first run deletes nothing; cleanup happens only at deploy time; keys present in the build are never deleted.
- **Two role sessions.** Credentials are assumed before the SSM read and again before publishing, so `AWS_ROLE_DURATION_SECONDS` only needs to cover the longer of the two halves, not the whole build.
- **Requires `node` on `PATH`.** `@heronlabs/env-ssm` runs via `npx`; the consumer's toolchain setup (`actions/setup-node`) must run before this action.
- **CloudFront invalidation.** After the publish, `/*` is invalidated on `DISTRIBUTION_ID` and the action waits for completion; CloudFront bills per path after the free tier, so frequent deploys may incur small costs.
- Replaces `heronlabs/action-ssm-env-build`, `heronlabs/action-s3-publish` and `heronlabs/action-cloudfront-publish` for web apps served by the cloud-iac `web-server` stack.
- Requires an OIDC trust relationship configured on the AWS account.

## License

MIT

[ci-badge]: https://github.com/heronlabs/action-web-server/actions/workflows/continuous-integration.yml/badge.svg
[ci-url]: https://github.com/heronlabs/action-web-server/actions/workflows/continuous-integration.yml
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg
[license-url]: ./LICENSE
