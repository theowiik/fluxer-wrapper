# Run `make` for the list of commands.

-include .env
FLUXER_DIR ?= /opt/fluxer

COMPOSE := docker compose
# Runs commands against Fluxer's own stack from inside the init image, so the host
# needs nothing but Docker (and no access to FLUXER_DIR, which is root-owned).
FLUXER  := $(COMPOSE) run --rm --no-deps --entrypoint docker init compose
FLUXER_SH := $(COMPOSE) run --rm --no-deps -T --entrypoint sh init -c
JQ      := docker run --rm -i ghcr.io/jqlang/jq -r --unbuffered
ROW     := [(.ts|floor|todate), .request.client_ip, .status, .request.method, .request.uri] | @tsv
S       ?=

.DEFAULT_GOAL := help
.PHONY: help up down restart ps logs logs-fluxer access errors top-ips \
        alerts bans ban unban public lan-only health update rollback \
        update-proxy backup

help: ## Show this help
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | \
	  awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

## ---- lifecycle
up: ## Start everything (installs Fluxer on first run)
	$(COMPOSE) up -d --build
	@echo "Fluxer install/start output: make logs S=init"

down: ## Stop the proxy stack and Fluxer
	$(COMPOSE) down
	$(FLUXER) down

restart: ## Restart everything, or one service: make restart S=api
ifeq ($(S),)
	$(FLUXER) restart
	$(COMPOSE) restart caddy crowdsec
else
	@if $(COMPOSE) config --services | grep -qx '$(S)'; then \
	  $(COMPOSE) restart $(S); else $(FLUXER) restart $(S); fi
endif

ps: ## Show container status for both stacks
	$(COMPOSE) ps
	$(FLUXER) ps

health: ## Probe Fluxer's health endpoints through the edge
	@for p in /_health /api/_health /gateway/_health /media/_health /.well-known/fluxer /; do \
	  printf '%s %s\n' "$$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080$$p)" "$$p"; \
	done

## ---- logs
logs: ## Follow proxy stack logs: make logs [S=caddy|crowdsec|init]
	$(COMPOSE) logs -f --tail=100 $(S)

logs-fluxer: ## Follow Fluxer logs: make logs-fluxer [S=api|gateway|livekit|...]
	$(FLUXER) logs -f --tail=100 $(S)

access: ## Follow HTTP requests (time, ip, status, method, path)
	@$(COMPOSE) exec -T caddy tail -n 50 -F /var/log/caddy/access.log | $(JQ) '$(ROW)'

errors: ## Follow only 4xx/5xx requests
	@$(COMPOSE) exec -T caddy tail -n 200 -F /var/log/caddy/access.log | $(JQ) 'select(.status >= 400) | $(ROW)'

top-ips: ## Top 20 client IPs in the current access log
	@$(COMPOSE) exec -T caddy cat /var/log/caddy/access.log | $(JQ) '.request.client_ip' | sort | uniq -c | sort -rn | head -20

## ---- bans
alerts: ## What CrowdSec detected recently
	$(COMPOSE) exec crowdsec cscli alerts list -l 30

bans: ## Active bans
	$(COMPOSE) exec crowdsec cscli decisions list

ban: ## Ban an IP or range: make ban IP=1.2.3.4 [FOR=24h]
	@test -n "$(IP)" || { echo "usage: make ban IP=1.2.3.4 [FOR=24h]"; exit 1; }
	$(COMPOSE) exec crowdsec cscli decisions add $(if $(findstring /,$(IP)),--range,--ip) $(IP) --duration $(or $(FOR),168h) --reason manual

unban: ## Lift a ban: make unban IP=1.2.3.4
	@test -n "$(IP)" || { echo "usage: make unban IP=1.2.3.4"; exit 1; }
	$(COMPOSE) exec crowdsec cscli decisions delete $(if $(findstring /,$(IP)),--range,--ip) $(IP)

## ---- access
public: ## Open the site to everyone
	sed -i 's|^SITE_ALLOW_CIDRS=.*|SITE_ALLOW_CIDRS=0.0.0.0/0 ::/0|' .env
	$(COMPOSE) up -d caddy
	@echo "Site is public."

lan-only: ## Restrict the site to your LAN again
	sed -i 's|^SITE_ALLOW_CIDRS=.*|SITE_ALLOW_CIDRS=private_ranges|' .env
	$(COMPOSE) up -d caddy
	@echo "Site is LAN-only."

## ---- maintenance
update: ## Upgrade Fluxer (official installer: backup, pull, recreate, verify)
	$(COMPOSE) run --rm --no-deps init update

rollback: ## Undo the last Fluxer upgrade
	$(COMPOSE) run --rm --no-deps init rollback

update-proxy: ## Update Caddy and CrowdSec images
	$(COMPOSE) pull crowdsec
	$(COMPOSE) build --pull caddy init
	$(COMPOSE) up -d caddy crowdsec

backup: ## Dump the database to FLUXER_DIR/backups (no downtime)
	$(FLUXER_SH) 'mkdir -p backups && docker compose exec -T postgres pg_dump -U fluxer -d fluxer --format=custom > "backups/fluxer-$$(date -u +%Y%m%dT%H%M%SZ).dump" && ls -lh backups | tail -n 3'
