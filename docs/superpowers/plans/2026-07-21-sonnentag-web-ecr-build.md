# SonnenTag Web-Server → ECR Build Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manually-dispatched GitHub Actions workflow that builds the Onyx web-server image from the untouched upstream `web/Dockerfile` and pushes it to an AWS ECR repository.

**Architecture:** A single self-contained workflow file with one job on `ubuntu-latest`. It authenticates to AWS via GitHub OIDC, ensures the ECR repo exists, logs in to Docker Hub + dhi.io (to pull the hardened Node base), builds `linux/amd64` via buildx, and pushes to ECR. No upstream-tracked file is modified.

**Tech Stack:** GitHub Actions, Docker Buildx, AWS ECR, AWS OIDC, Docker Hardened Images (dhi.io).

**Spec:** [docs/superpowers/specs/2026-07-21-sonnentag-web-ecr-build-design.md](../specs/2026-07-21-sonnentag-web-ecr-build-design.md)

## Global Constraints

- **Naming rule:** every custom (non-upstream) artifact filename must contain `sonnentag`. The workflow file is `.github/workflows/sonnentag-build-web-ecr.yml`.
- **ECR repo naming:** `ecr-{project}-{meaning}-{env}` → project `sonnentag`, meaning `onyx-web-server` (both hardcoded in this workflow), env from `${{ vars.DEPLOY_ENV || 'dev' }}`. Default full name: `ecr-sonnentag-onyx-web-server-dev`. The name is derived in-workflow, not taken as a raw variable.
- **Do not modify any upstream-tracked file.** `web/Dockerfile` and `.github/workflows/deployment.yml` must remain byte-identical to upstream (verified in Task 1, Step 3).
- **Pin every action by commit SHA** with a `# ratchet:` comment, per repo/zizmor convention. Use exactly these pins (reused from `deployment.yml` where present):
  - `actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # ratchet:actions/checkout@v6`
  - `aws-actions/configure-aws-credentials@e7f100cf4c008499ea8adda475de1042d6975c7b # ratchet:aws-actions/configure-aws-credentials@v6.2.0`
  - `aws-actions/amazon-ecr-login@d539f0932e70871a027e9d5a9d8fc38589180a64 # ratchet:aws-actions/amazon-ecr-login@v2.1.6`
  - `docker/setup-buildx-action@d7f5e7f509e45cec5c76c4d5afdd7de93d0b3df5 # ratchet:docker/setup-buildx-action@v4`
  - `docker/login-action@c99871dec2022cc055c062a10cc1a1310835ceb4 # ratchet:docker/login-action@v4.3.0`
  - `docker/build-push-action@f9f3042f7e2789586610d6e8b85c8f03e5195baf # ratchet:docker/build-push-action@v6`
- **Trigger:** `workflow_dispatch` only.
- **Scope:** `linux/amd64` only; push to ECR only (Docker Hub / dhi.io logins are for *pulling* base images).
- **No template injection:** never interpolate `${{ inputs.* }}` / `${{ vars.* }}` directly into a `run:` shell body. Pass them through `env:` or through an action's `with:` inputs only.

## One-time GitHub configuration (user-owned prerequisite, NOT a code task)

These must exist in repo Settings before Task 2's dispatch will succeed. They are not created by this plan:

- **Secret** `AWS_OIDC_ROLE_ARN` — set to `arn:aws:iam::405389362913:role/role-sonnentag-github-actions-all` (pre-created). Must be assumable via OIDC by `repo:Soname-Solutions/onyx-foss:*` and hold ECR permissions: `ecr:GetAuthorizationToken`, `ecr:DescribeRepositories`, `ecr:CreateRepository`, `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`.
- **Secrets** `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` — a free Docker Hub account + PAT (also used for dhi.io). The account may need to accept DHI terms once at `hub.docker.com/hardened-images/catalog`.
- **Variable** `AWS_REGION` (e.g. `eu-central-1`) — required.
- **Variable** `DEPLOY_ENV` (e.g. `dev`, `staging`, `prod`) — optional; defaults to `dev` when unset. Feeds the ECR repo name `ecr-sonnentag-onyx-web-server-<DEPLOY_ENV>`. No `ECR_REPOSITORY` variable is used — the name is derived.

---

## File Structure

- Create: `.github/workflows/sonnentag-build-web-ecr.yml` — the entire deliverable.

There is one file and one responsibility, so the plan is one implementation task (Task 1) plus one live integration-verification task (Task 2).

---

### Task 1: Create the build-and-push workflow

**Files:**
- Create: `.github/workflows/sonnentag-build-web-ecr.yml`

