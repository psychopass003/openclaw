#!/bin/bash

# Exit on script error
set -e

echo "=== OpenClaw Hugging Face Space Bootloader ==="

# Explicitly export environment variables to make them visible to all background loops and child scripts
export BACKUP_PASSPHRASE
export OPENCLAW_STATE_DIR=/app/state
mkdir -p "$OPENCLAW_STATE_DIR"

# 1. Outer Nginx Basic Auth (Second Login Layer)
# ----------------------------------------------------------------------------
# The OpenClaw Gateway behind Nginx has shell/file/browser access, so anyone
# who can reach it is effectively a trusted operator. This generates the
# htpasswd file Nginx checks *before* a request is ever proxied to the
# Gateway, so this stays a real second layer even if Gateway-side auth is
# ever misconfigured or a future update changes its defaults.
echo "Configuring outer login (Nginx Basic Auth)..."
HTPASSWD_FILE="$OPENCLAW_STATE_DIR/.htpasswd"
if [ -n "$BASIC_AUTH_USER" ] && [ -n "$BASIC_AUTH_PASS" ]; then
    HASH=$(openssl passwd -apr1 "$BASIC_AUTH_PASS")
    echo "${BASIC_AUTH_USER}:${HASH}" > "$HTPASSWD_FILE"
    echo "Using BASIC_AUTH_USER / BASIC_AUTH_PASS from Space secrets."
else
    GEN_USER="openclaw"
    GEN_PASS=$(python3 -c "import secrets; print(secrets.token_urlsafe(18))")
    HASH=$(openssl passwd -apr1 "$GEN_PASS")
    echo "${GEN_USER}:${HASH}" > "$HTPASSWD_FILE"
    echo "############################################################"
    echo "# WARNING: BASIC_AUTH_USER / BASIC_AUTH_PASS are not set."
    echo "# A temporary login was generated so this Space is never left"
    echo "# reachable with no outer login at all:"
    echo "#   Username: ${GEN_USER}"
    echo "#   Password: ${GEN_PASS}"
    echo "#"
    echo "# This password is regenerated (and changes) on every restart."
    echo "# Set BASIC_AUTH_USER and BASIC_AUTH_PASS as Space secrets"
    echo "# (Settings -> Variables and secrets) for a permanent login."
    echo "############################################################"
fi
chmod 644 "$HTPASSWD_FILE"

# 2. Decrypt State Backup on Startup (Zero-Trust Security)
# If an encrypted backup archive exists and a passphrase is provided,
# decrypt it and extract it to restore settings, memory, and paired devices.
BACKUP_FILE="/app/state-backup.tar.gz.gpg"
if [ -f "$BACKUP_FILE" ]; then
    if [ -n "$BACKUP_PASSPHRASE" ]; then
        echo "Found encrypted state backup. Decrypting..."
        # Passphrase is piped over stdin (--passphrase-fd 0) instead of passed as a
        # CLI argument, so it never shows up in `ps`/`/proc/<pid>/cmdline` for other
        # processes in the container to read.
        if printf '%s' "$BACKUP_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt -o /tmp/state-backup.tar.gz "$BACKUP_FILE"; then
            echo "Decryption successful. Restoring file structures..."
            tar -xzf /tmp/state-backup.tar.gz -C /
            rm -f /tmp/state-backup.tar.gz

            # Ensure full write permissions for HF's fixed runtime UID (1000) on restored
            # files and database. Scoped to the state dir only - this never touches
            # /etc/nginx or the application config files that ship with the image.
            chmod -R 777 "$OPENCLAW_STATE_DIR" || true
            echo "State files restored successfully."
        else
            echo "ERROR: Decryption of backup failed! Invalid passphrase. Starting with a fresh state."
        fi
    else
        echo "WARNING: Encrypted backup found at $BACKUP_FILE, but BACKUP_PASSPHRASE environment variable is missing. Cannot restore."
    fi
fi

# 3. Custom Cron Daemon Loop (Non-root user friendly)
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

# 4. Start Keep-Alive Self-Ping Loop (if SPACE_URL is set)
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

