# Use official Microsoft Playwright image based on Ubuntu 24.04 (Noble), which pre-installs Node LTS, browsers, and libraries
FROM mcr.microsoft.com/playwright:v1.49.0-noble

# Set environment variables (inherits PLAYWRIGHT_BROWSERS_PATH=/ms-playwright from base image)
ENV OPENCLAW_STATE_DIR=/app/state
ENV PORT=7860

# Install required system tools (all browser libraries are already present in the base image)
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
    && rm -rf /var/lib/apt/lists/*

# Install yt-dlp (industry-standard command line video downloader)
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && \
    chmod a+rx /usr/local/bin/yt-dlp

WORKDIR /app

# Upgrade Node.js inside the container to v22.19.0 to satisfy OpenClaw's engine dependency requirement
RUN npm install -g n && n 22.19.0 && ln -sf /usr/local/bin/node /usr/bin/node

# Install OpenClaw globally from the stable NPM registry
RUN npm install -g openclaw@latest

# Prepare directories and grant broad write permissions for random non-root container users (UID 1000)
RUN mkdir -p /app/state /app/extensions/ubol /app/extensions/videodownloader && \
    chmod -R 777 /app /var/log/nginx /var/lib/nginx /etc/nginx

# Download and unzip the latest uBlock Origin Lite (Manifest V3 Edition) dynamically from GitHub Releases API
RUN LATEST_UBOL_URL=$(python3 -c "import urllib.request, json; res = urllib.request.urlopen('https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest'); data = json.loads(res.read().decode()); print([a['browser_download_url'] for a in data['assets'] if 'chromium.zip' in a['name']][0])") && \
    curl -L -o /tmp/ubol.zip "$LATEST_UBOL_URL" && \
    unzip /tmp/ubol.zip -d /app/extensions/ubol && \
    rm /tmp/ubol.zip

# Download and unzip the Open Source Video Downloader Extension dynamically based on the repository's default branch
# We use wildcards to handle folder renames (supporting main or master branches automatically)
RUN DEFAULT_BRANCH=$(python3 -c "import urllib.request, json; res = urllib.request.urlopen('https://api.github.com/repos/faridhafizh/video-downloader-ext'); data = json.loads(res.read().decode()); print(data['default_branch'])") && \
    curl -L -o /tmp/video_downloader.zip "https://github.com/faridhafizh/video-downloader-ext/archive/refs/heads/${DEFAULT_BRANCH}.zip" && \
    unzip /tmp/video_downloader.zip -d /app/extensions/ && \
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