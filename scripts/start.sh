#!/bin/sh
set -x

# Replace the statically built BUILT_NEXT_PUBLIC_WEBAPP_URL with run-time NEXT_PUBLIC_WEBAPP_URL
# NOTE: if these values are the same, this will be skipped.
scripts/replace-placeholder.sh "$BUILT_NEXT_PUBLIC_WEBAPP_URL" "$NEXT_PUBLIC_WEBAPP_URL"

# On Fly.io, migrations and seeding are handled by release_command before
# traffic shifts. Only run them here for non-Fly environments.
if [ -z "$FLY_APP_NAME" ]; then
  if [ -n "$DATABASE_HOST" ]; then
    scripts/wait-for-it.sh ${DATABASE_HOST} -- echo "database is up"
  fi
  npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
  if [ -z "$SKIP_APP_STORE_SEED" ]; then
    npx ts-node --transpile-only /calcom/scripts/seed-app-store.ts
  fi
fi

# Fly.io uses IPv6 internally (fdaa:... addresses). Binding to :: creates a
# dual-stack socket that accepts both IPv4 and IPv6 connections.
# Binding to 0.0.0.0 would only listen on IPv4, causing Fly health checks
# to get "connection refused" on IPv6.
exec yarn workspace @calcom/web next start -H "${HOSTNAME:-::}" -p "${PORT:-3000}"
