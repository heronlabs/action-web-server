# Web Server Template — Design

**Date**: 2026-09-14
**Status**: approved, pending implementation
**Scope**: `cloud-iac`, `action-web-server`, `cloud-iac-<tenant>`, webapp monorepos

## Problem

The bucket + CloudFront + Vite CSR architecture works, but nothing that crosses a
layer boundary is written down. IAM permissions, edge cache policy, which env
vars are public, which files get a one-year cache — each is an implicit
convention discovered by breakage.

The acceptance test for this template: **stand up a new webapp by reading the
READMEs alone, without asking anyone.**

Pilot tenant: `sonhandoape`. Rolls out to every webapp afterwards.

## The layer contract

The organising rule:

> Nothing that crosses a layer boundary may be an implicit convention. IAM
> permission, cache policy, public-variable prefix, unhashed file — each has a
> declared owner and is written down in the repo that owns it.

### Layer 1 — `cloud-iac` (engine, tenant-agnostic)

Provisions the bucket + distribution pair and the deploy role. Owns **edge cache
policy** and **security headers**.

Publishes: given a `web-server.yaml`, delivers a bucket, a distribution with
`defaultRootObject` and SPA fallback, DNS pointed at it, and an OIDC role with
least privilege. The granted permissions are exactly what the action consumes.

### Layer 2 — `action-web-server` (publish mechanics)

SSM to `.env`, build, sync with correct cache headers, grace prune, invalidation.
Knows nothing about domains, DNS or tenants.

Publishes: the inputs in `action.yml`, plus two rules that are currently written
nowhere:

- **Minimum IAM policy** — mirrors what the engine grants.
- **Unhashed-file rule** — every file that reaches `dist/` without a content
  hash gets a one-year cache. It must either be imported through `src/` (so Vite
  hashes it) or be listed in `NO_CACHE_PATTERNS`.

Precondition, currently unwritten and silent:

- **One bucket per app.** The action syncs to the bucket root
  (`s3://${BUCKET_NAME}`) and the prune lists the whole bucket. Two apps sharing
  a bucket means one app's prune deletes the other's files.

### Layer 3 — webapps

Build the app, and survive a deploy that lands underneath an open session.

Consumes: **the `VITE_` prefix is the public boundary.** Prefixed variables are
inlined into the served bundle; everything else stays on the runner. This is
independent of the parameter type in SSM.

### Layer 4 — `cloud-iac-<tenant>` (tenant config)

Declares instances. The only layer holding literal values — domain, bucket,
OIDC repository, parameters. `web-server.yaml` + `parameter.yaml` per app, one
block per environment.

## Decisions, with reasoning

Recording the *why* matters more than the *what*: these were all argued, and a
future reader should not have to re-derive them.

### Deletion policy: grace ledger, 7 days

Kept as-is (`PRUNE_GRACE_DAYS` default `'7'`).

The grace period exists to bound how long an orphaned asset stays fetchable. The
liveness set is genuinely unknowable — an old `index.html` can live in a browser
tab indefinitely — so any time-based policy is a heuristic, not a guarantee.

**Why deletion at all, given storage costs cents:** revocation, not tidiness.
Without deletion a published build is irrevocable. A rotated `VITE_*` value, a
pulled feature-flagged screen, an accidentally emitted source map — all stay
publicly fetchable forever. "Eventually revocable" and "never revocable" are
different categories.

**Why the grace cannot be zero**, even with client-side recovery in place:

The distribution uses a custom error response (403/404 → `/index.html`, 200)
with `errorCachingMinTtl: 86400`. Deep-route HTML is cached at the edge per
requested path. The action's step order is sync, prune, then invalidation — and
invalidation is asynchronous.

With immediate deletion, during the propagation window the edge still serves the
old HTML, which references chunks that were just deleted. The client reloads,
hits the same stale edge, gets the same dead references, and the reload guard
stops the loop on a broken page. **The grace period is what makes asynchronous
invalidation safe.**

