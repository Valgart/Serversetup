#!/bin/bash

# Bei Fehlern, ungesetzten Variablen oder fehlgeschlagenen Pipes abbrechen
set -euo pipefail

# --- Root-Check ---
if [ "$(id -u)" -ne 0 ]; then
    echo "FEHLER: Dieses Skript muss als root ausgeführt werden (sudo)." >&2
    exit 1
fi

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
# btop bevorzugen, Fallback auf htop falls nicht im Repo verfügbar
apt install -y curl wget git btop 2>/dev/null || {
    echo "--> btop nicht verfügbar, installiere htop als Fallback..."
    apt install -y curl wget git htop
}

# --- Funktionen für die optionale Installation ---

install_npm_pm2() {
    echo "=== Installiere NPM und PM2 ==="
    apt install -y npm
    # --unsafe-perm verhindert Berechtigungsprobleme in LXC/Container-Umgebungen
    npm install -g --unsafe-perm pm2
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

    # --- Pfad-Abfrage ---
    echo ""
    echo "Wo soll der Samba-Freigabe-Ordner erstellt werden?"
    echo "  Standard: /shares/Daten"
    read -p "Eigenen Pfad angeben? (j/n): " custom_path_choice </dev/tty
    if [[ "$custom_path_choice" =~ ^[JjYy]$ ]]; then
        read -p "Vollständigen Pfad eingeben (z.B. /mnt/internal/Daten): " SHARE_DIR </dev/tty
        SHARE_DIR=$(echo "$SHARE_DIR" | xargs)
        if [ -z "$SHARE_DIR" ]; then
            echo "Kein Pfad eingegeben. Verwende Standard: /shares/Daten"
            SHARE_DIR="/shares/Daten"
        fi
    else
        SHARE_DIR="/shares/Daten"
    fi
    echo "--> Verwende Freigabe-Pfad: $SHARE_DIR"

    # WSDD Installation via APT versuchen, sonst manuelles Fallback
    echo "--> Installiere und starte WSDD..."
    if apt install -y wsdd 2>/dev/null; then
        systemctl enable wsdd || true
        systemctl restart wsdd || true
    else
        echo "--> APT-Installation von wsdd fehlgeschlagen. Führe manuelles Setup durch..."
        wget -qO /usr/local/bin/wsdd https://raw.githubusercontent.com/christgau/wsdd/master/src/wsdd.py
        chmod +x /usr/local/bin/wsdd

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

    # Ordner erstellen und Rechte setzen
    echo "--> Erstelle Freigabe-Ordner: $SHARE_DIR"
    mkdir -p "$SHARE_DIR"

    # Gruppe erstellen, Ordner zuweisen und Berechtigungen setzen
    groupadd -f smbusers
    chown root:smbusers "$SHARE_DIR"
    chmod 2775 "$SHARE_DIR"

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

    # Dienste aktivieren & starten
    systemctl enable smbd nmbd || true
    systemctl restart smbd nmbd || true

    # Abfrage für Samba-Nutzer
    echo ""
    read -p "Möchtest du jetzt einen Samba-Nutzer anlegen? (j/n): " create_user </dev/tty
    if [[ "$create_user" =~ ^[JjYy]$ ]]; then
        read -p "Gib den gewünschten Benutzernamen ein: " smb_username </dev/tty

        if id "$smb_username" &>/dev/null; then
            echo "Nutzer '$smb_username' existiert bereits im System."
        else
            # /usr/sbin/nologin ist auf Debian/Ubuntu zuverlässig vorhanden
            useradd -m -s /usr/sbin/nologin "$smb_username"
        fi

        usermod -aG smbusers "$smb_username"
        echo "--> Bitte richte das Samba-Passwort für '$smb_username' ein:"
        smbpasswd -a "$smb_username"
        smbpasswd -e "$smb_username"

        chown -R root:smbusers "$SHARE_DIR"
        chmod -R g+rwx "$SHARE_DIR"
        echo "=== Samba-Benutzer '$smb_username' erfolgreich angelegt. ==="
    fi

    # Gewählten Pfad für die Abschlussmeldung merken
    SAMBA_SHARE_DIR="$SHARE_DIR"
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
read -p "Auswahl [1-7]: " choice </dev/tty

# Auswahl bestätigen lassen
case $choice in
    1) choice_label="NPM + PM2" ;;
    2) choice_label="Docker" ;;
    3) choice_label="Samba" ;;
    4) choice_label="NPM + PM2 + Docker" ;;
    5) choice_label="Docker + Samba" ;;
    6) choice_label="NPM + PM2 + Docker + Samba" ;;
    7) choice_label="Keine weiteren Pakete" ;;
    *) choice_label="Ungültige Auswahl" ;;
esac

echo ""
echo "--> Gewählt: $choice_label"
read -p "Fortfahren? (j/n): " confirm </dev/tty
if [[ ! "$confirm" =~ ^[JjYy]$ ]]; then
    echo "Abgebrochen. Bitte Skript erneut starten."
    exit 0
fi

SAMBA_SHARE_DIR=""

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
echo "=========================================="
echo "=== Setup erfolgreich abgeschlossen    ==="
echo "=========================================="
if [ -n "$SAMBA_SHARE_DIR" ]; then
    echo "  Samba-Freigabe:  $SAMBA_SHARE_DIR"
fi
if [ "$REAL_USER" != "root" ]; then
    echo "  Hinweis: Bitte einmal neu einloggen,"
    echo "  damit neue Gruppenrechte für '$REAL_USER' aktiv werden."
fi
echo "=========================================="
