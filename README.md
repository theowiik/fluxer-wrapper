# fluxer-wrapper

A self-hosted [Fluxer](https://docs.fluxer.app/operator/get-started/) instance behind a hardened front door, in one `docker compose up`.

```
internet ─► Caddy :80/:443 ──(CrowdSec bans, allowlists, JSON logs)──► Fluxer edge 127.0.0.1:8080
               │
               └─ access log ─► CrowdSec

internet ─► :7881/tcp, :7882/udp ─► LiveKit (voice media; cannot go through a proxy)
```

- **init** runs Fluxer's official installer on the first start, in proxy mode, so Fluxer only listens on loopback. After that it just makes sure Fluxer is up.
- **Caddy** handles TLS, writes JSON access logs, blocks banned IPs, and enforces the site and `/admin` allowlists.
- **CrowdSec** watches the logs for scanners, brute force and known exploit probes. It also pulls community blocklists.

Requirements: Linux with Docker Engine 24+ and Compose 2.24.4+ (the proxy overlay needs it), 2 vCPU, 8 GB RAM, 20 GB disk. `make` is optional.

## Setup

1. Point a DNS A/AAAA record at your public IP.
2. Forward or open **80/tcp, 443/tcp, 443/udp, 7881/tcp, 7882/udp** to the machine.
3. Clone, configure and start:
   ```bash
   git clone <this repo> fluxer-wrapper && cd fluxer-wrapper
   cp .env.example .env    # set domain, email, and CROWDSEC_BOUNCER_KEY (openssl rand -hex 32)
   make up                 # or: docker compose up -d
   ```
   The first run takes a while: Fluxer's installer pulls its images and waits until they're healthy. Follow it with `make logs S=init`.
4. The site starts **LAN-only**. From your LAN, open `https://<domain>` and register. The first account becomes admin. Save the password: without email configured there's no reset.
5. In `/admin`, go to **Runtime settings** and turn off open registration. Invite people instead.
6. Go public with `make public`. `make lan-only` locks it down again.

Step 4 matters: until setup is finished, anyone who registers can change the instance's configuration.

> Reaching your own domain from inside the LAN relies on your router's hairpin NAT. If you get "Not open yet." from home, your router is presenting your public IP. Add that IP to `SITE_ALLOW_CIDRS` and `ADMIN_ALLOW_CIDRS`.

## Where to run it

Any Linux machine with Docker works: a bare-metal server, a VPS, a VM or an LXC container. The stack behaves identically on all of them. It does not work on Docker Desktop (Mac/Windows), because Caddy uses Linux host networking. The machine must not already be using ports 80/443, or 8080/8081 on loopback.

On a home server, run it in an isolated VM or container. Docker keeps a compromised app from taking over the host, but not from reaching the rest of your home network. **[docs/isolation.md](docs/isolation.md)** walks through the setup with Incus/LXD or Proxmox: port forwarding that keeps visitors' real IPs, plus firewall rules that block the instance from your LAN.

## Day to day

Run `make` to list every command.

| Task | Command |
|---|---|
| Start / stop / status | `make up` / `make down` / `make ps` |
| Restart all, or one service | `make restart` / `make restart S=api` |
| Health check | `make health` |
| Proxy logs / Fluxer logs | `make logs [S=caddy]` / `make logs-fluxer [S=gateway]` |
| Watch requests live | `make access` |
| Only errors / top IPs | `make errors` / `make top-ips` |
| What CrowdSec detected / active bans | `make alerts` / `make bans` |
| Ban (default 7d) / unban | `make ban IP=203.0.113.7 [FOR=24h]` / `make unban IP=203.0.113.7` |
| Open to everyone / back to LAN-only | `make public` / `make lan-only` |
| Database backup | `make backup` |
| Upgrade / roll back Fluxer | `make update` / `make rollback` |
| Update Caddy and CrowdSec | `make update-proxy` |

Fluxer commands run through the `init` image, so you never need to touch the root-owned `FLUXER_DIR`. CrowdSec never bans private/LAN addresses.

## Notes

- Bans are enforced by Caddy, so they cover web traffic. The voice ports only carry media and aren't covered.
- Fluxer's files and secrets live in `FLUXER_DIR` (default `/opt/fluxer`). Back it up. For database and upload backups, see the Fluxer get-started guide.
- The `init` container has access to the Docker socket (root-equivalent) so it can run the installer. It exits as soon as that's done.
- Behind NAT, LiveKit discovers your public IP over STUN (`use_external_ip: true` by default). If voice connects but there's no audio, set `FLUXER_LIVEKIT_NODE_IP=<public ip>` in `FLUXER_DIR/.env` and restart LiveKit.

## Checked against Fluxer's reverse-proxy requirements

| Fluxer requires | Here |
|---|---|
| Terminate TLS, serve HTTPS | Caddy, automatic Let's Encrypt |
| Forward every path to the edge unchanged | `reverse_proxy 127.0.0.1:8080` |
| Pass websocket upgrades (`/gateway`, `/livekit/*`) | Caddy does this by default |
| Replace `X-Forwarded-For` with the real client IP | `header_up X-Forwarded-For {remote_host}`. The edge trusts it because our request reaches it from a private Docker address (`FLUXER_EDGE_TRUSTED_PROXIES=private_ranges`). |
| Allow bodies up to the attachment limit (~512 MB) | `request_body max_size 512MB` |
| Keep idle sockets open for about an hour | Caddy doesn't time out upgraded websocket connections |
| Pass `Sec-Fetch-Site` untouched | Not modified |
| Send no `Content-Security-Policy` | None added |
| Voice media goes direct, not through the proxy | LiveKit publishes 7881/tcp and 7882/udp itself |
| Proxy overlay with `127.0.0.1:8080` edge bind | Installer runs with `--tls proxy --edge-bind 127.0.0.1:8080`, which writes `COMPOSE_FILE` and `FLUXER_EDGE_BIND` |

In proxy mode, the only ports Fluxer publishes are the loopback edge and LiveKit. Postgres, Valkey, search and the rest stay on its internal network.
- Host hardening (SSH keys, a host firewall) is up to you and deliberately not automated here.
