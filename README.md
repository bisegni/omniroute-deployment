# OmniRoute + SLAC tunnel

Runs [OmniRoute](https://github.com/diegosouzapw/OmniRoute) as a local model
router in front of two backends:

- **SLAC** — your org's LiteLLM instance at `ai-api.slac.stanford.edu`,
  reached through an SSH tunnel (mirrors the `slac` provider in the main
  `gateway.yaml`).
- **GitHub Copilot** — connected natively through OmniRoute's OAuth flow (no
  extra sidecar needed).

`claude` and `codex` on your laptop then point at this router instead of
talking to providers directly.

## Prerequisites

- Docker + Docker Compose.
- `~/.ssh/config` has a working `Host s3df` entry (same one `gateway.yaml`
  uses for `ssh_tunnel.config_host`), with your key/agent already set up —
  nothing extra to configure there.
- Your SLAC bearer token, i.e. the contents of `~/.bedrock-api-key`.

## 1. Configure

```bash
cd /path/to/9router-deploy
cp .env.example .env
```

If `.env` already exists from the 9router setup, edit it in place instead of
overwriting it. The Compose file temporarily accepts the old
`NINEROUTER_INITIAL_PASSWORD` and `NINEROUTER_JWT_SECRET` names, but the new
`OMNIROUTE_*` names in `.env.example` are recommended. Add independent values
for the API-key, storage-encryption, machine-salt, and WebSocket secrets.

Edit `.env`:

| Variable | What to put |
|---|---|
| `OMNIROUTE_INITIAL_PASSWORD` | A real dashboard password. |
| `OMNIROUTE_PUBLIC_BASE_URL` | URL other machines use, e.g. `http://192.168.1.100:20128` or your HTTPS reverse-proxy URL. |
| `OMNIROUTE_JWT_SECRET` | A long random string, e.g. `openssl rand -hex 32`. |
| `OMNIROUTE_API_KEY_SECRET` | A second long random string used to sign API keys. |
| `OMNIROUTE_STORAGE_ENCRYPTION_KEY` | A long random string used to encrypt the SQLite data at rest. Keep it safe: losing it makes stored credentials unrecoverable. |
| `OMNIROUTE_MACHINE_ID_SALT` | A unique random string for this deployment. |
| `OMNIROUTE_WS_BRIDGE_SECRET` | A long random string for the Responses/WebSocket bridge. |
| `SLAC_API_KEY` | `cat ~/.bedrock-api-key` — paste the contents. |

Generate the five random values with `openssl rand -hex 32`. Do not rotate the
storage-encryption key after the first start unless you have a migration plan.

## 2. Start

```bash
docker compose up -d
docker compose logs -f
```

Check both containers came up:

```bash
docker compose ps
```

If `tunnel` stops, check `docker compose logs tunnel` — usually this means
`s3df` isn't resolvable/reachable from the container, or the mounted `~/.ssh`
doesn't have the right permissions/identity file.

The tunnel is intentionally limited to one initial SSH attempt plus two
retries. After that it stops and requires an explicit `docker compose up -d
tunnel` after you fix the credentials or network problem. This prevents a bad
SSH key/password from repeatedly triggering the remote account's lockout
policy.

## 3. Open the dashboard

<http://<this-host>:20128>

Log in with `OMNIROUTE_INITIAL_PASSWORD`.

The port is published on all host interfaces so other machines can reach it.
This is plain HTTP, so use it only on a trusted network or behind a VPN,
firewall, or HTTPS reverse proxy. Keep `REQUIRE_API_KEY=true`, use a strong
dashboard password, and do not expose port `20128` directly to the public
internet.

For a safer remote-access option, bind the port back to `127.0.0.1` and tunnel
to it over SSH:

```bash
ssh -N -L 20128:127.0.0.1:20128 <this-host>
```

## 4. Add the SLAC provider

`Dashboard → Providers → Add Provider → Custom OpenAI-compatible`

| Field | Value |
|---|---|
| Base URL | `https://ai-api.slac.stanford.edu:8443` |
| API Key | value of `SLAC_API_KEY` (copy from `.env`) |
| TLS verify | on |

The tunnel service has an internal Docker network alias for
`ai-api.slac.stanford.edu`. Use that hostname so the TLS SNI and certificate
match while traffic is still routed to the tunnel container on port `8443`.

## 5. Connect GitHub Copilot

`Dashboard → Providers → GitHub Copilot → OAuth via GitHub`

Follow the device-flow prompt (visit the URL, enter the code). Token is
stored in the `omniroute-data` volume and refreshed automatically. Available
models are exposed with `github/` and `gh/` aliases; use the canonical
`github/` prefix when selecting a model manually.

## 6. Find your model ids