# 5. Start SearXNG locally in the background (binding only to 127.0.0.1)
# Generate a fresh session-signing secret on every boot instead of using the
# fixed value baked into the public settings.yml template in the repo.
if [ -f /app/settings.yml ]; then
    FRESH_SEARXNG_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    sed -i "s/secret_key: \"__RUNTIME_GENERATED_SECRET__\"/secret_key: \"${FRESH_SEARXNG_KEY}\"/" /app/settings.yml
fi

echo "Starting SearXNG (Web Search)..."
if python3 -c "import searxng" &>/dev/null; then
    python3 -m searxng.webapp &
elif python3 -c "import searx" &>/dev/null; then
    python3 -m searx.webapp &
else
    echo "WARNING: SearXNG modules not found. Skipping auto-start."
fi

# 6. Config Setup with Template Hash Matching
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

if [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "############################################################"
    echo "# WARNING: OPENCLAW_GATEWAY_TOKEN is not set."
    echo "# openclaw.json references \${OPENCLAW_GATEWAY_TOKEN} for Gateway"
    echo "# auth. Gateway auth fails CLOSED when it's unset, which means"
    echo "# every connection - including your own - will be refused."
    echo "# Set OPENCLAW_GATEWAY_TOKEN as a Space secret with a long"
    echo "# random value before relying on this deployment."
    echo "############################################################"
fi

# 7. Start OpenClaw Gateway in the background (Port 18789)
echo "Starting OpenClaw Gateway..."
if command -v openclaw &>/dev/null; then
    openclaw gateway --allow-unconfigured &
elif [ -f /app/bin/openclaw ]; then
    /app/bin/openclaw gateway --allow-unconfigured &
else
    node /app/dist/index.js &
fi

# 8. Device pairing approval
# ----------------------------------------------------------------------------
# SECURITY: OpenClaw's device-pairing approval exists specifically to stop a
# stranger who reaches this URL from gaining full operator access (shell,
# browser, messaging tools). The previous version of this script approved
# *every* pending pairing request, forever, every 5 seconds - which means
# anyone on the internet who found this Space's URL and opened the dashboard
# would have been silently granted full access within seconds. That has been
# removed.
#
# Default (recommended): do nothing here. Approve your own devices yourself.
# If your Hugging Face plan gives you Spaces Dev Mode / SSH into this
# container, run: `openclaw devices list` then `openclaw devices approve <id>`.
#
# Optional convenience (off by default, opt-in only): set
# OPENCLAW_AUTO_APPROVE_FIRST_PAIRING=true as a Space secret to auto-approve
# pairing requests for a short window after a fresh boot only. This still
# widens the attack surface during that window - only enable it briefly while
# you personally connect for the first time, then unset it and restart.
AUTO_APPROVE_WINDOW_SECONDS=600
if [ "${OPENCLAW_AUTO_APPROVE_FIRST_PAIRING:-false}" = "true" ]; then
    (
        echo "Initializing TIME-BOXED Device Auto-Approval (${AUTO_APPROVE_WINDOW_SECONDS}s)..."
        echo "WARNING: any pairing request received in this window will be auto-approved."
        sleep 15
        end_time=$(( $(date +%s) + AUTO_APPROVE_WINDOW_SECONDS ))
        while [ "$(date +%s)" -lt "$end_time" ]; do
            if command -v openclaw &>/dev/null; then
                request_id=$(openclaw devices approve --latest 2>/dev/null | grep -E -o '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n 1)
                if [ -n "$request_id" ]; then
                    echo "Auto-Approval window: approving pairing request $request_id"
                    yes | openclaw devices approve "$request_id" || true
                fi
            elif [ -f /app/bin/openclaw ]; then
                request_id=$(/app/bin/openclaw devices approve --latest 2>/dev/null | grep -E -o '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n 1)
                if [ -n "$request_id" ]; then
                    echo "Auto-Approval window: approving pairing request $request_id"
                    yes | /app/bin/openclaw devices approve "$request_id" || true
                fi
            fi
            sleep 5
        done
        echo "Device auto-approval window closed. New devices now require manual approval."
    ) &
else
    echo "Device auto-approval is disabled (recommended default). Approve new devices manually."
fi

# 9. Start Nginx in the foreground to keep container running and bind port 7860
echo "Starting Nginx Reverse Proxy on port 7860..."
exec nginx -g "daemon off;"
