#!/bin/sh
# Installs Fluxer on first run, starts it on later runs.
#   docker compose run --rm init update     upgrade Fluxer
#   docker compose run --rm init rollback   undo the last upgrade
set -eu
cd "$FLUXER_DIR"

fetch_installer() {
  curl -fsSLO https://fluxer.dev/install.sh
  curl -fsSLO https://fluxer.dev/install.sh.sha256
  sha256sum -c install.sh.sha256
}

installed() { [ -f .env ] && grep -q '^FLUXER_' .env; }

# On a slow first boot a service can still be starting when compose's health
# wait gives up. Everything is in place by then, so starting again finishes it.
start_stack() {
  for attempt in 1 2 3; do
    docker compose up -d && return 0
    echo "Fluxer not fully up yet (attempt $attempt/3), retrying in 15s."
    sleep 15
  done
  return 1
}

case "${1:-up}" in
  update)   fetch_installer; exec sh install.sh --update --non-interactive --allow-root --dir "$FLUXER_DIR" ;;
  rollback) exec sh install.sh --rollback --non-interactive --allow-root --dir "$FLUXER_DIR" ;;
esac

if installed; then
  echo "Fluxer already installed in $FLUXER_DIR, making sure it's running."
  start_stack
  exit
fi

echo "Installing Fluxer for $FLUXER_DOMAIN into $FLUXER_DIR (proxy mode)."
fetch_installer
# --allow-root: this container runs as root and the installer refuses otherwise.
rc=0
sh install.sh \
  --domain "$FLUXER_DOMAIN" \
  --email "$ACME_EMAIL" \
  --tls proxy \
  --edge-bind 127.0.0.1:8080 \
  --dir "$FLUXER_DIR" \
  --non-interactive \
  --allow-root || rc=$?

# Exit 6 means everything was written but the stack didn't come up in time.
if [ "$rc" -eq 6 ]; then
  start_stack
elif [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
