#!/bin/bash

set -e

echo "=== System aktualisieren ==="
apt update
apt upgrade -y

echo "=== Zeitzone auf Europa/Berlin setzen ==="
# Setzt die Zeitzone non-interaktiv
ln -fs /usr/share/zoneinfo/Europe/Berlin /etc/localtime
echo "Europe/Berlin" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

echo "=== Basis-Pakete installieren ==="
apt install -y curl wget git npm

echo "=== PM2 installieren ==="
npm install -g pm2

echo "=== Docker installieren ==="
if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh
else
    wget -q https://get.docker.com -O get-docker.sh
fi

sh get-docker.sh

echo "=== User zu Docker-Gruppe hinzufügen ==="
usermod -aG docker "$USER"

echo "=== Hinweis: bitte einmal neu einloggen ==="
echo "Docker-Gruppenrechte werden erst nach erneuter Anmeldung aktiv."

echo "=== Setup abgeschlossen ==="
