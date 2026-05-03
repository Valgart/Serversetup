#!/bin/bash

# Bei Fehlern abbrechen
set -e

# Ermitteln, ob ein normaler User existiert (für Docker/Samba Rechte)
REAL_USER=${SUDO_USER:-$USER}
if [ "$REAL_USER" = "root" ]; then
    REAL_USER=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1; exit}' /etc/passwd)
    REAL_USER=${REAL_USER:-root}
fi

echo "=== System aktualisieren ==="
apt update
apt upgrade -y

echo "=== Zeitzone auf Europe/Berlin setzen ==="
ln -snf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
echo "Europe/Berlin" > /etc/timezone

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Europe/Berlin || true
fi

DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata

echo "=== Basis-Pakete installieren ==="
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
    rm -f get-docker.sh

    if [ "$REAL_USER" != "root" ]; then
        echo "=== Füge Nutzer '$REAL_USER' zur Docker-Gruppe hinzu ==="
        usermod -aG docker "$REAL_USER" || true
    fi
}

install_samba() {
    echo "=== Installiere Samba & WSDD ==="
    apt install -y samba
    
    # WSDD Installation via APT versuchen, sonst manuelles Fallback
    echo "--> Installiere und starte WSDD..."
    if apt install -y wsdd 2>/dev/null; then
        systemctl enable wsdd || true
        systemctl restart wsdd || true
    else
        echo "--> APT-Installation von wsdd fehlgeschlagen. Führe manuelles Setup durch..."
        wget -qO /usr/local/bin/wsdd https://raw.githubusercontent.com/christgau/wsdd/master/src/wsdd.py
        chmod +x /usr/local/bin/wsdd
        
        # Systemd Service für wsdd erstellen
        cat <<EOT > /etc/systemd/system/wsdd.service
[Unit]
Description=Web Services Dynamic Discovery Host Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wsdd --shortlog
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT
        systemctl daemon-reload
        systemctl enable wsdd
        systemctl start wsdd
    fi

    # Ordner erstellen
    SHARE_DIR="/shares/Daten"
    echo "--> Erstelle Freigabe-Ordner: $SHARE_DIR"
    mkdir -p "$SHARE_DIR"
    chmod 2775 "$SHARE_DIR"
    chown -R nobody:nogroup "$SHARE_DIR"

    # Samba Konfiguration sichern und neu schreiben
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

    # Dienste aktivieren & starten (Fehler ignorieren, damit Skript weiterläuft)
    systemctl restart smbd nmbd || true
    systemctl enable smbd nmbd || true

    # Abfrage für Samba-Nutzer (Zwingend von /dev/tty lesen!)
    echo ""
    read -p "Möchtest du jetzt einen Samba-Nutzer anlegen? (j/n): " create_user </dev/tty
    if [[ "$create_user" =~ ^[JjYy]$ ]]; then
        read -p "Gib den gewünschten Benutzernamen ein: " smb_username </dev/tty
        
        if id "$smb_username" &>/dev/null; then
            echo "Nutzer '$smb_username' existiert bereits im System."
        else
            useradd -m -s /sbin/nologin "$smb_username"
        fi

        usermod -aG smbusers "$smb_username"
        echo "--> Bitte richte das Samba-Passwort für '$smb_username' ein:"
        # smbpasswd liest nativ aus dem Terminal, das funktioniert problemlos
        smbpasswd -a "$smb_username"
        smbpasswd -e "$smb_username"
        
        chown -R :smbusers "$SHARE_DIR"
        chmod -R g+rwx "$SHARE_DIR"
        echo "=== Samba-Benutzer '$smb_username' erfolgreich angelegt. ==="
    fi
}

# --- Auswahl-Menü ---
# Auch hier wird von /dev/tty gelesen, damit wget das Menü nicht überspringt!
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
read -p "Auswahl [1-7]: " choice </dev/tty

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
    echo "Hinweis: Bitte einmal neu einloggen, damit neue Gruppenrechte für '$REAL_USER' aktiv werden."
fi