**Why 7 specifically is judgement, not physics:** the technical floor is set by
invalidation propagation — minutes, with a wide margin at one day. Seven days is
about not interrupting active sessions on every deploy, which costs unsaved
state in `client-app` (forms, wizards) and nothing in `client-website`.

**When to revisit:** once client-side recovery is in production, the
`vite:preloadError` rate in Sentry measures exactly how many users are
interrupted. With that number in hand, 1–2 days is defensible.

### `cloud-iac` releases as major `v2`

**This is a hard requirement, not a precaution.** The engine changes carry real
breaking potential, on three independent fronts:

1. **IAM scoping.** Replacing `s3:*` with an enumerated action list breaks every
   deploy if the enumeration misses something the AWS CLI actually calls. The
   list is a hypothesis until a real deploy proves it.
2. **Distribution behavior.** Dropping the `/index.html` ordered behavior and
   moving every behavior onto a managed cache policy changes how production
   traffic is cached and served. The intent is like-for-like; the blast radius
   if it is not is every page of every tenant.
3. **`parametersName` type.** Verified compatible with both current tenants, but
   it is still a contract change on a consumed interface.

Compounding all three: tenants dispatch with a floating `engine-ref: v1`
(`cloud-iac-<tenant>/.github/workflows/continuous-deployment.yml`). A `v1.x`
release would reach production distributions the next time anyone deploys
anything unrelated, with no deliberate act and no one watching for it.

A major forces the version bump to be typed by hand at the dispatch, which is
the only moment a human is positioned to run `preview` first and read the diff.

Follow the repo's conventional-commit flow (`feat!:`) and let
`action-tag-release-build` cut the tag. **Never edit `version.txt` by hand.**

### Bucket growth

Steady state is `current build + orphans younger than the grace window`. It does
not accumulate feature history. Around 35 MB for a 5 MB bundle at 30 deploys per
week with 20% churn.

The bill for a static site tracks CloudFront egress, which scales with traffic,
not bucket size. Invalidations are effectively free (`/*` counts as one path;
1,000 paths/month are included).

### Rejected: bucket versioning + `--size-only`

Considered as a safety net making the first prune reversible.

Rejected as a pair, because neither pays for itself alone: versioning plus the
sync's current behaviour (fresh CI checkout gives every file a new mtime, so
every deploy re-uploads everything) would create a noncurrent version of every
file on every deploy. `--size-only` fixes that, but is only safe when pass 1
contains exclusively content-hashed files — which is not true today.

Both are cents either way. The real cost is two extra moving parts, and
unbounded version growth contradicts the goal of a small bucket.

**Consequence:** there is no undo. Reading the ledger inside the grace window
becomes a mandatory gate in the adoption procedure, not a recommendation.

### Rejected: CloudFront Function URI rewrite

Considered as a replacement for the 403/404 custom error response. Would give
every SPA route the `/index.html` cache key, making `/*` invalidation
unnecessary and returning real 4xx for missing assets.

Rejected for now: the current setup works, and the change alters routing in
production for every tenant. Revisit if edge-cache warmth after deploys becomes
a measured problem.

### Rejected: `PRUNE_EXCLUDE_PATTERNS`

Considered for bucket objects that legitimately never appear in the build.

Rejected: it would create a second source of truth about what the site is,
competing with the build. The documented resolution is to bring such files into
the build or move them out of the bucket. If a genuine case appears — a file
another system writes into the bucket — the input is justified then, with the
case in hand.

### The `VITE_` prefix is not the security lever

Every currently-prefixed variable genuinely needs to reach the browser;
un-prefixing any of them breaks the app rather than hiding anything. The Sentry
DSN is public by design — it only authorises sending events, and abuse is
mitigated in Sentry (allowed domains, rate limits), not by concealment. The one
real secret, `SENTRY_AUTH_TOKEN`, is already unprefixed and build-time only.

