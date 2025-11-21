#!/bin/bash

# Abbruch bei Fehlern
set -e

echo "=== System aktualisieren ==="
apt update
apt upgrade -y

echo "=== Pakete installieren ==="
apt install -y curl git npm

echo "=== PM2 installieren ==="
npm install -g pm2

echo "=== Docker installieren ==="
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

echo "=== User zu Docker-Gruppe hinzufügen ==="
usermod -aG docker "$USER"

echo "=== Gruppe neu laden (nur aktuelle Session) ==="
# newgrp funktioniert in Skripten nicht sinnvoll → Hinweis ausgeben
echo "Du musst dich einmal ab- und wieder anmelden, damit die Docker-Berechtigungen aktiv werden."

echo "=== Setup abgeschlossen ==="
