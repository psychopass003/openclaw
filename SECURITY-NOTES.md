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

## Follow-up — 1 Jul 2026: WebSocket "Could not connect" + pairing window

Two changes made after the fixes below were already deployed and running.

### 10. Nginx Basic Auth was also (intermittently) blocking the WebSocket handshake
**File:** `nginx.conf`

The dashboard's live connection to the Gateway is a WebSocket
(`wss://…hf.space`), and `auth_basic` was set at the `server` level, so it
applied to that handshake too. Browsers don't reliably attach cached HTTP
Basic Auth credentials to a `new WebSocket()` connection the way they do to a
normal page load, `<script>` tag, or `fetch()` call — and unlike those, a WS
handshake that comes back with a 401 is not transparently retried with
credentials. It just fails, and the WebSocket spec hides the real HTTP status
from JS, so the only thing the dashboard could report was `disconnected
(1006): no reason`. This lines up with the raw access log from the Space: the
initial page and its JS/CSS assets loaded fine (`200`, user `admin`), but
`manifest.webmanifest`, `favicon.svg`, and `control-ui-config.json` all got
`401 no user/password was provided` in that same browser session — the same
credential-attachment gap, just on request types the browser silently retries
and eventually succeeds on, which a WebSocket handshake doesn't do.

**Fix:** added a `map` on `$http_upgrade` so *only* genuine WebSocket upgrade
requests skip the Nginx Basic Auth check; every normal request still needs
it. The WS channel stays protected by the Gateway's own token auth
(`gateway.auth.mode: "token"`), which this doesn't touch or weaken.

### 11. Device auto-approval window is no longer time-boxed
**File:** `entrypoint.sh`

Previously, turning on `OPENCLAW_AUTO_APPROVE_FIRST_PAIRING` gave exactly 10
minutes from container boot to pair a device, even if the secret was still
`true` — a restart-and-race-the-clock flow every time, including to pair a
second device later on. It now stays active for as long as the secret is
`true`, with a reminder printed to the Logs tab roughly every 10 minutes so
it's hard to forget it's on. Net effect: the window of exposure is now
whatever you leave the secret set for, rather than a hard-capped 10 minutes —
but it's already sitting behind the Basic Auth + WebSocket fix above, matching
the threat model in the Bottom line: anyone who reaches the pairing screen at
all already needed Basic Auth. Still set it back to `false` (and let the
Space restart) once you're done pairing — this trades a fixed timer for
relying on you to flip it off, not for "always on."

---

## Follow-up — 1 Jul 2026 (cont.): repeating 401s, log noise, and "is this two logins conflicting?"

Prompted by a fresh boot log showing the same `manifest.webmanifest` /
`favicon.svg` / `control-ui-config.json` 401s repeating continuously for the
full ~10-minute capture, across three different client IPs, alongside a
"Device pairing required" screen after entering the Gateway Token. Read as
"two logins sending conflicting requests" — worth being precise about, since
they're not actually in conflict.

**Correction to Follow-up #10 above:** that entry assumed the manifest/
favicon/config 401s were "the same credential-attachment gap" as the
WebSocket issue and "eventually succeed on retry," the way other assets do.
The new log disproves the second half of that: across the full capture,
`manifest.webmanifest`, `favicon.svg`, `favicon-32.png`, and
`control-ui-config.json` are 401 on *every single occurrence* — never a 200 —
while `/`, `/chat`, and `/assets/*.js|css` do show the normal 401-then-200
pattern once the browser has a valid credential to attach. The mechanism
diagnosis was right; the "it resolves itself" part wasn't. Fixed below
instead of leaving it as accepted log noise.

### 12. Static/config sub-resources never carry Basic Auth credentials, so they never succeeded
**File:** `nginx.conf`

Confirmed against the boot log: every 401 for `manifest.webmanifest`,
`favicon.svg`, `favicon-32.png`, and `control-ui-config.json` in the capture
— none ever got a 200. This matches long-documented (largely WONTFIX'd)
Chromium/Firefox behavior: the PWA manifest and favicon are fetched through
browser-internal codepaths that don't attach cached HTTP Basic Auth even to
an already-authenticated same-origin realm, and a Service Worker's own
background fetches (update checks, precache) can fire with no page attached
to inherit credentials from. `control-ui-config.json` is fetched by the
Control UI's own JS before the user has entered anything (by design, per
OpenClaw's own docs on how the connect screen bootstraps).

**Fix:** added an exact-match `location` block exempting only these specific
non-sensitive paths (favicons, manifest, `sw.js`, `control-ui-config.json`,
`robots.txt`) from `auth_basic`, via `auth_basic off;`. None of them
authenticate, execute, or return anything sensitive. `/`, `/chat`, and the
WebSocket endpoint are untouched and still require Basic Auth (or, for the
WS upgrade specifically, the Gateway's own token auth per the Follow-up #10
map).

### 13. error_log noise from Hugging Face's own health checks
**File:** `nginx.conf`

The `10.112.183.5 ... client closed connection while waiting for request`
lines repeating once a second for the entire capture are Hugging Face's own
container health-checker opening a raw TCP connection to port 7860 and
closing it without sending a request — not a client, not an error. At
nginx's `info` log level this gets logged every time, along with routine
"client closed keepalive connection" notices, burying the one line per
request that's actually diagnostic.

**Fix:** `error_log` level lowered from `info` to `warn`. Basic Auth failures
are logged by nginx's auth module at `error` severity (above `warn`), so
those still show; `access_log` (the per-request status-code lines) is a
separate stream and unaffected either way.

### 14. Investigated: `gateway.auth.mode: "trusted-proxy"` to merge both logins into one — not applied

OpenClaw supports delegating Gateway auth entirely to an authenticating
reverse proxy via `gateway.auth.mode: "trusted-proxy"`, with identity passed
through a header (e.g. `X-Forwarded-User`, settable here from nginx's
`$remote_user` after a successful Basic Auth check). Per OpenClaw's docs,
this mode also lets Control UI WebSocket sessions connect *without* device
pairing — which would have collapsed this deployment's two logins (Basic
Auth + Gateway Token) and the pairing screen into a single Basic Auth login,
directly addressing the "why two logins" question at the root.

**Not applied**, for one specific reason: trusted-proxy mode requires the
identity header on *every* request reaching the Gateway, including the
WebSocket upgrade itself — meaning the WS handshake would need to carry a
valid Basic Auth `Authorization` header directly, with no fallback. That's
exactly the request type Follow-up #10 above documents browsers as
unreliable at attaching cached Basic Auth credentials to (Firefox
specifically is documented to reuse stale cached credentials across
WebSocket reconnects, causing roughly every other connection attempt to
fail). Switching now would risk trading today's one-time, clearly-labeled
pairing screen for an intermittent, hard-to-diagnose WS connection failure —
a worse failure mode, even though the steady-state UX would be nicer. Left
on `gateway.auth.mode: "token"` (current, working) instead. Revisit if
OpenClaw ships a way to satisfy trusted-proxy identity without gating the WS
upgrade request itself.

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