Two actual issues:

1. **`SecureString` on public values.** `VITE_GTM_ID` and
   `VITE_CLARITY_PROJECT_ID` are stored as `SecureString` but land in the public
   bundle. Nothing leaks — both are public by nature — but the type signals a
   secrecy that does not exist. **Rule: `VITE_*` is always `String`. If a value
   needs `SecureString`, it must not be `VITE_*`.**

2. **`define` in `vite.config.ts` bypasses the prefix.** Vite only inlines
   `VITE_*` through `import.meta.env`, but `define` has no such guard.
   `define: {__TOKEN__: JSON.stringify(process.env.SENTRY_AUTH_TOKEN)}` ships the
   token with no prefix involved. This is the real leak vector, and the reason
   for the `LEAK_CHECK` step below.

## Changes by repo

### `cloud-iac` (engine)

| Change | Detail |
|---|---|
| Cache policies | Replace legacy `forwardedValues` + TTLs with `CachingOptimized` on **every** behavior, letting the origin's `Cache-Control` drive freshness: `max-age=31536000,immutable` for hashed assets, `no-cache` for HTML (revalidated at the edge, min TTL 1s). Verify managed policy IDs during implementation. |
| `/index.html` ordered behavior | Currently at `index.ts:76-96` with 0/0/0 TTLs. It is **not load-bearing and should be dropped**: with `defaultRootObject` set, a request for `/` is matched against the *default* behavior — the rewrite to `index.html` happens after behavior selection — so this behavior only catches explicit `/index.html` requests, which is not how anyone reaches the page. Do not replace it with `CachingDisabled`: that forces max TTL 0, which also disables compression. If a dedicated HTML behavior is wanted later it needs a custom policy with min 0 / default 0 / max 1, keeping max ≥ 1 so compression survives. |
| Migration | Swapping `forwardedValues` for `cachePolicyId` is an in-place update in Pulumi, not a replacement, but it is a live config change. The tenant runs `preview` before `up`; the expected diff touches only cache-policy and response-headers fields. Dispatch a `/*` invalidation after `up` — edge entries otherwise keep the old policy until natural expiry. |
| Response headers policy | Define one in the engine — explicit and reviewable — with HSTS, `X-Content-Type-Options: nosniff`, `X-Frame-Options`, `Referrer-Policy`. |
| CSP | Deliberately out of scope. Needs per-app tuning (GTM, Clarity, Sentry, Google Fonts); a generic policy breaks all four. Tracked as a per-app follow-up. |
| `parametersName` | `variables.ts:9` declares `string`; tenant YAML passes an array; `index.ts:172` interpolates it into a template literal. Works by accident for one element, produces an invalid ARN silently for two. Change the type to `string[]`, one ARN per entry. Confirm against how the `parameter` module names paths. **Tenant compatibility verified 2026-09-14:** both `cloud-iac-sonhandoape` and `cloud-iac-heronlabs` (`environments/production/client-website/web-server.yaml:11`) already pass arrays, so the change aligns the declared type with actual usage and breaks no tenant. |
| IAM scope | `s3:*` becomes `ListBucket` on the bucket ARN and `GetObject`/`PutObject`/`DeleteObject` on `bucket/*`. Applies in both places: the role statement and the bucket policy. Verify whether `GetBucketLocation` is required. |
| `priceClass` | `index.ts:94` uses `PriceClass_All`, the most expensive class. Correct for a Brazilian audience; document as a per-tenant decision point. Confirm the region-to-class mapping during implementation rather than asserting it. |

**Version: major `v2`. Non-negotiable.** See the decision below.

### `action-web-server`

