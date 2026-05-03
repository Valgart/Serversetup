#!/bin/bash

# Bei Fehlern abbrechen
set -e

# Ermitteln, ob ein normaler User existiert (für Docker/Samba Rechte)
# Falls man als root via SSH eingeloggt ist, wird geschaut, wer der originale User war.
REAL_USER=${SUDO_USER:-$USER}
if [ "$REAL_USER" = "root" ]; then
    # Falls kein sudo genutzt wurde, nehmen wir den ersten normalen User mit einer UID >= 1000
    REAL_USER=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1; exit}' /etc/passwd)
    # Falls gar kein normaler User existiert, bleibt es bei root
    REAL_USER=${REAL_USER:-root}
fi

echo "=== System aktualisieren ==="
apt update
apt upgrade -y

echo "=== Zeitzone auf Europe/Berlin setzen ==="
# 1. Symlink erzwingen
ln -snf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
echo "Europe/Berlin" > /etc/timezone

# 2. Falls systemd aktiv ist (LXC-Standard), direkt via timedatectl setzen
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Europe/Berlin || true
fi

# 3. tzdata non-interaktiv rekonfigurieren
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata
echo "=== Basis-Pakete installieren ==="
# git und btop werden immer installiert, curl/wget für Downloads benötigt
apt install -y curl wget git btop

# --- Funktionen für die optionale Installation ---

install_npm_pm2() {
    echo "=== Installiere NPM und PM2 ==="
    apt install -y npm
    npm install -g pm2
}

install_docker() {
    echo "=== Installiere Docker ==="
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com -o get-docker.sh
    else
        wget -q https://get.docker.com -O get-docker.sh
    fi
    sh get-docker.sh
    rm get-docker.sh

    if [ "$REAL_USER" != "root" ]; then
        echo "=== Füge Nutzer '$REAL_USER' zur Docker-Gruppe hinzu ==="
        usermod -aG docker "$REAL_USER"
    fi
}

install_samba() {
    echo "=== Installiere Samba & WSDD ==="
    apt install -y samba wsdd
    
    # Ordner erstellen
    SHARE_DIR="/shares/Daten"
    echo "--> Erstelle Freigabe-Ordner: $SHARE_DIR"
    mkdir -p "$SHARE_DIR"
    chmod 2775 "$SHARE_DIR"
    chown -R nobody:nogroup "$SHARE_DIR"

    # Samba Konfiguration sichern und neu schreiben (inkl. Server Signing)
    SMB_CONF="/etc/samba/smb.conf"
    if [ -f "$SMB_CONF" ]; then
        cp "$SMB_CONF" "${SMB_CONF}.bak"
    fi

    echo "--> Erstelle Samba-Konfiguration..."
    cat <<EOT > "$SMB_CONF"
[global]
   workgroup = WORKGROUP
   server string = Samba Server %v
   netbios name = $(hostname)
   security = user
   map to guest = bad user
   dns proxy = no

   # Server Signing erzwingen
   server signing = required
   server min protocol = SMB2

[Daten]
   path = $SHARE_DIR
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   force create mode = 0660
   force directory mode = 0770
   valid users = @smbusers
EOT

    # Gruppe erstellen und Rechte setzen
    groupadd -f smbusers
    chgrp -R smbusers "$SHARE_DIR"

    # Dienste aktivieren & starten
    systemctl restart smbd nmbd wsdd
    systemctl enable smbd nmbd wsdd

    # Abfrage für Samba-Nutzer
    echo ""
    read -p "Möchtest du jetzt einen Samba-Nutzer anlegen? (j/n): " create_user
    if [[ "$create_user" =~ ^[JjYy]$ ]]; then
        read -p "Gib den gewünschten Benutzernamen ein: " smb_username
        
        if id "$smb_username" &>/dev/null; then
            echo "Nutzer '$smb_username' existiert bereits im System."
        else
            useradd -m -s /sbin/nologin "$smb_username"
        fi

        usermod -aG smbusers "$smb_username"
        echo "--> Bitte richte das Samba-Passwort für '$smb_username' ein:"
        smbpasswd -a "$smb_username"
        smbpasswd -e "$smb_username"
        
        chown -R :smbusers "$SHARE_DIR"
        chmod -R g+rwx "$SHARE_DIR"
        echo "=== Samba-Benutzer '$smb_username' erfolgreich angelegt. ==="
    fi
}

# --- Auswahl-Menü ---

echo ""
echo "================================================="
echo " Bitte wähle die Zusatzpakete für die Installation:"
echo "================================================="
echo "1) Nur NPM + PM2"
echo "2) Nur Docker"
echo "3) Nur Samba"
echo "4) NPM + Docker"
echo "5) Docker + Samba"
echo "6) NPM + Docker + Samba"
echo "7) Keine weiteren Pakete installieren"
echo "================================================="
read -p "Auswahl [1-7]: " choice

case $choice in
    1)
        install_npm_pm2
        ;;
    2)
        install_docker
        ;;
    3)
        install_samba
        ;;
    4)
        install_npm_pm2
        install_docker
        ;;
    5)
        install_docker
        install_samba
        ;;
    6)
        install_npm_pm2
        install_docker
        install_samba
        ;;
    7)
        echo "Keine Zusatzpakete ausgewählt."
        ;;
    *)
        echo "Ungültige Auswahl. Überspringe Zusatzinstallationen."
        ;;
esac

echo ""
echo "=== Setup erfolgreich abgeschlossen ==="
if [ "$REAL_USER" != "root" ]; then
    echo "Hinweis: Bitte einmal neu einloggen, damit neue Gruppenrechte (z.B. Docker) für '$REAL_USER' aktiv werden."
fi
