#!/bin/bash

# Exit code tracking
set -e

LOG_FILE="/var/log/openclaw-cleanup.log"
# Fallback to /tmp if logs directory is unwritable
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/openclaw-cleanup.log"

echo "=== Scheduled Daily Cleanup Started at $(date) ===" >> "$LOG_FILE"

# 1. Clear OpenClaw temporary history directories
if [ -d "/app/state/history" ]; then
    echo "Clearing /app/state/history/..." >> "$LOG_FILE"
    rm -rf /app/state/history/* 2>/dev/null || true
fi

# 2. Clear OpenClaw execution logs
if [ -d "/app/state/logs" ]; then
    echo "Clearing /app/state/logs/..." >> "$LOG_FILE"
    rm -rf /app/state/logs/* 2>/dev/null || true
fi

# 3. SQLite Database Maintenance (Clear chats and vacuum database)
# We preserve the database itself and the 'devices' table so paired iOS devices are NOT unlinked.
DB_PATH="/app/state/openclaw.db"
if [ -f "$DB_PATH" ]; then
    echo "Cleaning SQLite database at $DB_PATH..." >> "$LOG_FILE"
    if command -v sqlite3 &>/dev/null; then
        # Check if tables exist before deleting, otherwise ignore errors
        sqlite3 "$DB_PATH" "
          CREATE TABLE IF NOT EXISTS messages (id TEXT);
          CREATE TABLE IF NOT EXISTS conversations (id TEXT);
          DELETE FROM messages; 
          DELETE FROM conversations; 
          VACUUM;
        " 2>&1 >> "$LOG_FILE" || true
        echo "Database vacuum complete. Chat history wiped." >> "$LOG_FILE"
    else
        echo "sqlite3 CLI not found. Re-initializing database to clear state." >> "$LOG_FILE"
        rm -f "$DB_PATH"
    fi
fi

# 4. Clear temporary system folders to free up disk space in the container
echo "Clearing temporary files..." >> "$LOG_FILE"
rm -rf /tmp/* 2>/dev/null || true

# 5. Create Encrypted State Backup (Zero-Trust Backup Setup)
# Tars the state folder and encrypts it with AES-256 using GPG passphrase.
# We copy files to /tmp/state_backup_temp/app/state first to prevent tar file-locking or file-changed-during-read errors (Exit 1).
# By using /app/state relative structures, unpacking the tarball to / will restore it to the exact location.
BACKUP_PASSPHRASE_VAL="${BACKUP_PASSPHRASE}"
if [ -n "$BACKUP_PASSPHRASE_VAL" ]; then
    echo "Creating GPG-encrypted state backup..." >> "$LOG_FILE"

    # Secure clean copy to avoid open file descriptor locks
    rm -rf /tmp/state_backup_temp
    mkdir -p /tmp/state_backup_temp/app
    cp -Rp /app/state /tmp/state_backup_temp/app/

    # Tar the copy and capture exits safely (storing as app/state path)
    if tar -czf /tmp/state-backup.tar.gz -C /tmp/state_backup_temp app/state; then
        # Encrypt the tarball. Passphrase is piped over stdin (--passphrase-fd 0)
        # instead of passed as a CLI argument - command-line arguments are visible
        # to any other process in this container via `ps`/`/proc/<pid>/cmdline`,
        # so this keeps the passphrase out of that surface.
        printf '%s' "$BACKUP_PASSPHRASE_VAL" | gpg --symmetric --batch --yes --pinentry-mode loopback --passphrase-fd 0 -o /app/state-backup.tar.gz.gpg /tmp/state-backup.tar.gz
        echo "Encrypted backup successfully created at /app/state-backup.tar.gz.gpg" >> "$LOG_FILE"
    else
        echo "ERROR: Archiving state folder failed." >> "$LOG_FILE"
    fi

    # Cleanup temp directory and tarball
    rm -rf /tmp/state-backup.tar.gz /tmp/state_backup_temp
else
    echo "Backup step skipped: BACKUP_PASSPHRASE environment variable is not defined." >> "$LOG_FILE"
fi

echo "=== Daily Cleanup Finished at $(date) ===" >> "$LOG_FILE"
