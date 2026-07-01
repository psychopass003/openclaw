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
container, so to approve your *own* first connection:

1. Set `OPENCLAW_AUTO_APPROVE_FIRST_PAIRING=true` as a Space secret and restart.
2. Within 10 minutes, open the Space and connect (enter your `OPENCLAW_GATEWAY_TOKEN`
   when prompted).
3. Unset `OPENCLAW_AUTO_APPROVE_FIRST_PAIRING` and restart again.

Leave it unset the rest of the time — while it's `true`, anyone else who
connects during that window gets approved too.

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
