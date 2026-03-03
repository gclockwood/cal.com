# fly.io Production Deployment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy the cal.com fork to fly.io via a GitHub Actions pipeline that builds a Docker image on GitHub Runners, pushes to GHCR, and deploys the pre-built image to fly.io on every push to the `prod` branch.

**Architecture:** GitHub Actions builds the image and pushes it to GHCR tagged with the Git SHA, then `flyctl deploy --image` pulls that exact tag to fly.io. fly.io's `release_command` runs `prisma migrate deploy` before traffic shifts (a safety gate — `start.sh` also runs it on startup, which is harmless and idempotent). Postgres and Redis run on fly.io's private network in `ewr`.

**Tech Stack:** fly.io (flyctl), GitHub Actions, GHCR (ghcr.io), Docker Buildx, Prisma, Upstash Redis

**Design doc:** `docs/plans/2026-03-02-fly-deploy-design.md`

---

## Prerequisites

Before starting, confirm you have:
- `flyctl` installed locally (`brew install flyctl` or https://fly.io/docs/hands-on/install-flyctl/)
- Logged in to fly.io (`fly auth login`)
- Admin access to the GitHub repo (to create environments and secrets)
- The repo checked out on the `dev` branch (current state)

---

## Task 1: Create the `prod` branch

**Files:**
- No file changes — branch creation only

**Step 1: Create and push the prod branch from current HEAD**

```bash
git checkout dev
git checkout -b prod
git push origin prod
```

Expected: GitHub now has a `prod` branch at the same commit as `dev`.

**Step 2: Switch back to dev for file editing**

```bash
git checkout dev
```

> All file changes in Tasks 2–3 are made on `dev`. The `prod` branch is the deploy target — you'll merge `dev` → `prod` when ready to deploy. This keeps history clean.

---

## Task 2: Create `fly.toml`

**Files:**
- Create: `fly.toml` (repo root)

**Step 1: Create the file**

```toml
app = "cal-com-halftide"
primary_region = "ewr"

[build]
  image = "ghcr.io/gclockwood/cal.com:latest"

[deploy]
  release_command = "npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma"

[env]
  PORT = "3000"
  NODE_ENV = "production"
  NEXT_PUBLIC_WEBAPP_URL = "https://cal-com-halftide.fly.dev"

[http_service]
  internal_port = 3000
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1

[[vm]]
  memory = "2gb"
  cpu_kind = "shared"
  cpus = 2
```

> **Note on `release_command`:** fly.io runs this in a temporary container (with all fly secrets injected, including `DATABASE_URL`) before routing any traffic to the new containers. If it exits non-zero, the deploy is aborted and the old container keeps serving. `start.sh` also runs `prisma migrate deploy` on startup — running it twice is safe because Prisma skips already-applied migrations.

> **Note on `NEXT_PUBLIC_WEBAPP_URL` in `[env]`:** This is a public value so it can live unencrypted in fly.toml. The `start.sh` entrypoint calls `scripts/replace-placeholder.sh` to swap out the build-time value with this runtime value if they differ — keeping it here ensures the running container always uses the correct URL.

**Step 2: Validate the TOML syntax**

```bash
flyctl config validate
```

Expected output: `✓ Configuration is valid` (or similar). If flyctl isn't installed, open `fly.toml` in an editor and visually verify indentation — TOML is whitespace-sensitive.

**Step 3: Commit**

```bash
git add fly.toml
git commit -m "feat: add fly.toml for cal-com-halftide"
```

---

## Task 3: Create the GitHub Actions deploy workflow

**Files:**
- Create: `.github/workflows/deploy-prod.yml`

**Step 1: Create the workflow file**

```yaml
name: Deploy to fly.io (prod)

on:
  push:
    branches:
      - prod

jobs:
  build:
    name: Build & push image
    runs-on: ubuntu-latest
    environment: production
    permissions:
      contents: read
      packages: write
    outputs:
      sha: ${{ steps.sha.outputs.short }}
    steps:
      - uses: actions/checkout@v4

      - name: Get short SHA
        id: sha
        run: echo "short=$(git rev-parse --short HEAD)" >> $GITHUB_OUTPUT

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          platforms: linux/amd64
          tags: |
            ghcr.io/${{ github.repository_owner }}/cal.com:${{ steps.sha.outputs.short }}
            ghcr.io/${{ github.repository_owner }}/cal.com:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
          build-args: |
            NEXT_PUBLIC_WEBAPP_URL=${{ vars.NEXT_PUBLIC_WEBAPP_URL }}
            NEXT_PUBLIC_API_V2_URL=${{ vars.NEXT_PUBLIC_API_V2_URL }}
            CALCOM_TELEMETRY_DISABLED=1
            NEXTAUTH_SECRET=${{ secrets.NEXTAUTH_SECRET }}
            CALENDSO_ENCRYPTION_KEY=${{ secrets.CALENDSO_ENCRYPTION_KEY }}
            DATABASE_URL=${{ secrets.BUILD_DATABASE_URL }}
            ORGANIZATIONS_ENABLED=${{ vars.ORGANIZATIONS_ENABLED }}
            NEXT_PUBLIC_SINGLE_ORG_SLUG=${{ vars.NEXT_PUBLIC_SINGLE_ORG_SLUG }}

  deploy:
    name: Deploy to fly.io
    needs: build
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4

      - uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Deploy
        run: |
          flyctl deploy \
            --app cal-com-halftide \
            --image ghcr.io/${{ github.repository_owner }}/cal.com:${{ needs.build.outputs.sha }} \
            --strategy rolling
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

> **`environment: production` on both jobs:** Both the build and deploy jobs reference the `production` environment. This means GitHub will gate both on the branch restriction you configure in Task 4 — secrets are only available when running from the `prod` branch.

> **`BUILD_DATABASE_URL`:** Prisma needs a database URL at build time to generate TypeScript types. It does not actually connect to the database during the build. You can use a dummy URL here (`postgresql://user:pass@localhost/db`) or your real DATABASE_URL — either works. If using a dummy URL, make sure it's a valid Postgres URL format or Prisma will error.

> **GitHub Actions layer cache (`type=gha`):** Caches Docker layers in GitHub's cache store. Subsequent builds are significantly faster when only app code changes (node_modules layer is reused). The first build after setting this up will be slow — that's expected.

**Step 2: Validate the YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy-prod.yml'))" && echo "YAML valid"
```

Expected: `YAML valid`

**Step 3: Commit**

```bash
git add .github/workflows/deploy-prod.yml
git commit -m "feat: add GitHub Actions deploy workflow for fly.io prod"
```

---

## Task 4: Configure GitHub repository — production environment

This is a manual step in the GitHub web UI. No code changes.

**Step 1: Create the production environment**

1. Go to your repo on GitHub → **Settings** → **Environments** → **New environment**
2. Name it exactly: `production`
3. Click **Configure environment**

**Step 2: Add branch protection**

Under **Deployment branches and tags**, click **Add deployment branch or tag rule**:
- Rule type: **Branch**
- Branch name pattern: `prod`

This ensures secrets in this environment are only accessible when the workflow runs on the `prod` branch.

**Step 3: Add environment secrets**

Under **Environment secrets**, add each of these:

| Secret name | Value |
|---|---|
| `FLY_API_TOKEN` | Get from: `fly tokens create deploy -x 999999h` (long-lived deploy token) |
| `NEXTAUTH_SECRET` | Generate: `openssl rand -base64 32` |
| `CALENDSO_ENCRYPTION_KEY` | Generate: `openssl rand -base64 24` (must be exactly 32 chars after base64 decode — 24 random bytes = 32 base64 chars) |
| `BUILD_DATABASE_URL` | Use `postgresql://user:pass@localhost/db` as a safe dummy, OR your real fly.io Postgres URL after Task 5 |

**Step 4: Add environment variables** (non-sensitive, visible in logs)

Under **Environment variables**, add:

| Variable name | Value |
|---|---|
| `NEXT_PUBLIC_WEBAPP_URL` | `https://cal-com-halftide.fly.dev` |
| `NEXT_PUBLIC_API_V2_URL` | `https://cal-com-halftide.fly.dev/api/v2` |
| `ORGANIZATIONS_ENABLED` | `false` |
| `NEXT_PUBLIC_SINGLE_ORG_SLUG` | (leave empty unless you're using single-org mode) |

> **Generate `FLY_API_TOKEN` locally:**
> ```bash
> fly tokens create deploy -x 999999h
> ```
> Copy the output token and paste it into the GitHub secret.

---

## Task 5: Provision fly.io infrastructure (one-time)

These are `flyctl` commands run locally. They provision the fly.io app, Postgres cluster, and Redis. Run them in order.

> **Important:** These are one-time setup steps. Running them again will error (resources already exist) — that's fine.

**Step 1: Create the fly app (registers the name, no deploy)**

```bash
fly apps create cal-com-halftide --machines
```

Expected: `New app created: cal-com-halftide`

**Step 2: Create the Postgres cluster**

```bash
fly pg create \
  --name cal-com-halftide-db \
  --region ewr \
  --vm-size shared-cpu-1x \
  --volume-size 10 \
  --initial-cluster-size 1
```

Expected: Prompts for org (select yours), then provisions a single-node Postgres VM. Takes ~2 minutes. At the end it prints credentials — **save these somewhere safe**, though you won't need them directly (the attach step sets everything up).

> `shared-cpu-1x` with 1GB RAM is the cheapest option (~$2–3/mo). `--volume-size 10` gives 10GB of disk. `--initial-cluster-size 1` creates a single node (no HA replica). Sufficient for personal/small-team use.

**Step 3: Attach Postgres to the app**

```bash
fly pg attach cal-com-halftide-db --app cal-com-halftide
```

Expected: fly.io sets `DATABASE_URL` as a secret on `cal-com-halftide` automatically. It prints the connection string.

**Step 4: Set `DATABASE_DIRECT_URL`**

Cal.com requires both `DATABASE_URL` (for pooled connections) and `DATABASE_DIRECT_URL` (for migrations — direct, non-pooled). With fly.io Postgres both point to the same address.

First, retrieve the `DATABASE_URL` that was just set:

```bash
fly secrets list --app cal-com-halftide
```

Then set `DATABASE_DIRECT_URL` to the same value:

```bash
fly secrets set DATABASE_DIRECT_URL="<same-url-as-DATABASE_URL>" --app cal-com-halftide
```

**Step 5: Create Upstash Redis via fly.io extension**

```bash
fly ext upstash redis create \
  --name cal-com-halftide-redis \
  --region ewr
```

Expected: Creates a Redis instance and prints a `REDIS_URL`. Copy it.

**Step 6: Set remaining app secrets**

Replace the placeholder values with your actual generated secrets (use the same `NEXTAUTH_SECRET` and `CALENDSO_ENCRYPTION_KEY` you put in GitHub — they must match):

```bash
fly secrets set \
  REDIS_URL="<upstash-redis-url-from-step-5>" \
  NEXTAUTH_SECRET="<same-value-as-github-secret>" \
  NEXTAUTH_URL="https://cal-com-halftide.fly.dev" \
  CALENDSO_ENCRYPTION_KEY="<same-value-as-github-secret>" \
  --app cal-com-halftide
```

Expected: `Secrets are staged for the first deployment`

**Step 7: Verify all secrets are set**

```bash
fly secrets list --app cal-com-halftide
```

Expected: You should see at minimum: `DATABASE_URL`, `DATABASE_DIRECT_URL`, `REDIS_URL`, `NEXTAUTH_SECRET`, `NEXTAUTH_URL`, `CALENDSO_ENCRYPTION_KEY`

**Step 8: (Optional) Update `BUILD_DATABASE_URL` in GitHub**

Now that you have a real `DATABASE_URL`, you can optionally update the `BUILD_DATABASE_URL` GitHub secret to use it (replacing the dummy URL from Task 4). The real URL makes Prisma's build-time type generation more accurate.

---

## Task 6: Trigger the first deploy

**Step 1: Merge dev into prod and push**

```bash
git checkout prod
git merge dev --no-edit
git push origin prod
```

Expected: GitHub Actions picks up the push to `prod` and starts the `Deploy to fly.io (prod)` workflow.

**Step 2: Monitor the build job**

Go to **GitHub → Actions → Deploy to fly.io (prod)** → click the running workflow.

The `build` job will:
1. Check out the code
2. Log in to GHCR
3. Build the Docker image (first build takes 15–30 minutes — Cal.com is a large monorepo)
4. Push to `ghcr.io/gclockwood/cal.com:<sha>` and `:latest`

If the build fails:
- Check the step logs for the specific error
- Common issues: missing build ARG (check GitHub secrets/variables are all set), Docker build memory errors (GitHub free runners have 7GB RAM — the Cal.com build needs most of it)

**Step 3: Monitor the deploy job**

After build succeeds, the `deploy` job runs `flyctl deploy --image ...`.

fly.io will:
1. Start a release container and run `prisma migrate deploy` (release_command)
2. If migration succeeds, start the new VM with the new image
3. Health check the new VM (hits `localhost:3000`)
4. Stop the old VM once health check passes

Watch logs in real time:
```bash
fly logs --app cal-com-halftide
```

**Step 4: Verify the app is running**

```bash
fly status --app cal-com-halftide
```

Expected: One machine in `started` state.

Open in browser:
```
https://cal-com-halftide.fly.dev
```

Expected: Cal.com login page loads.

**Step 5: Check the database seeding**

`start.sh` calls `scripts/seed-app-store.ts` on every startup. Verify the seed ran without errors:

```bash
fly logs --app cal-com-halftide | grep -i seed
```

---

## Task 7: Ongoing deploy workflow

For all future deploys:

```bash
# On dev branch: make changes, commit
git checkout dev
# ... make your changes ...
git commit -m "feat: your change"

# Deploy: merge to prod and push
git checkout prod
git merge dev --no-edit
git push origin prod
# GitHub Actions takes it from here
```

To watch a deploy in progress:
```bash
fly logs --app cal-com-halftide
```

To roll back to a previous image (find SHA from GitHub Actions history):
```bash
fly deploy \
  --app cal-com-halftide \
  --image ghcr.io/gclockwood/cal.com:<previous-sha> \
  --strategy rolling
```

---

## Troubleshooting

**Build fails: `No space left on device`**
GitHub free runners have limited disk. The Cal.com Docker build is large. Try adding `--no-cache` removal steps or splitting the build into a self-hosted runner if this recurs.

**Deploy fails: `release_command` non-zero exit**
The Prisma migration failed. SSH into the app to investigate:
```bash
fly ssh console --app cal-com-halftide
npx prisma migrate status --schema /calcom/packages/prisma/schema.prisma
```

**App starts but crashes immediately**
Check logs:
```bash
fly logs --app cal-com-halftide
```
Most common cause: a missing secret (e.g. `NEXTAUTH_SECRET` or `DATABASE_URL` not set).

**GHCR image is private — fly.io can't pull it**
By default, GHCR packages are private. After the first push, go to **GitHub → Packages → cal.com** → **Package settings** → change visibility to **Public**, or configure fly.io to authenticate with a GitHub PAT.

To make the package public (easiest for a personal fork):
1. Go to `https://github.com/gclockwood?tab=packages`
2. Find the `cal.com` package → Settings → Change visibility → Public
