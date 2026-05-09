# ── Stage 1: Install dependencies ────────────────────────────────────────────
FROM oven/bun:1-alpine AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

# ── Stage 2: Build ────────────────────────────────────────────────────────────
FROM oven/bun:1-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# NEXT_PUBLIC_ vars must be present at build time — Next.js inlines them into
# client bundles. Passed as build args from docker-compose.
ARG NEXT_PUBLIC_MAPBOX_TOKEN
ARG NEXT_PUBLIC_POSTHOG_KEY
ARG NEXT_PUBLIC_POSTHOG_HOST
ARG NEXT_PUBLIC_PROJECT_SHUTDOWN=false

ENV NEXT_PUBLIC_MAPBOX_TOKEN=$NEXT_PUBLIC_MAPBOX_TOKEN
ENV NEXT_PUBLIC_POSTHOG_KEY=$NEXT_PUBLIC_POSTHOG_KEY
ENV NEXT_PUBLIC_POSTHOG_HOST=$NEXT_PUBLIC_POSTHOG_HOST
ENV NEXT_PUBLIC_PROJECT_SHUTDOWN=$NEXT_PUBLIC_PROJECT_SHUTDOWN
ENV NEXT_TELEMETRY_DISABLED=1

RUN bun run build

# ── Stage 3: Runtime (node only — bun not needed for next standalone) ─────────
FROM node:20-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# standalone output contains a traced subset of node_modules — no full copy needed
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

USER nextjs

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

CMD ["node", "server.js"]
