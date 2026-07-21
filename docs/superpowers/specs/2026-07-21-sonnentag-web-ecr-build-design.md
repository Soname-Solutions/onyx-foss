# Design: SonnenTag web-server image build → AWS ECR

**Date:** 2026-07-21
**Status:** Approved design, pending implementation

## Goal

Provide a custom CI workflow that builds the Onyx **web-server** Docker image and
pushes it to a private **AWS ECR** repository in the SonnenTag AWS account.

`onyx-foss` is a fork of `onyx-dot-app/onyx` that syncs upstream via `sync_foss.yml`.
Upstream already builds this image in `.github/workflows/deployment.yml` (jobs
`build-web-amd64`, `build-web-arm64`, `merge-web`), but that pipeline is wired to
Onyx's own infrastructure and cannot run in this fork unchanged (see "Why not reuse
deployment.yml"). This design is a **minimal, self-contained derivative** of those
jobs, retargeted at our AWS account.

## Naming convention

Per project rule, every custom (non-upstream) artifact carries `sonnentag` in its
filename so it is instantly distinguishable from synced upstream files and never
clobbered by a sync. This applies to filenames only; the YAML `name:` field and job
ids remain free-form.

## Base image decision: keep DHI

The upstream `web/Dockerfile` builds `FROM dhi.io/node:24-debian13[-dev]` (Docker
Hardened Images). As of **2025-12-17** the full DHI catalog is **free** and Apache-2.0
licensed — no paid subscription. Pulling still requires authentication (a free Docker
Hub account + Personal Access Token) and a `docker login dhi.io` step.

We therefore **keep the hardened base and do not fork the Dockerfile.** The workflow
builds the untouched upstream `web/Dockerfile` and adds the required Docker logins.
This keeps the hardened/near-distroless, non-root runtime image and leaves nothing to
keep in sync with upstream.

## Deliverable (one new file)

### `.github/workflows/sonnentag-build-web-ecr.yml`

Single job on a GitHub-hosted runner. Structure:

```yaml
name: Build Web Server → ECR (SonnenTag)

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: "Tag to apply to the image in ECR"
        required: true
        default: latest

permissions:
  contents: read      # checkout
  id-token: write     # OIDC → AWS

jobs:
  build-web-ecr:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - Checkout (persist-credentials: false)

      - Configure AWS credentials        # role-to-assume: secrets.AWS_OIDC_ROLE_ARN
                                          # aws-region:     vars.AWS_REGION

      - Compute ECR repository name:      # ecr-sonnentag-onyx-web-server-<env>
          # DEPLOY_ENV via env->$GITHUB_ENV (default "dev"); no shell interpolation
          echo "ECR_REPOSITORY=ecr-sonnentag-onyx-web-server-${DEPLOY_ENV}" >> "$GITHUB_ENV"

      - Ensure ECR repository exists:     # describe-or-create
          aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" \
            || aws ecr create-repository --repository-name "$ECR_REPOSITORY"

      - Login to Amazon ECR              # id: login-ecr → outputs.registry

      - Set up Docker Buildx

      - Login to Docker Hub (docker.io)  # secrets.DOCKERHUB_USERNAME / DOCKERHUB_TOKEN
                                          # authenticates the oven/bun + any docker.io pulls

      - Login to Docker Hardened Images (dhi.io)   # same DOCKERHUB_* credentials
                                                    # authenticates the dhi.io/node base pulls

      - Build and push:
          context:   ./web
          file:      ./web/Dockerfile          # upstream, untouched
          platforms: linux/amd64
          push:      true
          tags:      ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ inputs.image_tag }}
          build-args:
            ONYX_VERSION=${{ inputs.image_tag }}
            NODE_OPTIONS=--max-old-space-size=8192
```

Both `docker login` steps mirror what upstream's web jobs already do (Docker Hub +
dhi.io, same credentials). All actions are SHA-pinned per repo convention (zizmor),
reusing the exact pins already present in `deployment.yml` where they exist
(`actions/checkout`, `aws-actions/configure-aws-credentials`,
`docker/setup-buildx-action`, `docker/build-push-action`, `docker/login-action`);
`aws-actions/amazon-ecr-login` is pinned to its current `v2` release SHA.