| Change | Detail |
|---|---|
| `immutable` | Add the directive to the pass 1 `Cache-Control`. The comment at `core/s3/publish.sh:22` already claims it; the header does not carry it. |
| `LEAK_CHECK` input | Default `'true'`. Between build and publish, scan `dist/` for the values of the build environment's secrets. A match fails the build. Covers the `define` leak vector and anything similar. Named `LEAK_CHECK` rather than `SECRET_SCAN` to avoid collision with GitHub's secret scanning feature. |
| `LEAK_CHECK` scope | **Must not scan every non-`VITE_` parameter** — that produces blocking false positives. `SENTRY_ORG=sonhandoape` and `SENTRY_PROJECT=client-website` will legitimately appear in the bundle as site name and URLs. Scan only parameters typed `SecureString`, and only values at or above a minimum length (16 characters), so short or structurally public values are excluded. |
| `LEAK_CHECK` placement | Runs **inside the action**, between the build step and the publish step, using the values `core/ssm/env.sh` already fetched. The app's own CI never needs SSM access. |
| README | Four new sections: adopting an existing bucket, minimum IAM policy, the unhashed-file rule, one bucket per app. |

**Version**: minor, `v1.1.0`. No default changes for `@v1` consumers except
`LEAK_CHECK`, which defaults to `'true'` and can therefore fail a
currently-green pipeline on a floating `@v1`. That is deliberate: a leaked
secret is worse than a failed deploy, and the failure is loud and actionable.
The escape hatch is setting `LEAK_CHECK: 'false'` on the affected app while it
is fixed — not a quieter default. The `SecureString`-plus-minimum-length scope
above is what keeps this from being a false-positive generator; without it the
default could not honestly be `'true'`.

### `cloud-iac-sonhandoape` (tenant)

- `parametersName` in the new shape.
- `VITE_GTM_ID` and `VITE_CLARITY_PROJECT_ID` from `SecureString` to `String`.
  SSM `PutParameter` cannot change a parameter's type in place, so Pulumi will
  delete and recreate. Both values come from `useEnvironment`, so they are
  recoverable — but the tenant PR should say "expect replace" so the `preview`
  diff is not mistaken for a mistake.
- Dispatch default `tag` to `v2` once the engine is released.

Config-only repo with no build or test, matching how `cloud-iac-heronlabs` is
treated: manual PR, not `/supera:ship`.

### `sonhandoape/webapps` (pilot)

| Change | Detail |
|---|---|
| Client recovery | Package under `packages/`: listen for `vite:preloadError`, record a Sentry breadcrumb, then reload behind the guard defined below. No `__APP_VERSION__` polling as a freshness check — the event covers the failure — but the version **is** used as the guard key. |
| Guard semantics | A bare boolean is wrong: it reloads exactly once per tab, forever, so an unrelated deploy months later finds the guard already set and fails silently. Instead: on `vite:preloadError`, if `sessionStorage` key `__reloaded_for` equals the current `__APP_VERSION__`, do nothing — report to Sentry and let it fail visibly. Otherwise set `__reloaded_for` to `__APP_VERSION__` and `location.reload()`. Clear the key only once the app has actually reached first render, so a boot that crashes before rendering cannot loop. |
| Tests | Vitest in the monorepo, covering: first error reloads; second error at the same version does not; an error at a new version reloads again; a boot that never renders does not clear the key. |
| `NO_CACHE_PATTERNS` | `client-website`: `robots.txt`, `sitemap.xml`, `og-image.png`. `client-app`: the contents of `public/icons/`. |
| `textures/` | Decide per asset: import through `src/` to gain a hash (preferred), or list in `NO_CACHE_PATTERNS`. |

Current unhashed files receiving a one-year cache today:

| App | Files |
|---|---|
| `client-app` | `public/icons/` |
| `client-website` | `public/og-image.png`, `public/robots.txt`, `public/textures/`, emitted `sitemap.xml` |

`sitemap.xml` is emitted by `seoPlugin` in `generateBundle`
(`apps/client-website/src/application/seo/seo-plugin.ts:158`), not from
`public/`, so it is easy to miss.

### `heronlabs/webapps` (rollout)

