# ============================================================
# BeEF (Browser Exploitation Framework) — Render-Ready Build
# Multi-stage Dockerfile optimized for Render deployment
# ============================================================

# --- Stage 1: Builder (compile gems) ---
FROM ruby:3.4-slim-bookworm AS builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        libssl-dev \
        libreadline-dev \
        zlib1g-dev \
        libsqlite3-dev \
        libyaml-dev \
        libxml2-dev \
        libxslt1-dev \
        nodejs \
        npm && \
    rm -rf /var/lib/apt/lists/*

# Clone BeEF from the official repo
RUN git clone --depth 1 https://github.com/beefproject/beef.git /beef

# Copy our custom config into the cloned source
COPY config.yaml /beef/config.yaml

WORKDIR /beef

RUN bundle config set --local without 'test development docs' && \
    bundle install --jobs 4 --retry 3

# --- Stage 2: Runtime ---
FROM ruby:3.4-slim-bookworm

ARG DEBIAN_FRONTEND=noninteractive
ARG UI_PORT=3000

# Install runtime deps
RUN adduser --home /beef --gecos beef --disabled-password beef && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        wget \
        libreadline-dev \
        libyaml-dev \
        libxml2-dev \
        libxslt1-dev \
        libncurses6 \
        libncurses-dev \
        libsqlite3-0 \
        libsqlite3-dev \
        sqlite3 \
        zlib1g \
        openssl \
        ca-certificates \
        nodejs \
        npm \
        git && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/*

# Copy application code from builder
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /beef /beef

# Copy entrypoint wrapper
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /beef

# Fix git ownership + make beef user own the entire app directory
RUN git config --global --add safe.directory /beef && \
    mkdir -p /beef/data && \
    chown -R beef:beef /beef

# --- Render Configuration ---
ENV BEEF_PORT=${UI_PORT}
ENV RACK_ENV=production
# Set BeEF password via env var (override in Render dashboard or docker-compose)
ENV BEEF_PASSWORD=CHANGE_ME_IN_RENDER_ENV

# Patch config to bind all interfaces (required for Render)
RUN sed -i 's/host: "127.0.0.1"/host: "0.0.0.0"/g' config.yaml || true

EXPOSE 3000

USER beef

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -f http://localhost:3000/ || exit 1

ENTRYPOINT ["/entrypoint.sh"]