## Required GitHub repo configuration (one-time, by the user)

- **Secret** `AWS_OIDC_ROLE_ARN` — set to the pre-created role
  `arn:aws:iam::405389362913:role/role-sonnentag-github-actions-all`, assumable by
  this repo via GitHub OIDC. IAM permissions the role needs:
  - `ecr:GetAuthorizationToken`
  - `ecr:DescribeRepositories`, `ecr:CreateRepository`   *(for the ensure-exists step)*
  - `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`,
    `ecr:CompleteLayerUpload`, `ecr:PutImage`             *(for push)*
  - The role's trust policy must allow `repo:Soname-Solutions/onyx-foss:*`.
- **Secrets** `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` — a **free** Docker Hub account
  and a Personal Access Token, used for both the Docker Hub and dhi.io logins.
  - The account may need to accept the DHI terms once at
    `hub.docker.com/hardened-images/catalog` before its first `dhi.io` pull.
- **Variable** `AWS_REGION` — e.g. `eu-central-1` (required).
- **Variable** `DEPLOY_ENV` — e.g. `dev` / `staging` / `prod` (optional, defaults to
  `dev`). Only the env segment of the ECR repo name is configurable.

### ECR repository naming

The repo name is **derived in-workflow**, not supplied as a raw variable, following
the project convention `ecr-{project}-{meaning}-{env}`:

- `project` = `sonnentag` (constant)
- `meaning` = `onyx-web-server` (i.e. `onyx-{container}`; constant for this workflow)
- `env` = `${{ vars.DEPLOY_ENV || 'dev' }}`

Default full name: **`ecr-sonnentag-onyx-web-server-dev`**. The name is computed into
`$GITHUB_ENV` in an early step so no `${{ }}` value is interpolated into a shell body.
The workflow creates the ECR repository on first run if it does not already exist.

## Trigger

`workflow_dispatch` only (manual, with an `image_tag` input). Nothing fires
automatically — deliberate, because a fork that syncs upstream tags would otherwise
build on every synced tag. Automatic triggers can be added later if wanted.

## Scope: single-arch, ECR only

- **linux/amd64 only** — one build job, no ARM64 job, no manifest merge.
- **ECR only** — no Docker Hub *push*, no ECR pull-through *cache*. (Docker Hub /
  dhi.io logins are for *pulling* base images only.)

## Why not reuse deployment.yml

The upstream web jobs depend on Onyx-account infrastructure at several points, each of
which is dropped or replaced here:

| Upstream dependency                                             | Handling here                          |
| -------------------------------------------------------------- | -------------------------------------- |
| RunsOn self-hosted runners (`runs-on`, `extras=ecr-cache`)     | replaced with `ubuntu-latest`          |
| Docker Hub **push** to `onyxdotapp/onyx-web-server`            | dropped (ECR only)                     |
| Docker/dhi.io creds read from Onyx AWS Secrets Manager         | replaced with our own `DOCKERHUB_*` GitHub secrets |
| `audit-gate` / `image-audit` gates running `ods audit`         | dropped                                |
| ARM64 build + `docker buildx imagetools` manifest merge        | dropped (amd64 only)                   |

Kept from upstream: the DHI base image and the Docker Hub + dhi.io login steps.
Also dropped: Slack notifications, `is-test-run`/`is-cloud`/semver tag matrix.

## Success criteria

1. Manually dispatching the workflow with `image_tag=<x>` builds the upstream
   `web/Dockerfile` (DHI base, authenticated) and pushes
   `<registry>/ecr-sonnentag-onyx-web-server-<DEPLOY_ENV>:<x>` to ECR, creating the
   repo if absent.
2. No upstream-tracked file is modified — `web/Dockerfile` and `deployment.yml` remain
   byte-identical to upstream, so `sync_foss` never conflicts.
