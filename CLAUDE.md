<!-- supera:guardrails -->
## Working with this repo (managed by /init — edits between these markers are overwritten on re-init)

- **Edit, don't rewrite.** Change only the needed entry in a config/generated file (`package.json`, lockfiles, manifests, CI yaml); preserve the rest. Never regenerate a whole file to add one line.
- **No scope creep.** Build only what was asked; no speculative abstractions, layers, or options. Prefer the simplest working solution.
- **Ambiguous literals: flag, don't guess.** Config keys, IDs, and env names can be literal values, not mappings. State which reading you took.
- **Scope a change to where it belongs** — most changes are localized to one area; touch other repos only when the change genuinely cuts across, and then update the related repos too.
<!-- /supera:guardrails -->

## Stack
- **Runtime**: Bash (composite GitHub Action)
- **Test framework**: [BATS](https://github.com/bats-core/bats-core) — `tests/*.bats`, one file per script
- **Linter**: [shellcheck](https://www.shellcheck.net/) — all shell scripts + test files + mocks
- **Entry points**: `core/ssm/env.sh`, `core/build/run.sh`, `core/s3/publish.sh`, `core/cloudfront/invalidate.sh` — invoked in that order by `action.yml` composite steps; `core/` is split by domain (`ssm/` from action-ssm-env-build, `s3/` from action-s3-publish, `cloudfront/` from action-cloudfront-publish, `build/` new)

## Commands
| Command | Description |
|---------|-------------|
| `make test` | Run BATS tests |
| `make lint` | Run shellcheck on all shell scripts |

## Key files
| File | Purpose |
|------|---------|
| `action.yml` | Composite action definition (inputs, outputs, steps) |
| `core/ssm/env.sh` | SSM parameters -> `APP_DIR/.env` via pinned `@heronlabs/env-ssm` |
| `core/build/run.sh` | Runs `BUILD_COMMAND` inside `APP_DIR` |
| `core/s3/publish.sh` | Two-pass S3 sync (long cache / no-cache) + grace-period ledger prune |
| `core/cloudfront/invalidate.sh` | CloudFront invalidation + wait |
| `tests/ssm.bats` | BATS tests for `core/ssm/env.sh` |
| `tests/build.bats` | BATS tests for `core/build/run.sh` |
| `tests/s3.bats` | BATS tests for `core/s3/publish.sh` |
| `tests/cloudfront.bats` | BATS tests for `core/cloudfront/invalidate.sh` |
| `tests/__mocks__/aws` | AWS CLI stub (records invocations, fakes ledger/bucket state) |
| `tests/__mocks__/npx` | npx stub (records argv, prints dotenv) |
| `tests/__mocks__/node` | No-op node stub |
| `Makefile` | Test + lint targets |
| `version.txt` | Current semver version |
| `CHANGELOG.md` | Release history |
