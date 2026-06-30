#!/bin/bash

# Exit on script error
set -e

echo "=== OpenClaw Hugging Face Space Bootloader ==="

# Explicitly export environment variables to make them visible to all background loops and child scripts
export BACKUP_PASSPHRASE
export OPENCLAW_STATE_DIR=/app/state
mkdir -p "$OPENCLAW_STATE_DIR"

# 1. Decrypt State Backup on Startup (Zero-Trust Security)
# If an encrypted backup archive exists and a passphrase is provided,
# decrypt it and extract it to restore settings, memory, and paired devices.
BACKUP_FILE="/app/state-backup.tar.gz.gpg"
if [ -f "$BACKUP_FILE" ]; then
    if [ -n "$BACKUP_PASSPHRASE" ]; then
        echo "Found encrypted state backup. Decrypting..."
        if gpg --decrypt --batch --passphrase "$BACKUP_PASSPHRASE" -o /tmp/state-backup.tar.gz "$BACKUP_FILE"; then
            echo "Decryption successful. Restoring file structures..."
            tar -xzf /tmp/state-backup.tar.gz -C /
            rm -f /tmp/state-backup.tar.gz
            
            # Ensure full write permissions for random Hugging Face UID on restored files and database
            chmod -R 777 "$OPENCLAW_STATE_DIR" || true
            echo "State files restored successfully."
        else
            echo "ERROR: Decryption of backup failed! Invalid passphrase. Starting with a fresh state."
        fi
    else
        echo "WARNING: Encrypted backup found at $BACKUP_FILE, but BACKUP_PASSPHRASE environment variable is missing. Cannot restore."
    fi
fi

# 2. Custom Cron Daemon Loop (Non-root user friendly)
# Runs a background bash thread that sleeps until 2:00 AM IST (20:30 UTC)
# and then fires /app/cleanup-history.sh, completely replacing root-only cron services.
(
    echo "Initializing Daily Cleanup Scheduler (Target: 2:00 AM IST / 20:30 UTC)..."
    # Delay startup slightly to avoid immediate CPU usage
    sleep 30
    while true; do
        # Use python to calculate exact seconds until the next 20:30 UTC
        sleep_seconds=$(python3 -c "import datetime; now=datetime.datetime.now(datetime.timezone.utc); target=now.replace(hour=20, minute=30, second=0, microsecond=0); target += datetime.timedelta(days=1) if now >= target else datetime.timedelta(); print(int((target - now).total_seconds()))")
        echo "Daily cleanup cron loop: sleeping for ${sleep_seconds} seconds..."
        sleep "$sleep_seconds"
        
        echo "Triggering scheduled daily cleanup and encrypted backup..."
        /app/cleanup-history.sh || true
    done
) &

# 3. Start Keep-Alive Self-Ping Loop (if SPACE_URL is set)
# Pings the external Space URL via HTTP request every 25 minutes to prevent sleep.
if [ -n "$SPACE_URL" ]; then
    echo "Registering Keep-Alive self-ping loop for: $SPACE_URL"
    (
        # Wait a minute after startup before the first ping
        sleep 60
        while true; do
            echo "Sending keep-alive ping to $SPACE_URL at $(date)..."
            if [ -n "$HF_TOKEN" ]; then
                # Use HF Token if Space is private to authenticate the ping request
                curl -s -H "Authorization: Bearer $HF_TOKEN" -I "$SPACE_URL" > /dev/null || true
            else
                curl -s -I "$SPACE_URL" > /dev/null || true
            fi
            # Sleep for 25 minutes (1500 seconds)
            sleep 1500
        done
    ) &
else
    echo "WARNING: SPACE_URL environment variable is not defined. Keep-alive self-ping is inactive."
    echo "To enable keep-alive, add your Space's URL (e.g. https://user-space.hf.space) to Space Secrets."
fi

# 4. Start SearXNG locally in the background (binding only to 127.0.0.1)
echo "Starting SearXNG (Web Search)..."
if python3 -c "import searxng" &>/dev/null; then
    python3 -m searxng.webapp &
elif python3 -c "import searx" &>/dev/null; then
    python3 -m searx.webapp &
else
    echo "WARNING: SearXNG modules not found. Skipping auto-start."
fi

# 5. Config Setup with Template Hash Matching
# We calculate a hash of the Git repository's template config.
# If a new commit updates openclaw.json, we force-apply the new settings.
# Otherwise, we preserve the user's custom changes made via the Web UI dashboard.
if [ -f /app/openclaw.json ]; then
    TEMPLATE_HASH=$(python3 -c "import hashlib; print(hashlib.md5(open('/app/openclaw.json','rb').read()).hexdigest())")
    COPY_NEEDED=false
    
    if [ ! -f "$OPENCLAW_STATE_DIR/openclaw.json" ]; then
        echo "No config found in state directory. Copying template..."
        COPY_NEEDED=true
    elif [ -f "$OPENCLAW_STATE_DIR/.config_hash" ]; then
        LAST_HASH=$(cat "$OPENCLAW_STATE_DIR/.config_hash")
        if [ "$TEMPLATE_HASH" != "$LAST_HASH" ]; then
            echo "Detected updated openclaw.json in Git repository. Force-updating config..."
            COPY_NEEDED=true
        fi
    else
        # Persistent config exists but hash file is missing (e.g., migration from older version)
        # We overwrite to guarantee we clear out any older clobbered configurations.
        echo "Config hash tracker missing. Restoring config from repository template..."
        COPY_NEEDED=true
    fi
    
    if [ "$COPY_NEEDED" = "true" ]; then
        cp /app/openclaw.json "$OPENCLAW_STATE_DIR/openclaw.json"
        echo "$TEMPLATE_HASH" > "$OPENCLAW_STATE_DIR/.config_hash"
        chmod 777 "$OPENCLAW_STATE_DIR/openclaw.json" || true
        chmod 777 "$OPENCLAW_STATE_DIR/.config_hash" || true
    fi
fi

# 6. Start OpenClaw Gateway in the background (Port 18789)
echo "Starting OpenClaw Gateway..."
if command -v openclaw &>/dev/null; then
    openclaw gateway --allow-unconfigured &
elif [ -f /app/bin/openclaw ]; then
    /app/bin/openclaw gateway --allow-unconfigured &
else
    node /app/dist/index.js &
fi

# 6.5. Start Device Auto-Approval Daemon
# Automatically approves any incoming device pairing requests within 5 seconds,
# making the web dashboard connection completely seamless.
(
    echo "Initializing Device Auto-Approval Daemon..."
    sleep 15
    while true; do
        if command -v openclaw &>/dev/null; then
            # Extract request ID from preview output and approve it
            request_id=$(openclaw devices approve --latest 2>/dev/null | grep -E -o '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n 1)
            if [ -n "$request_id" ]; then
                echo "Auto-Approval Daemon: Found pending request $request_id. Approving..."
                openclaw devices approve "$request_id" || true
            fi
        elif [ -f /app/bin/openclaw ]; then
            request_id=$(/app/bin/openclaw devices approve --latest 2>/dev/null | grep -E -o '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n 1)
            if [ -n "$request_id" ]; then
                echo "Auto-Approval Daemon: Found pending request $request_id. Approving..."
                /app/bin/openclaw devices approve "$request_id" || true
            fi
        fi
        sleep 5
    done
) &

# 7. Start Nginx in the foreground to keep container running and bind port 7860
echo "Starting Nginx Reverse Proxy on port 7860..."
exec nginx -g "daemon off;"