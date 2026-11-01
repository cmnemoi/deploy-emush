# Multi-stage Dockerfile for production Vue.js app deployment

# ================================
# Stage 1: Build Stage
# ================================
FROM node:lts-alpine AS builder

# Set working directory
WORKDIR /app

# Copy package files for dependency caching
COPY emush/App/ ./

# Install dependencies with frozen lockfile for reproducible builds
# Node no longer bundles corepack since version 25.
RUN npm install --global corepack && corepack enable && yarn install --immutable

# Copy .env file for build-time environment variables
COPY .env ./

# Build the application for production
RUN yarn build

# ================================
# Stage 2: Production Stage
# ================================
FROM caddy:2.10 AS production

# Add non-root user for security
RUN addgroup -g 1001 -S nodejs \
    && adduser -S vuejs -u 1001

# Install security updates
RUN apk update && apk upgrade --no-cache

# Caddy listens on 5173 and does not need the capability the image grants to bind low ports
RUN setcap -r /usr/bin/caddy

# Create web directory
RUN mkdir -p /srv

# Copy built application from builder stage: owned by root, so Caddy cannot modify what it serves
COPY --from=builder /app/dist /srv

# Copy Caddyfile configuration
COPY Caddyfile.app /etc/caddy/Caddyfile

# Switch to non-root user (Caddy can run as non-root user)
USER vuejs

# Expose port
EXPOSE 5173

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:5173/health || exit 1

# Start Caddy
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile"]
