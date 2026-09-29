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

case "${1:-up}" in
  update)   fetch_installer; exec sh install.sh --update --non-interactive --allow-root --dir "$FLUXER_DIR" ;;
  rollback) exec sh install.sh --rollback --non-interactive --allow-root --dir "$FLUXER_DIR" ;;
esac

if installed; then
  echo "Fluxer already installed in $FLUXER_DIR, making sure it's running."
  exec docker compose up -d
fi

echo "Installing Fluxer for $FLUXER_DOMAIN into $FLUXER_DIR (proxy mode)."
fetch_installer
exec sh install.sh \
  --domain "$FLUXER_DOMAIN" \
  --email "$ACME_EMAIL" \
  --tls proxy \
  --edge-bind 127.0.0.1:8080 \
  --dir "$FLUXER_DIR" \
  --non-interactive \
  --allow-root  # this container runs as root; the installer refuses otherwise
