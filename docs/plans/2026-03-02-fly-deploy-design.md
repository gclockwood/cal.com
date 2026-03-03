# fly.io Production Deployment Design

**Date:** 2026-03-02
**App:** cal-com-halftide
**Region:** ewr (Newark, NJ)

## Overview

Deploy the cal.com fork to fly.io via a GitHub Actions pipeline that builds a Docker image on GitHub Runners, pushes it to GHCR, and deploys the pre-built image to fly.io. Database migrations run automatically via fly.io's `release_command` before traffic shifts to the new container.

## Architecture

```
push to prod branch
        │
        ▼
GitHub Actions workflow (deploy-prod.yml)
  ├── Job 1: build  [environment: production]
  │     ├── checkout prod branch
  │     ├── docker buildx build (linux/amd64)
  │     ├── pass build-time ARGs from GitHub secrets/variables
  │     ├── GitHub Actions layer cache (type=gha)
  │     └── push ghcr.io/gclockwood/cal.com:<sha> + :latest
  │
  └── Job 2: deploy  [environment: production, needs: build]
        ├── flyctl deploy --image ghcr.io/gclockwood/cal.com:<sha>
        └── fly.io runs release_command: npx prisma migrate deploy
              └── if migration fails → deploy aborted, old container serves

fly.io app: cal-com-halftide (ewr)
  ├── web process (Next.js on port 3000)
  ├── fly.io Postgres cluster: cal-com-halftide-db (ewr, private network)
  └── Upstash Redis via fly.io extension (ewr, private network)
```

## Files to Create

### `fly.toml`

```toml
app = "cal-com-halftide"
primary_region = "ewr"

[build]
  image = "ghcr.io/gclockwood/cal.com:latest"

[deploy]
  release_command = "npx prisma migrate deploy"

[env]
  PORT = "3000"
  NODE_ENV = "production"

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

### `.github/workflows/deploy-prod.yml`

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

## One-Time Infrastructure Setup

Run these `flyctl` commands locally once to provision fly.io resources:

```bash
# 1. Create the fly app
fly apps create cal-com-halftide --machines

# 2. Create the Postgres cluster
#    shared-cpu-1x + 1GB RAM (~$3/mo), 10GB volume, single node
fly pg create \
  --name cal-com-halftide-db \
  --region ewr \
  --vm-size shared-cpu-1x \
  --volume-size 10 \
  --initial-cluster-size 1

# 3. Attach Postgres — automatically sets DATABASE_URL secret on the app
fly pg attach cal-com-halftide-db --app cal-com-halftide

# 4. Set DATABASE_DIRECT_URL to same value as DATABASE_URL
#    (retrieve DATABASE_URL first: fly secrets list --app cal-com-halftide)
fly secrets set DATABASE_DIRECT_URL=<same-as-DATABASE_URL> --app cal-com-halftide

# 5. Create Redis via Upstash extension
fly ext upstash redis create \
  --name cal-com-halftide-redis \
  --region ewr

# 6. Set Redis and app secrets
fly secrets set \
  REDIS_URL=<upstash-redis-url> \
  NEXTAUTH_SECRET=<generated> \
  NEXTAUTH_URL=https://cal-com-halftide.fly.dev \
  CALENDSO_ENCRYPTION_KEY=<generated-32-chars> \
  NEXT_PUBLIC_WEBAPP_URL=https://cal-com-halftide.fly.dev \
  --app cal-com-halftide

# 7. Create the prod branch
git checkout -b prod
git push origin prod
```

## Secrets Reference

### GitHub Actions — `production` environment

Configure at: **Settings → Environments → production → branch restriction: prod**

| Name | Type | Purpose |
|---|---|---|
| `FLY_API_TOKEN` | Secret | Authorises flyctl to deploy |
| `NEXTAUTH_SECRET` | Secret | Baked into image at build time |
| `CALENDSO_ENCRYPTION_KEY` | Secret | Baked into image at build time |
| `BUILD_DATABASE_URL` | Secret | Prisma type generation at build time (can be dummy URL) |
| `NEXT_PUBLIC_WEBAPP_URL` | Variable | e.g. `https://cal-com-halftide.fly.dev` |
| `NEXT_PUBLIC_API_V2_URL` | Variable | e.g. `https://cal-com-halftide.fly.dev/api/v2` |
| `ORGANIZATIONS_ENABLED` | Variable | `false` unless using orgs feature |
| `NEXT_PUBLIC_SINGLE_ORG_SLUG` | Variable | Leave blank unless using single-org mode |

### fly.io Secrets (runtime)

| Name | Source |
|---|---|
| `DATABASE_URL` | Auto-set by `fly pg attach` |
| `DATABASE_DIRECT_URL` | Set manually — same value as `DATABASE_URL` |
| `REDIS_URL` | From Upstash after `fly ext upstash redis create` |
| `NEXTAUTH_SECRET` | Must match GitHub secret value exactly |
| `NEXTAUTH_URL` | e.g. `https://cal-com-halftide.fly.dev` |
| `CALENDSO_ENCRYPTION_KEY` | Must match GitHub secret value exactly |
| `NEXT_PUBLIC_WEBAPP_URL` | e.g. `https://cal-com-halftide.fly.dev` |

**Important:** `NEXTAUTH_SECRET` and `CALENDSO_ENCRYPTION_KEY` must be identical in both GitHub secrets and fly.io secrets. Mismatched values will break auth and encryption silently.

## Key Design Decisions

- **SHA-tagged images** — deploy job references the exact Git SHA tag from the build job, never `:latest`, preventing race conditions.
- **GitHub Actions layer cache** — `type=gha` cache makes incremental builds significantly faster when only app code changes.
- **`release_command`** — runs `npx prisma migrate deploy` in a temporary container with full access to fly secrets before traffic shifts. A non-zero exit aborts the deploy and keeps the old container live.
- **`--strategy rolling`** — fly.io starts the new container before stopping the old one, ensuring zero-downtime deploys.
- **Private network** — both Postgres and Redis are accessed over fly.io's internal network (`*.internal`), keeping latency at ~0.5–2ms per query with no TLS overhead.
- **Environment protection** — GitHub `production` environment restricts secret access to the `prod` branch only, preventing accidental deploys from other branches or PRs.
