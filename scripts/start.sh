#!/bin/sh
set -x

# Replace the statically built BUILT_NEXT_PUBLIC_WEBAPP_URL with run-time NEXT_PUBLIC_WEBAPP_URL
# NOTE: if these values are the same, this will be skipped.
scripts/replace-placeholder.sh "$BUILT_NEXT_PUBLIC_WEBAPP_URL" "$NEXT_PUBLIC_WEBAPP_URL"

scripts/wait-for-it.sh ${DATABASE_HOST} -- echo "database is up"
npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
# Seeding is handled by fly.io release_command before traffic shifts.
# Set SKIP_APP_STORE_SEED=1 to skip on startup (recommended for production).
if [ -z "$SKIP_APP_STORE_SEED" ]; then
  npx ts-node --transpile-only /calcom/scripts/seed-app-store.ts
fi
yarn start
