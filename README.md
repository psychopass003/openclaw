# OpenClaw Hugging Face Space Deployment Template

This folder contains a complete, optimized template for deploying your **OpenClaw Gateway** to a **Hugging Face Space**. It is configured to remain secure even if you make your Hugging Face Space repository **Public**.

---

## 🔒 1. Safe Key & Environment Management (Public Repository Safe)

If you configure your Hugging Face Space visibility to **Public**, anyone on the internet can inspect your repository files (including your `Dockerfile`, `nginx.conf`, and `openclaw.json`).

### Key Protection Boundary:
* **No hardcoded secrets**: Your keys are **never** written in code or configs. The `openclaw.json` file uses standard variable expansion (e.g., `"${MISTRAL_API_KEY}"` and `"${OPENCLAW_GATEWAY_TOKEN}"`). OpenClaw automatically parses and injects these variables from the system environment at startup.
* **Hugging Face Secrets**: You must input all keys inside the Hugging Face Space settings panel. Hugging Face decrypts and injects these secrets as system environment variables inside the running container. They are **never** visible to users browsing your public repository.

### Configuring Your Space Secrets:
Go to your Space's **Settings → Variables and Secrets** and click **Add secret** for each of the following:

| Secret Name | Description / Value |
| :--- | :--- |
| `MISTRAL_API_KEY` | Your Mistral AI API Key (provides dynamic model selection via Mistral Large/Medium/Small) |
| `OPENCLAW_GATEWAY_TOKEN` | A strong, random alphanumeric string to protect API commands |
| `SPACE_URL` | Your Space's public URL: `https://<your-username>-<your-space-name>.hf.space` (Enables Keep-Alive self-pings) |
| `HF_TOKEN` | A private Hugging Face Access Token (Required *only* if your Space is Private, to allow the self-ping bot to bypass the HF auth barrier) |
| `BACKUP_PASSPHRASE` | A custom password to encrypt your database backups using GPG AES-256 (Enables secure backup files) |

---

## 🔑 2. File Exclusions (.gitignore) & Encryption Exceptions

To ensure that your private runtime logs, SQLite databases, and pairing tokens are never pushed to the public git repository, we enforce **two layers of security exception handling**:

### Layer A: Git Exclusions (`.gitignore`)
The `.gitignore` file contains rules to prevent local files inside the running space from being added to the git tree:
* `state/` and `openclaw.db` are explicitly excluded.
* Credentials (`.env`, `*.token`, `*.key`) are explicitly excluded.
* Logs (`*.log`, `logs/`) are explicitly excluded.

### Layer B: GPG AES-256 Encryption (Zero-Trust Backups)
If you want to backup your agent configuration and paired devices so they survive space restarts, you can sync `/app/state-backup.tar.gz.gpg` to your Hugging Face Space dataset or repo. 
* **Encryption**: In `cleanup-history.sh`, the state is compressed and encrypted symmetrically using GPG AES-256 with the `$BACKUP_PASSPHRASE`.
* **Decryption**: In `entrypoint.sh`, the container attempts to decrypt the backup file using the secret passphrase. If decryption fails (e.g., mismatching passphrase), it handles the exception gracefully by booting a fresh state without corrupting the local files.
* **Security**: This encrypted backup is **100% safe to store in a public repository or dataset**, as the files cannot be read without the password stored in your Hugging Face Secrets.

---

## 💤 3. Keep-Alive Mechanism (Anti-Sleep)

By default, Hugging Face free-tier Spaces go to sleep after 48 hours of inactivity. To prevent this:
1. Ensure the `SPACE_URL` (and `HF_TOKEN` if the space is private) is configured in your Space Secrets.
2. The `entrypoint.sh` startup script launches a background loop that sends an HTTP request (`curl`) to your Space's external URL every 25 minutes. Because this request travels outside the container and routes back through the Hugging Face router, Hugging Face detects it as external traffic and keeps the Space warm/active indefinitely.

---

## 🧹 4. Daily History Cleansing (2:00 AM IST)

To ensure privacy and maintain a clean state, a daily cleaning task runs inside the container:
* **Schedule**: Daily at **2:00 AM IST** (which maps to **20:30 UTC**).
* **Action**: Executes `/app/cleanup-history.sh` which:
  1. Deletes cached log files and temporary folders.
  2. Uses `sqlite3` CLI utility to specifically wipe chat histories (`messages` and `conversations` tables) and run a `VACUUM` command to reclaim disk space.
  3. **Preserves the `devices` table** so that your paired iOS companion app is **never** unlinked.
  4. Triggers the GPG-encryption backup script.

---

## 🛠 = 5. Browser & Extensions Setup

The container executes an optimized **Chromium (Playwright)** profile tuned for Hugging Face's **2 vCPUs** limits. It automatically loads:
* **uBlock Origin Lite (Manifest V3)**: Configured in standard/optimal mode. It blocks ads, trackers, and scripts to save CPU overhead.
* **Buster**: An open-source reCAPTCHA/hCAPTCHA audio challenge solver to prevent agent interruption.
* **yt-dlp**: An industry-standard command line utility installed inside the container. Allows OpenClaw to download any video or audio asset from the web directly, without relying on unstable browser interface extensions.

---

## 📤 6. Deployment Steps

```bash
# 1. Clone your Space repository
git clone https://huggingface.co/spaces/YOUR_USERNAME/YOUR_SPACE_NAME
cd YOUR_SPACE_NAME

# 2. Copy the files from your scratch folder here:
# (Dockerfile, nginx.conf, entrypoint.sh, openclaw.json, settings.yml, cleanup-history.sh, .gitignore)

# 3. Commit and push
git add .
git commit -m "Deploy secure OpenClaw with Keep-Alive and MV3 extensions"
git push origin main
```
