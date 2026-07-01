---
title: OpenClaw Gateway
emoji: 🦀
colorFrom: indigo
colorTo: blue
sdk: docker
pinned: false
---

# OpenClaw Gateway (Hugging Face Space)

This Space runs a personal [OpenClaw](https://openclaw.ai) Gateway with browser
automation enabled, fronted by Nginx. Because OpenClaw is a single-operator
assistant with shell/file/browser access, **anyone who can log in has full
control of it** — treat access to this Space like you'd treat access to your
own computer.

## Required setup

Set these in your Space's **Settings → Variables and secrets** before relying
on this deployment. Nothing below is optional if you want it actually secure.

| Name | Required | Purpose |
|---|---|---|
| `MISTRAL_API_KEY` | Yes | Model provider key used by the agent. |
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Long random secret. Gateway auth **fails closed** without it, meaning every connection — including yours — gets refused until it's set. Generate one with `openssl rand -hex 32` on any machine. |
| `BASIC_AUTH_USER` / `BASIC_AUTH_PASS` | Strongly recommended | Outer login checked by Nginx before a request ever reaches OpenClaw. If unset, a random one-time login is generated on every restart and printed once to the Space's **Logs** tab — check there if you're locked out. |
| `SPACE_URL` | Optional | Your Space's `https://…hf.space` URL, used only for the keep-alive self-ping so the free-tier Space doesn't sleep. |
| `BACKUP_PASSPHRASE` | Optional | Enables nightly GPG-encrypted state backups. Without it, restarts lose chat history/session state. |
| `OPENCLAW_AUTO_APPROVE_FIRST_PAIRING` | Optional, off by default | See "Pairing a new device" below. Leave unset unless you're actively pairing. |

## Pairing a new device

The first time you open the Control UI from a new browser, OpenClaw requires
a one-time pairing approval — this is intentional, and is what stops a
stranger who finds this URL from getting in even if they somehow had your
token. Normally you'd approve it with `openclaw devices approve <id>` on the
machine running the Gateway.

Standard Hugging Face Docker Spaces don't give you a shell inside the running
container, so to approve your *own* connections:

1. Set `OPENCLAW_AUTO_APPROVE_FIRST_PAIRING=true` as a Space secret (this
   restarts the Space).
2. Open the Space and connect (enter your `OPENCLAW_GATEWAY_TOKEN` when
   prompted). This isn't time-boxed — pair whichever of your own devices you
   need to in this session, no clock to race.
3. Set `OPENCLAW_AUTO_APPROVE_FIRST_PAIRING` back to `false` (or delete it)
   so the Space restarts again with it off.

Leave it `false` the rest of the time — while it's `true`, anyone else who
reaches the pairing screen gets approved too. The Space's **Logs** tab prints
a reminder roughly every 10 minutes while auto-approval is active, so it's
hard to forget it's still on.

## Security model

Two independent login layers, in order:

1. **Nginx Basic Auth** (`BASIC_AUTH_USER`/`BASIC_AUTH_PASS`) — the outer gate,
   checked before anything reaches OpenClaw.
2. **OpenClaw Gateway token** (`OPENCLAW_GATEWAY_TOKEN`) plus one-time device
   pairing — OpenClaw's own auth.

See `SECURITY-NOTES.md` in this repo for the full list of issues found in the
previous version of these files and what changed, plus further hardening
ideas. For OpenClaw's own guidance, see their
[security guide](https://docs.openclaw.ai/gateway/security) and
[exposure runbook](https://docs.openclaw.ai/gateway/security/exposure-runbook).

## After deploying

Check the Space's **Logs** tab on first boot for two things:
- A `WARNING: OPENCLAW_GATEWAY_TOKEN is not set` banner (means you still need
  to add that secret).
- The generated Basic Auth credentials, if you didn't set your own.

## Troubleshooting

**"Am I supposed to log in twice?"** Yes, and they're not in conflict — they're
two separate, independent gates, checked in order:

1. **Nginx Basic Auth** (the browser's native login popup) — required to load
   *anything* from this Space at all, including the login screen itself.
2. **OpenClaw's Gateway Token** — pasted into the Control UI's own connect
   form, a completely separate check the Gateway itself makes once your
   browser is already past #1.

Each protects a different layer, the same way a building keycard and your
laptop password aren't "in conflict" even though you use both. Neither one
being present makes the other misbehave.

**Logs full of repeating `no user/password was provided for basic
authentication` for `manifest.webmanifest`, `favicon.svg`, `sw.js`, or
`control-ui-config.json`?** That's a browser quirk, not a misconfiguration —
Chrome/Firefox fetch those specific files through internal codepaths that
don't attach cached Basic Auth credentials, even to an already-authenticated
page. `nginx.conf` exempts exactly those non-sensitive paths from the outer
login so this stops recurring; everything that actually matters (`/`,
`/chat`, the WebSocket) still requires it.

**Logs full of `client closed connection while waiting for request` from an
address like `10.112.183.5`, once a second, forever?** That's Hugging Face's
own infrastructure health-checking the container's port to confirm it's
alive — not a client, not an error, not something to fix. `error_log` is set
to `warn` so this stops cluttering the tab.

**"Device pairing required" after entering the Gateway Token?** That's not
related to Basic Auth or the token at all — it's a third, separate OpenClaw
security gate (device pairing) that's working as intended. See "Pairing a new
device" above; you need `OPENCLAW_AUTO_APPROVE_FIRST_PAIRING=true` for one
session since this container has no CLI access to approve it manually.

**Considered merging the two logins into one (`gateway.auth.mode:
"trusted-proxy"`)?** Yes — OpenClaw supports it, and it would remove the
separate Gateway Token step entirely. Not used here: it requires every
request, including the WebSocket handshake, to carry Basic Auth credentials,
and browsers are documented to attach those to a native WebSocket handshake
unreliably (Firefox in particular). That trade would risk swapping today's
one-time pairing screen for an intermittent, harder-to-diagnose connection
failure — worse, not better. Revisit only if OpenClaw ships a way to satisfy
trusted-proxy identity without gating the WS upgrade itself.