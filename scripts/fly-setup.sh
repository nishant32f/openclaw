#!/usr/bin/env bash
# Setup script for openclaw Fly.io deployment.
# Installs plugins/extensions on the running Fly machine.
# Usage: ./scripts/fly-setup.sh

set -euo pipefail

APP="pawalker-openclaw"

# Plugins to install globally on the Fly machine.
# Add new packages here as needed.
PACKAGES=(
  clawhub
)

echo "Installing packages on $APP..."
for pkg in "${PACKAGES[@]}"; do
  echo "  -> $pkg"
  fly ssh console -a "$APP" -C "sh -c 'npm i -g $pkg'"
done

echo "Pushing config..."
fly ssh console -a "$APP" -C "sh -c 'cat > /data/openclaw.json'" < openclaw.json
fly ssh console -a "$APP" -C "chown node:node /data/openclaw.json"

echo "Syncing secrets..."
fly secrets import -a "$APP" < .env

echo "Done. Gateway will restart automatically after secrets sync."