```bash
curl -s http://127.0.0.1:20128/v1/models \
  -H "Authorization: Bearer <api-key-from-dashboard>" | jq -r '.data[].id'
```

This lists every model across every connected provider (SLAC + Copilot),
in OpenAI format — use these ids in the launch scripts below.

## 7. Launch agents against it

Create an API key: `Dashboard → API Keys → Create`.

```bash
export OMNIROUTE_URL=http://127.0.0.1:20128
export OMNIROUTE_API_KEY=<api-key-from-dashboard>

# Configure Claude Code, Codex, or another client with:
#   OpenAI-compatible base URL: $OMNIROUTE_URL/v1
#   API key:                    $OMNIROUTE_API_KEY
#   Model:                      one of the ids returned by /v1/models
```

Swap `github/...` for whatever id you actually got from step 6 — the values
here are placeholders.

To start Claude Code with the GitHub Copilot Claude tiers selected from the
live OmniRoute model catalog:

```bash
chmod +x ./start-claude-omniroute.sh
./start-claude-omniroute.sh
```

The script reads `OMNIROUTE_API_KEY` from the shell or
`~/.omniroute/.env`, fetches `/v1/models`, prefers canonical `github/` Claude
models over the `gh/` aliases for Opus, Sonnet, and Haiku, then exports the three
`ANTHROPIC_DEFAULT_*_MODEL` variables before launching `claude`.

Override an automatically selected tier when needed:

```bash
ANTHROPIC_DEFAULT_OPUS_MODEL=github/claude-opus-4.7 \
  ./start-claude-omniroute.sh
```

To start Codex with OmniRoute injected through temporary `-c` overrides:

```bash
./start-codex-omniroute.sh --model gpt-5.5
```

The Codex script does not modify `~/.codex/config.toml`. It fetches and
validates the live `/v1/models` catalog, then injects the OmniRoute provider
and Responses API settings for that process only. List available models with:

```bash
./start-codex-omniroute.sh --list-models
```

You can also set `CODEX_MODEL=<model-id>` instead of passing `--model`.

## Build the unreleased OmniRoute 3.8.51 image locally

The `3.8.51` npm and Docker artifacts are not published yet, but the source
branch is available. Build the official `runner-base` image locally for Apple
Silicon with:

```bash
chmod +x ./build-omniroute-3.8.51.sh
./build-omniroute-3.8.51.sh
```

The script updates `OMNIROUTE_VERSION=3.8.51-local` in `.env` automatically.
The default source branch is `release/v3.8.51`; select another branch when
needed with `--branch`:

```bash
./build-omniroute-3.8.51.sh --branch release/v3.9.0
```

After the build completes, start only OmniRoute when ready:

```bash
docker compose up -d --no-deps --force-recreate omniroute
```

The build script downloads the source into a temporary directory, uses the
upstream Dockerfile, loads the image into local Docker, and removes the source
directory afterward. It does not start Compose.

## Operations

```bash
docker compose stop            # stop, keep data
docker compose up -d           # start again
docker compose down            # stop and remove containers (keeps volumes)
docker compose down --volumes  # also wipe omniroute-data and its SQLite db — irreversible
docker compose pull            # pull the configured OmniRoute image before recreating
```

On macOS, Docker may fail before starting with `error getting credentials` if
the login Keychain is locked. Unlock the login Keychain or sign in to Docker
Desktop, then retry `docker compose pull` and `docker compose up -d`.

## OmniRoute vs 9router

The similar UI is expected: OmniRoute started as a 9router fork and keeps the
same local dashboard + OpenAI-compatible gateway model.

| Area | 9router | OmniRoute |
|---|---|---|
| Core gateway | Local dashboard, OAuth providers, format translation, quotas, RTK compression, and fallback | Same core model, expanded and rewritten |
| Provider breadth | About 40 providers / 100+ models | 350+ providers / 1,200+ model ids, depending on the release |
| Routing | Tiered fallback and custom combos | `auto` routing plus 19 strategies such as quota headroom, cost, latency, round-robin, fusion, and pipeline |
| Token efficiency | RTK tool-output compression | RTK plus additional compression modes such as Caveman and other engines |
| Agent protocols | HTTP gateway | HTTP gateway plus built-in MCP and A2A support |
| Operations | Basic fallback and quota tracking | Circuit breakers, cooldowns, richer quota telemetry, usage/cost analytics, and guardrails |

The most important practical upgrade for this deployment is quota-aware
automatic routing: use `auto`, `auto/coding`, or a custom combo and OmniRoute
can choose another healthy provider with headroom when a model is rate-limited
or its quota is exhausted. You keep the same client endpoint, but no longer
need to manually switch model ids as often.

The trade-off is operational complexity: OmniRoute has more providers and
features, so keep its image version and encryption key stable, and review
provider terms before routing organization or Copilot traffic through it.
