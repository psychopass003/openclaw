# Security & bug audit — johnwick003/openclaw

Reviewed: `Dockerfile`, `entrypoint.sh`, `nginx.conf`, `openclaw.json`, `settings.yml`,
`cleanup-history.sh`, `README.md`, `.gitignore` (fetched from the public Space repo
on huggingface.co). Cross-checked against OpenClaw's own docs at docs.openclaw.ai
(`/gateway/security`, `/gateway/security/exposure-runbook`, `/web/control-ui`).

## Bottom line

The Space's own login/auth config wasn't the main problem — the real issue was
**two things quietly cancelling that auth out**: a background script that rubber-stamped
every device-pairing request, and an Nginx setting that let any visitor claim to be
"localhost." Combined, anyone who found the Space's URL could get full operator
access (shell, browser, files) within seconds, without ever needing your token.
That's almost certainly what surfaced to you as "login errors" or things feeling
insecure — it wasn't that login was broken, it's that it was being bypassed.

---

## Critical

### 1. Device pairing was auto-approved for everyone, forever
**File:** `entrypoint.sh` (section "Device Auto-Approval Daemon")

The script ran a loop every 5 seconds that approved *any* pending device-pairing
request, indefinitely, for the life of the container. OpenClaw's own docs describe
pairing approval as the control that exists specifically "to prevent unauthorized
access" when a new browser/device connects. Auto-approving it removed that control
entirely — anyone who opened the Space's public URL and triggered a pairing request
would be granted full operator access (shell, filesystem, browser, any connected
messaging channels) within seconds, with no human check.

**Fix:** removed the unconditional loop. Replaced with an opt-in, 10-minute,
off-by-default window (`OPENCLAW_AUTO_APPROVE_FIRST_PAIRING=true`) so you still have
a way to approve your own first connection without shell access to the container,
without leaving it running permanently. See README for how to use it.

### 2. Nginx forwarded a spoofable client IP to the Gateway
**File:** `nginx.conf`

