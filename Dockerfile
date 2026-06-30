# Use official Node.js runtime (Node 22 is recommended for OpenClaw)
FROM node:22-slim

# Set environment variables for non-root execution and browser paths
ENV PLAYWRIGHT_BROWSERS_PATH=/app/playwright-cache
ENV OPENCLAW_STATE_DIR=/app/state
ENV PORT=7860

# Install system dependencies:
# - nginx: Reverse proxy
# - git, curl, unzip: Setup helpers
# - python3, python3-pip: For calculations and utilities
# - ffmpeg: Required by yt-dlp to merge video streams (1080p+)
# - sqlite3: To perform database chat cleanups
# - gnupg: For GPG AES-256 backup encryption
# - Playwright Chromium dependencies explicitly listed to avoid using Playwright's runtime sudo install script
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    git \
    curl \
    unzip \
    python3 \
    python3-pip \
    ffmpeg \
    sqlite3 \
    gnupg \
    sudo \
    libglib2.0-0 \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxcb1 \
    libxkbcommon0 \
    libxdamage1 \
    libxcomposite1 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    && rm -rf /var/lib/apt/lists/*

# Install yt-dlp (industry-standard command line video downloader)
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && \
    chmod a+rx /usr/local/bin/yt-dlp

WORKDIR /app

# Install OpenClaw globally from the stable NPM registry
RUN npm install -g openclaw@latest

# Prepare directories and grant broad write permissions for random non-root container users (UID 1000)
RUN mkdir -p /app/state /app/playwright-cache /app/extensions/ubol /app/extensions/videodownloader && \
    chmod -R 777 /app /var/log/nginx /var/lib/nginx /etc/nginx

# Install Playwright browser binary (dependencies already loaded above via apt-get)
RUN npx playwright install chromium

# Download and unzip uBlock Origin Lite (Manifest V3 Edition)
RUN curl -L -o /tmp/ubol.zip https://github.com/uBlockOrigin/uBOL-home/releases/download/uBOL_0.1.26.11029/uBOL_0.1.26.11029.chromium.zip && \
    unzip /tmp/ubol.zip -d /app/extensions/ubol && \
    rm /tmp/ubol.zip

# Download and unzip the Open Source Video Downloader Extension from GitHub
RUN curl -L -o /tmp/video_downloader.zip https://github.com/faridhafizh/video-downloader-ext/archive/refs/heads/master.zip && \
    unzip /tmp/video_downloader.zip -d /app/extensions/ && \
    mv /app/extensions/video-downloader-ext-master /app/extensions/videodownloader && \
    rm /tmp/video_downloader.zip

# Place files in their correct folders
COPY nginx.conf /etc/nginx/nginx.conf
COPY openclaw.json /app/openclaw.json
COPY settings.yml /app/settings.yml

# Setup cleanup script
COPY cleanup-history.sh /app/cleanup-history.sh
RUN chmod +x /app/cleanup-history.sh

# Expose Port 7860
EXPOSE 7860

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]