# Multi-stage Dockerfile for production Vue.js app deployment

# ================================
# Stage 1: Build Stage
# ================================
FROM node:lts-alpine AS builder

# Set working directory
WORKDIR /app

# Copy package files for dependency caching
COPY emush/App/package.json emush/App/yarn.lock ./

# Install dependencies with frozen lockfile for reproducible builds
RUN yarn install --frozen-lockfile --production=false

# Copy .env file for build-time environment variables
COPY .env ./

# Copy source code
COPY emush/App/public ./public
COPY emush/App/src ./src
COPY emush/App/vite.config.js ./vite.config.js
COPY emush/App/index.html ./index.html
COPY emush/App/offline.html ./offline.html
COPY emush/App/package.json ./package.json
COPY emush/App/tsconfig.json ./tsconfig.json

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
RUN apk upgrade --no-cache

# Create web directory
RUN mkdir -p /srv

# Copy built application from builder stage
COPY --from=builder --chown=vuejs:nodejs /app/dist /srv

# Copy Caddyfile configuration
COPY Caddyfile.app /etc/caddy/Caddyfile

# Set proper permissions for Caddy
RUN chown -R vuejs:nodejs /srv \
    && chown -R vuejs:nodejs /etc/caddy \
    && chown vuejs:nodejs /etc/caddy/Caddyfile

# Switch to non-root user (Caddy can run as non-root user)
USER vuejs

# Expose port
EXPOSE 5173

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:5173/health || exit 1

# Start Caddy
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile"]