```
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

This appends to whatever `X-Forwarded-For` a visitor already sent, instead of
overwriting it. OpenClaw's reverse-proxy docs call this out by name as the
"bad" pattern, because it lets a remote request masquerade as coming from
`127.0.0.1` — the same address OpenClaw treats as an implicitly-trusted local
client for some pairing/auth checks.

**Fix:** now overwrites both headers with Nginx's own view of the connection
(`$remote_addr`), and `openclaw.json` adds `gateway.trustedProxies: ["127.0.0.1"]`
so the Gateway only trusts that header when it genuinely comes from the local
Nginx process, per OpenClaw's documented reverse-proxy setup.

### 3. No login in front of Nginx itself
**File:** `nginx.conf`

Every request to the public `*.hf.space` URL was proxied straight to the Gateway
with no authentication layer of its own. OpenClaw's exposure runbook is explicit
that a public-internet deployment behind a reverse proxy needs "an identity-aware
proxy" that "must authenticate users before forwarding to the Gateway" — i.e., the
Gateway's own auth shouldn't be the *only* gate.

**Fix:** added HTTP Basic Auth at the Nginx layer (`BASIC_AUTH_USER`/`BASIC_AUTH_PASS`
secrets), generated into `/app/state/.htpasswd` by `entrypoint.sh` on every boot. If
those secrets aren't set, a random one-time login is generated and printed to the
Space logs instead of silently leaving the door open.

---

## Should fix

### 4. `allowInsecureAuth: true` left on
**File:** `openclaw.json`

`gateway.controlUi.allowInsecureAuth` is a compatibility flag for loading the
Control UI over plain HTTP on localhost. This Space is already served over HTTPS
by Hugging Face, so it wasn't doing anything useful — but OpenClaw's own
`security audit` tool flags it as a tracked "insecure/dangerous" setting to keep
unset in production. Removed.

### 5. `OPENCLAW_GATEWAY_TOKEN` unset would silently look like a broken login
**File:** `entrypoint.sh` / `openclaw.json`

`openclaw.json` correctly references `${OPENCLAW_GATEWAY_TOKEN}` for the Gateway's
own token auth, but if that secret was never actually added in Space Settings,
OpenClaw fails *closed* — every connection, including yours, gets refused. This is
the safe failure mode, but it looks exactly like "login is broken" from the outside,
with nothing in the old script telling you why.

**Fix:** `entrypoint.sh` now prints an explicit warning to the Space logs on boot if
`OPENCLAW_GATEWAY_TOKEN` is missing. Also made `gateway.auth.mode: "token"` and
`gateway.bind: "loopback"` explicit in `openclaw.json` instead of relying on
defaults.

### 6. GPG backup passphrase was passed on the command line
**Files:** `entrypoint.sh`, `cleanup-history.sh`

`gpg --passphrase "$BACKUP_PASSPHRASE"` puts the plaintext passphrase in the
process list (`ps aux`, `/proc/<pid>/cmdline`), readable by any other process in
the same container — relevant here because the container also runs a real browser,
third-party browser extensions, and yt-dlp/ffmpeg.

**Fix:** both scripts now pipe the passphrase over stdin
(`--passphrase-fd 0 --pinentry-mode loopback`) instead.

### 7. Hardcoded, shared SearXNG secret key
**File:** `settings.yml`

`secret_key: "default-searxng-local-secret-for-openclaw"` was a fixed value baked
into the public repo — every deployment built from this template would share it.
It's used to sign session cookies. Impact is limited since SearXNG is bound to
`127.0.0.1` only and Nginx never exposes it externally, but it's an easy fix.

**Fix:** template now ships a placeholder; `entrypoint.sh` generates a fresh random
key into the file on every boot.

### 8. World-writable config directory
**File:** `Dockerfile`

`chmod -R 777 /app /etc/nginx` made `nginx.conf`, `openclaw.json` (which resolves
your gateway token), and `cleanup-history.sh` sit inside directories any process in
the container could write to — not just the specific folders that actually need
runtime write access. A world-writable *directory* lets a process delete/replace a
file inside it even if the file itself isn't individually writable.

**Fix:** narrowed to only the paths that need runtime writes for Hugging Face's
container user: `/app/state`, `/app/extensions`, and Nginx's log/lib dirs.
`/etc/nginx` and the top-level `/app` no longer get blanket write access.
(Hugging Face's Docker Spaces actually run with a **fixed** UID 1000, not a random
one — see "Further hardening" below for a follow-up you could make later.)

### 9. Unvalidated downloads in the build
**File:** `Dockerfile`

The `curl` calls that fetch yt-dlp and the two browser extensions didn't use
`--fail`, so a GitHub rate-limit or 404 would silently download an HTML error page
instead of the real file, and the build would either produce a broken extension or
fail confusingly at the `unzip` step.

**Fix:** added `-f`/`--fail` so a failed download stops the build with a clear error
instead of continuing with bad data.

---

## Lower priority / hygiene

- **No setup documentation existed.** `README.md` was just the Space metadata
  header. Rewrote it with the required secrets, the pairing workflow, and a link to
  this file.
- **`openclaw@latest` / extensions tracked "latest" with no pinning.** Left as-is —
  this looks intentional (you likely want current OpenClaw versions), but it does
  mean a build today can behave differently from a build next week. Worth knowing,
  not changed.

---

## What I could NOT do

I don't have write access to your Hugging Face repo (no credentials or connector
for it), so I couldn't push these changes directly — the corrected files are
provided for you to upload/commit yourself. I also couldn't run `docker build` or
`openclaw security audit` against the result (no outbound network in my sandbox),
so I verified everything I could offline: shell scripts pass `bash -n`, `openclaw.json`
is valid JSON, `settings.yml` is valid YAML, and `nginx.conf`'s braces balance — but
please watch the Space's **Logs** tab on first boot after deploying, in case
something in the live OpenClaw version behaves differently than documented.

## Further hardening (optional, not applied)

- **Fixed-UID Docker user.** Hugging Face's own Docker Spaces guide recommends
  `RUN useradd -m -u 1000 user` + `USER user` instead of `chmod 777`, since the
  runtime UID is fixed at 1000, not random. This would let you `chown` instead of
  world-write `/app/state`, tightening it further per OpenClaw's own advice to keep
  `~/.openclaw`-equivalent state at `700`/`600`. I didn't make this change myself —
  it touches how every process in the container starts, and I can't build/test the
  image to confirm nothing (Playwright, SearXNG, gpg) breaks under it — but it's a
  reasonable next step if you want to test it yourself.
- **`openclaw security audit`** — if you ever get shell access to the container
  (e.g. via Hugging Face's paid Spaces Dev Mode), run this directly; it checks far
  more than what's reviewable from the repo files alone.