- Migrate the CD action from the three-action flow
  (`action-ssm-env-build@v4` + `action-s3-publish@v5` with `PRUNE_STALE: 'false'`
  + `action-cloudfront-publish@v6`) to `action-web-server`.
- Same client recovery package and `NO_CACHE_PATTERNS`.
- Its buckets have never been pruned, so the adoption procedure applies in full.

## Procedure: adopting an existing bucket

Goes in the action README. This is the gap that leaves years of orphans
invisible until the first prune.

**Precondition:** one bucket per app (see layer 2).

### Step 1 — stamping deploy

The first deploy with the action creates the ledger and stamps everything absent
from the build. **It deletes nothing** — every timestamp is `now`.

### Step 2 — review the ledger, inside the window (mandatory gate)

> **The ledger is the dry run.** `.s3-publish/stale.tsv` is literally the pending
> deletion list, with dates. No `--dry-run` mode is needed, and the preview lasts
> for the whole grace window.

```bash
aws s3 cp s3://BUCKET_NAME/.s3-publish/stale.tsv - | sort
```

Look for anything that never comes from `dist/`: `.well-known/`, domain
verification files, manual marketing uploads, assets belonging to another app.

With versioning rejected, there is no undo. This step is a gate, not a
recommendation.

### Step 3 — reconcile each survivor

- **Should be served** → bring it into the build (`public/` plus
  `NO_CACHE_PATTERNS`). It leaves the stale set on the next deploy naturally.
- **Does not belong in this bucket** → move it out.

### Step 4 — confirm

Once the grace window expires, the next deploy deletes. Verify with a listing
diff.

### Timing semantics

Worth stating explicitly, because it is the most commonly misread part:

- The clock starts when a file is **first absent from a build**, not when it was
  created.
- Changing `PRUNE_GRACE_DAYS` does not reset the clock; stamps are preserved and
  only the cutoff moves.
- The comparison is strict: deletion needs a deploy **more than** `GRACE` after
  the stamp, not exactly at the boundary.
- The prune only runs during a deploy. An app with no deploys never prunes.

## Sequencing

With the CloudFront Function rejected, there is no invalidation flip, so almost
everything is parallel.

**Wave 1 — independent, can ship together**

- `action-web-server`: `immutable`, `LEAK_CHECK`, README.
- `cloud-iac`: cache policies, response headers, `parametersName`, IAM scope.
- `sonhandoape/webapps`: client recovery package.

**Wave 2 — depends on wave 1**

- `cloud-iac-sonhandoape`: needs engine v2 released and the new
  `parametersName` shape.
- `sonhandoape/webapps`: CD inputs, needs the action released.

**Wave 3 — rollout**

- `heronlabs/webapps`: CD migration plus bucket adoption.
- `cloud-iac-heronlabs`: also consumes the `web-server` module, in both
  production and sandbox. Its dispatch default moves to `v2` and its
  distributions pick up the new policies on the next `up`. Same manual-PR
  treatment as the sonhandoape tenant.

Each repo is one `/supera:ship`, except the tenant config repo, which takes a
manual PR. Wave 1 is three parallel dispatches.

## Out of scope

- Versioned release prefixes (`/releases/<sha>/` with a pointer). The
  correct-by-construction answer — an open tab from three weeks ago keeps
  working, rollback is a pointer swap, the ledger disappears. Revisit only if
  instant rollback becomes a requirement; it moves real complexity into the IaC
  layer.
- CSP.
- OAI to OAC migration.
- CloudFront Function URI rewrite.

## Review triggers

| Signal | Revisit |
|---|---|
| `vite:preloadError` rate in Sentry | `PRUNE_GRACE_DAYS` — a low rate justifies 1–2 days |
| Slow first loads after deploy | The `/*` invalidation and the CloudFront Function decision |
| A file another system writes into the bucket | `PRUNE_EXCLUDE_PATTERNS` |
| Rollback speed becomes a requirement | Versioned release prefixes |
