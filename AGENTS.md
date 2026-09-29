# AGENTS.md

Guidance for AI coding agents working in this repo.

## What this is

A reusable wrapper that runs a self-hosted [Fluxer](https://docs.fluxer.app/operator/get-started/) instance behind Caddy + CrowdSec with one `docker compose up` (or `make up`). It's configuration, not an application: compose files, Caddy config, a small init container, a Makefile and docs.

## Layout

| Path | Role |
|---|---|
| `docker-compose.yml` | Three services: `init` (runs Fluxer's installer), `crowdsec`, `caddy` |
| `init/` | `docker:cli` image + `entrypoint.sh`. Installs Fluxer into `FLUXER_DIR` on the first run; `update` / `rollback` subcommands |
| `caddy/Caddyfile` | Imports `modes/$PROXY_MODE.caddy` |
| `caddy/modes/direct.caddy` | Caddy owns 80/443 and gets certificates itself |
| `caddy/modes/behind.caddy` | Another proxy terminates TLS; plain HTTP on `BEHIND_PORT`, `trusted_proxies` for the client IP |
| `caddy/fluxer.caddy` | Site body shared by both modes: log, body limit, allowlists, CrowdSec, `reverse_proxy` |
| `caddy/Dockerfile` | Caddy built with the `caddy-crowdsec-bouncer` module |
| `crowdsec/acquis.yaml` | Tells CrowdSec to read Caddy's JSON access log |
| `Makefile` | Operator commands (`make` lists them) |
| `docs/isolation.md` | Running the stack in an isolated LXD/Incus/Proxmox instance |

## How it fits together

- Fluxer is **not** vendored. `init` downloads Fluxer's official `install.sh` (checksum-verified) and runs it with `--tls proxy --edge-bind 127.0.0.1:8080 --non-interactive --allow-root`. Fluxer runs as its own compose project (`name: fluxer`) in `FLUXER_DIR`. That directory is bind-mounted at the same path inside `init`, so Fluxer's relative bind mounts resolve on the host.
- Caddy uses `network_mode: host` to see real client IPs and to reach Fluxer's edge (`127.0.0.1:8080`) and CrowdSec's API (`127.0.0.1:8081`).
- Bans are enforced by the Caddy bouncer module, not host iptables, so nothing needs host privileges.
- Fluxer commands in the Makefile go through the `init` image (`$(FLUXER)`), because `FLUXER_DIR` is root-owned.

## Rules

- **Host needs only Docker.** Don't add host dependencies: no apt, ufw, systemd or host scripts in the main flow. Linux-only is fine; distro-specific is not. Host-level advice belongs in `docs/`.
- **Never fork Fluxer's compose files or installer.** Pass flags or `.env` keys instead. Upgrades go through `install.sh --update`.
- **No secrets in the repo.** `.env` is gitignored. Fluxer's secrets live only in `FLUXER_DIR/.env` on the server.
- **Keep both proxy modes working.** Anything added to the site goes in `caddy/fluxer.caddy`. Use `client_ip` (not `remote_ip` / `{remote_host}`) so behind mode sees the visitor, not the proxy.
- **Never trust the leftmost `X-Forwarded-For` entry.** Behind mode keeps `trusted_proxies_strict`; without it a visitor can spoof a LAN IP and bypass the allowlists and bans. Test it with a spoofed header after touching the proxy config.
- **Match Fluxer's reverse-proxy requirements** ([docs](https://docs.fluxer.app/operator/reverse-proxy/)): forward all paths unchanged, websockets, replace `X-Forwarded-For`, bodies ≥ 512 MB, idle sockets for about 1 h, leave `Sec-Fetch-Site` alone, add no CSP. The README table tracks this; update it when you change the proxy.
- **Safe defaults.** The site starts LAN-only (`SITE_ALLOW_CIDRS=private_ranges`), and `/admin` is allowlisted. Don't loosen defaults.
- **Line endings are LF** (`.gitattributes`). Makefile recipes need tabs.
- Match the existing style: short comments that explain *why*, and plain wording in docs.

## Testing

There's no test suite. Useful checks:

- `docker compose config` validates the compose file and interpolation.
- `docker run --rm -v "$PWD/caddy:/etc/caddy" -e PROXY_MODE=behind ... <built caddy image> caddy validate --config /etc/caddy/Caddyfile` checks the Caddy config (set all the env vars the config uses).
- `sh -n init/entrypoint.sh`
- Full test: a throwaway Linux VM with `make up`, then `make health` and `make ps`.
