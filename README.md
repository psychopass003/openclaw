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

## Connecting

Use this Space's own dashboard directly — open `https://<your-space>.hf.space`
in a browser and log in with your Basic Auth credentials, then your
`OPENCLAW_GATEWAY_TOKEN` when the Control UI asks for it. Its origin is
already allowlisted in `openclaw.json` and this path is confirmed working.

If you instead use a separate/third-party "paste in a WebSocket URL + token"
connector page, that page's own origin needs to be added to
`gateway.controlUi.allowedOrigins` in `openclaw.json` first, or the Gateway
will reject the connection with something that looks like a generic
connection failure. See `SECURITY-NOTES.md` item 13.

## Updating OpenClaw

The `Dockerfile` pins an exact OpenClaw npm version rather than `latest`, so
rebuilds are reproducible and don't silently pick up a breaking config-schema
change. To upgrade deliberately:

1. Check the [configuration reference](https://docs.openclaw.ai/gateway/configuration-reference)
   and [changelog](https://github.com/openclaw/openclaw/releases) for the new
   version against the current `openclaw.json`.
2. Bump the version in the `RUN npm install -g openclaw@...` line in `Dockerfile`.
3. Push and watch the Space's **Logs** tab on the next build/boot for schema
   validation errors.

## After deploying

Check the Space's **Logs** tab on first boot for two things:
- A `WARNING: OPENCLAW_GATEWAY_TOKEN is not set` banner (means you still need
  to add that secret).
- The generated Basic Auth credentials, if you didn't set your own.