**Interfaces:**
- Consumes: repo secrets `AWS_OIDC_ROLE_ARN`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`; repo vars `AWS_REGION` (required), `DEPLOY_ENV` (optional, default `dev`); upstream file `./web/Dockerfile` (build context `./web`).
- Produces: an image pushed to `<ecr-registry>/ecr-sonnentag-onyx-web-server-<DEPLOY_ENV>:<image_tag>`. No other task depends on internal names here.

- [ ] **Step 1: Write the workflow file**

Create `.github/workflows/sonnentag-build-web-ecr.yml` with exactly this content:

```yaml
name: Build Web Server to ECR (SonnenTag)

# Custom (non-upstream) workflow. Builds the Onyx web-server image from the
# untouched upstream web/Dockerfile and pushes it to our private AWS ECR repo.
# Manual dispatch only.
# Spec: docs/superpowers/specs/2026-07-21-sonnentag-web-ecr-build-design.md

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: "Tag to apply to the image in ECR"
        required: true
        default: latest

# Restrictive defaults; id-token needed for AWS OIDC federation.
permissions:
  contents: read
  id-token: write

jobs:
  build-web-ecr:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # ratchet:actions/checkout@v6
        with:
          persist-credentials: false

      # ECR repo name convention: ecr-{project}-{meaning}-{env}.
      # project=sonnentag, meaning=onyx-web-server (both fixed for this workflow);
      # env from DEPLOY_ENV, default "dev". Built via env->$GITHUB_ENV so no ${{ }}
      # is interpolated into the shell (no template injection).
      - name: Compute ECR repository name
        env:
          DEPLOY_ENV: ${{ vars.DEPLOY_ENV || 'dev' }}
        run: |
          echo "ECR_REPOSITORY=ecr-sonnentag-onyx-web-server-${DEPLOY_ENV}" >> "$GITHUB_ENV"

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@e7f100cf4c008499ea8adda475de1042d6975c7b # ratchet:aws-actions/configure-aws-credentials@v6.2.0
        with:
          role-to-assume: ${{ secrets.AWS_OIDC_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      # Idempotent: create the ECR repo on first run, no-op thereafter.
      # $ECR_REPOSITORY comes from job env (not direct interpolation) to avoid
      # shell template injection.
      - name: Ensure ECR repository exists
        run: |
          aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" >/dev/null 2>&1 \
            || aws ecr create-repository --repository-name "$ECR_REPOSITORY" >/dev/null

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@d539f0932e70871a027e9d5a9d8fc38589180a64 # ratchet:aws-actions/amazon-ecr-login@v2.1.6

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@d7f5e7f509e45cec5c76c4d5afdd7de93d0b3df5 # ratchet:docker/setup-buildx-action@v4

      # Authenticate Docker Hub so anonymous-pull rate limits don't bite the
      # oven/bun base pull inside web/Dockerfile.
      - name: Login to Docker Hub
        uses: docker/login-action@c99871dec2022cc055c062a10cc1a1310835ceb4 # ratchet:docker/login-action@v4.3.0
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      # web/Dockerfile pulls its hardened Node base from dhi.io, which (though free)
      # still requires authentication with the same Docker account credentials.
      - name: Login to Docker Hardened Images (dhi.io)
        uses: docker/login-action@c99871dec2022cc055c062a10cc1a1310835ceb4 # ratchet:docker/login-action@v4.3.0
        with:
          registry: dhi.io
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push to ECR
        uses: docker/build-push-action@f9f3042f7e2789586610d6e8b85c8f03e5195baf # ratchet:docker/build-push-action@v6
        with:
          context: ./web
          file: ./web/Dockerfile
          platforms: linux/amd64
          push: true
          tags: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ inputs.image_tag }}
          build-args: |
            ONYX_VERSION=${{ inputs.image_tag }}
            NODE_OPTIONS=--max-old-space-size=8192
```

- [ ] **Step 2: Validate the YAML parses**

Run:
```bash
cd c:/1a_Projects_Current/202606_SonnenTag/onyx-foss && \
python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/sonnentag-build-web-ecr.yml')); print('YAML OK')"
```
Expected: prints `YAML OK` with exit code 0.

- [ ] **Step 3: Confirm no upstream-tracked file was touched**

Run:
```bash
cd c:/1a_Projects_Current/202606_SonnenTag/onyx-foss && \
git status --porcelain web/Dockerfile .github/workflows/deployment.yml
```
Expected: **empty output** (neither file modified). If either appears, revert it — only the new workflow file may be added.

- [ ] **Step 4: (Optional) Lint with actionlint if available**

Run:
```bash
command -v actionlint >/dev/null 2>&1 && actionlint .github/workflows/sonnentag-build-web-ecr.yml || echo "actionlint not installed — skipping"
```
Expected: either `actionlint` reports no errors, or the skip message. (Not a gate — the repo runs zizmor/actionlint in CI; local absence is fine.)

- [ ] **Step 5: Commit**

```bash
cd c:/1a_Projects_Current/202606_SonnenTag/onyx-foss && \
git add .github/workflows/sonnentag-build-web-ecr.yml docs/superpowers/ && \
git commit -m "ci(sonnentag): add web-server build + push to AWS ECR workflow

