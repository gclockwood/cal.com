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

# next start does not read HOSTNAME from env — pass explicitly via -H
exec yarn workspace @calcom/web next start -H "${HOSTNAME:-0.0.0.0}" -p "${PORT:-3000}"
