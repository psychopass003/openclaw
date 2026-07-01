# Use official Microsoft Playwright image based on Ubuntu 24.04 (Noble), which pre-installs Node LTS, browsers, and libraries
FROM mcr.microsoft.com/playwright:v1.49.0-noble

# Set environment variables (inherits PLAYWRIGHT_BROWSERS_PATH=/ms-playwright from base image)
ENV OPENCLAW_STATE_DIR=/app/state
ENV PORT=7860

# Install required system tools (all browser libraries are already present in the base image)
# NOTE: added `openssl` - entrypoint.sh uses it to hash the Nginx Basic Auth password.
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
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Install yt-dlp (industry-standard command line video downloader)
RUN curl -fL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && \
    chmod a+rx /usr/local/bin/yt-dlp

WORKDIR /app

# Upgrade Node.js inside the container to v22.19.0 to satisfy OpenClaw's engine dependency requirement
RUN npm install -g n && n 22.19.0 && ln -sf /usr/local/bin/node /usr/bin/node

# Install OpenClaw globally from the stable NPM registry.
#
# PINNED (was @latest): an unpinned "latest" tag means every Space rebuild
# could silently pull in a newer OpenClaw with a changed config schema or
# gateway behavior - which is exactly how the strict openclaw.json schema
# validation failure happened before. Pinning makes rebuilds reproducible:
# the image only moves to a newer OpenClaw when this line is deliberately
# bumped, at which point openclaw.json can be checked against
# https://docs.openclaw.ai/gateway/configuration-reference before rebuilding.
# Bump deliberately with: npm view openclaw versions (or check npmjs.com/package/openclaw)
RUN npm install -g openclaw@2026.6.9

# Prepare directories needed at *runtime* by the non-root UID (Hugging Face Docker
# Spaces run as a fixed UID 1000, per HF's own Docker Spaces docs - not actually
# random, though the original comment here assumed it was). Only directories
# OpenClaw/Nginx genuinely need to WRITE to at runtime are made world-writable here.
#
# SECURITY FIX: the previous version ran `chmod -R 777 /app /etc/nginx`, which made
# nginx.conf, openclaw.json (containing the gateway auth token reference), and
# cleanup-history.sh all sit inside a world-writable directory - any process in the
# container (a compromised dependency, a malicious browser extension, or the agent's
# own shell tool if it were ever tricked via prompt injection) could silently replace
# those files. /etc/nginx and the top-level /app directory are no longer in this list;
# nginx only needs to *read* its config (it already writes pid/temp files under /tmp
# per nginx.conf), and openclaw.json/cleanup-history.sh/entrypoint.sh don't need to be
# writable at all after the image is built.
RUN mkdir -p /app/state /app/extensions/ubol /app/extensions/videodownloader && \
    chmod -R 777 /app/state /app/extensions /var/log/nginx /var/lib/nginx

# Download and unzip the latest uBlock Origin Lite (Manifest V3 Edition) dynamically from GitHub Releases API
# NOTE: `curl -f` added so the build fails loudly (instead of silently unzipping an
# HTML error page) if GitHub's API rate-limits the build or the asset name changes.
RUN LATEST_UBOL_URL=$(python3 -c "import urllib.request, json; res = urllib.request.urlopen('https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest'); data = json.loads(res.read().decode()); print([a['browser_download_url'] for a in data['assets'] if 'chromium.zip' in a['name']][0])") && \
    curl -fL -o /tmp/ubol.zip "$LATEST_UBOL_URL" && \
    unzip -q /tmp/ubol.zip -d /app/extensions/ubol && \
    rm /tmp/ubol.zip

# Download and unzip the Open Source Video Downloader Extension dynamically based on the repository's default branch
# We use wildcards to handle folder renames (supporting main or master branches automatically)
RUN DEFAULT_BRANCH=$(python3 -c "import urllib.request, json; res = urllib.request.urlopen('https://api.github.com/repos/faridhafizh/video-downloader-ext'); data = json.loads(res.read().decode()); print(data['default_branch'])") && \
    curl -fL -o /tmp/video_downloader.zip "https://github.com/faridhafizh/video-downloader-ext/archive/refs/heads/${DEFAULT_BRANCH}.zip" && \
    unzip -q /tmp/video_downloader.zip -d /app/extensions/ && \
    mv /app/extensions/video-downloader-ext-* /app/extensions/videodownloader && \
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