Custom manual-dispatch workflow that builds the upstream web/Dockerfile
and pushes linux/amd64 to AWS ECR via OIDC. Keeps the DHI base (free,
login-only). No upstream-tracked file modified.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
Expected: one commit created; `git status` clean afterward.

---

### Task 2: Live integration verification (requires the one-time GitHub config)

This is the real functional test — a YAML file cannot be unit-tested for build correctness. It runs the workflow end-to-end against AWS. It depends on the one-time GitHub configuration (secrets + vars) being in place; if the user hasn't set those yet, stop and report that Task 1 is complete and Task 2 is blocked on configuration.

**Files:** none (verification only).

**Interfaces:**
- Consumes: the pushed branch `feat/sonnentag-web-ecr-build`, configured secrets/vars.
- Produces: a verified image in ECR.

- [ ] **Step 1: Push the branch**

```bash
cd c:/1a_Projects_Current/202606_SonnenTag/onyx-foss && \
git push -u origin feat/sonnentag-web-ecr-build
```
Expected: branch pushed. (`workflow_dispatch` workflows are dispatchable once the file exists on a pushed branch / after merge, per repo settings.)

- [ ] **Step 2: Dispatch the workflow**

```bash
gh workflow run sonnentag-build-web-ecr.yml --ref feat/sonnentag-web-ecr-build -f image_tag=ecr-smoke-test
```
Expected: `✓ Created workflow_dispatch event`. (If GitHub reports the workflow isn't found on the branch, the branch/default-branch dispatch rules require it on the default branch first — note this and defer to post-merge.)

- [ ] **Step 3: Watch the run to completion**

```bash
gh run list --workflow=sonnentag-build-web-ecr.yml --limit 1
# then, using the run id from above:
gh run watch <run-id> --exit-status
```
Expected: run concludes with `completed success`. If it fails at "Login to Docker Hardened Images", the Docker account likely hasn't accepted DHI terms (see one-time config). If it fails at "Ensure ECR repository exists" or push, the IAM role is missing an ECR permission.

- [ ] **Step 4: Confirm the image landed in ECR**

```bash
# Repo name is derived: ecr-sonnentag-onyx-web-server-<DEPLOY_ENV> (default dev).
aws ecr describe-images \
  --repository-name "ecr-sonnentag-onyx-web-server-dev" \
  --image-ids imageTag=ecr-smoke-test \
  --region "$AWS_REGION"
```
Expected: JSON describing one image with tag `ecr-smoke-test` and a recent `imagePushedAt`. (Set `AWS_REGION` in the shell; substitute the real `DEPLOY_ENV` in the repo name if it isn't `dev`.)

- [ ] **Step 5: Report result**

Report to the user: run URL, success/failure, and that the smoke-test tag can be deleted. Do not delete anything automatically.

---

## Self-Review

**Spec coverage:**
- Single deliverable workflow file — Task 1. ✓
- Untouched upstream `web/Dockerfile` (`file: ./web/Dockerfile`) — Task 1 Step 1 + guard Step 3. ✓
- DHI base kept + Docker Hub/dhi.io logins — Task 1 login steps. ✓
- OIDC auth, ensure-repo-exists, ECR push, `linux/amd64`, `workflow_dispatch` w/ `image_tag` — Task 1. ✓
- ECR name derived per `ecr-{project}-{meaning}-{env}` (env from `DEPLOY_ENV`, default `dev`) — Task 1 "Compute ECR repository name" step. ✓
- SHA-pinned actions, `sonnentag` filename, no template injection (`DEPLOY_ENV` via env→`$GITHUB_ENV`) — Global Constraints + Task 1. ✓
- Required one-time config (role ARN `role-sonnentag-github-actions-all` w/ ECR+CreateRepository perms, DOCKERHUB_* secrets, `AWS_REGION` var, optional `DEPLOY_ENV` var) — documented as prerequisite; exercised by Task 2. ✓
- Success criteria (dispatch builds & pushes; no sync conflicts) — Task 2 verification + Task 1 Step 3. ✓

**Placeholder scan:** none — full YAML content and exact commands provided. `<run-id>` in Task 2 Step 3 is a runtime value, not a plan placeholder.

**Type consistency:** step id `login-ecr` defined and referenced as `steps.login-ecr.outputs.registry`; `ECR_REPOSITORY` written to `$GITHUB_ENV` in the compute step (before the ensure-repo step that uses it) and read as `$ECR_REPOSITORY` in `run:` bodies and `${{ env.ECR_REPOSITORY }}` in the image tag — consistent, and defined before first use. ✓
