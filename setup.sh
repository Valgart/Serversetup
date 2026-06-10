#!/bin/bash

# Bei Fehlern, ungesetzten Variablen oder fehlgeschlagenen Pipes abbrechen
set -euo pipefail

# =============================================================================
# Logging – alle Ausgaben gehen sowohl auf die Konsole als auch in die Logdatei
# =============================================================================
LOG_FILE="/var/log/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "=== Skript gestartet: $(date '+%Y-%m-%d %H:%M:%S') ==="

# =============================================================================
# trap – saubere Fehlermeldung bei unerwartetem Abbruch
# =============================================================================
trap 'echo ""; echo "FEHLER: Skript abgebrochen in Zeile $LINENO (Exit-Code: $?). Siehe $LOG_FILE für Details." >&2' ERR

# =============================================================================
# Root-Check
# =============================================================================
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

# =============================================================================
# Installations-Status prüfen (für Update-Modus und Menü-Anzeige)
# =============================================================================
check_installed() {
    command -v "$1" >/dev/null 2>&1
}

is_npm_installed()    { check_installed npm; }
is_pm2_installed()    { check_installed pm2; }
is_docker_installed() { check_installed docker; }
is_samba_installed()  { dpkg -l samba 2>/dev/null | grep -q '^ii'; }
is_iperf3_installed() { check_installed iperf3; }

# =============================================================================
# Modus-Abfrage: Update-only oder vollständiges Setup
# =============================================================================
echo ""
echo "================================================="
echo " Was soll das Skript tun?"
echo "================================================="
echo "1) Vollständiges Setup (System + optionale Pakete)"
echo "2) Nur System aktualisieren (apt update + upgrade)"
echo "================================================="
read -p "Auswahl [1-2]: " mode_choice </dev/tty

if [[ "$mode_choice" == "2" ]]; then
    echo ""
    echo "=== System aktualisieren ==="
    DEBIAN_FRONTEND=noninteractive apt update
    DEBIAN_FRONTEND=noninteractive apt upgrade -y
    echo ""
    echo "=== System erfolgreich aktualisiert: $(date '+%Y-%m-%d %H:%M:%S') ==="
    exit 0
fi

# =============================================================================
# Ab hier: Vollständiges Setup
# =============================================================================

echo ""
echo "=== System aktualisieren ==="
DEBIAN_FRONTEND=noninteractive apt update
DEBIAN_FRONTEND=noninteractive apt upgrade -y

echo "=== Zeitzone auf Europe/Berlin setzen ==="
ln -snf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
echo "Europe/Berlin" > /etc/timezone

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Europe/Berlin || true
fi

DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata

echo "=== Basis-Pakete installieren ==="
# btop bevorzugen, Fallback auf htop falls nicht im Repo verfügbar
DEBIAN_FRONTEND=noninteractive apt install -y curl wget git btop 2>/dev/null || {
    echo "--> btop nicht verfügbar, installiere htop als Fallback..."
    DEBIAN_FRONTEND=noninteractive apt install -y curl wget git htop
}

# =============================================================================
# unattended-upgrades – immer installieren und konfigurieren
# =============================================================================
echo "=== Installiere und konfiguriere unattended-upgrades ==="
DEBIAN_FRONTEND=noninteractive apt install -y unattended-upgrades apt-listchanges

# Automatische Sicherheitsupdates aktivieren
cat <<'EOT' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOT

# Konfiguration: nur Security-Updates, Reboot nachts um 3 Uhr
cat <<'EOT' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOT

systemctl enable unattended-upgrades || true
systemctl restart unattended-upgrades || true
echo "--> unattended-upgrades konfiguriert (Security-Updates, Auto-Reboot 03:00 Uhr)"

# =============================================================================
# Installations-Funktionen
# =============================================================================

install_npm_pm2() {
    echo "=== Installiere NPM und PM2 ==="
    DEBIAN_FRONTEND=noninteractive apt install -y npm
    # --unsafe-perm verhindert Berechtigungsprobleme in LXC/Container-Umgebungen
    npm install -g --unsafe-perm pm2
}

install_docker() {
    echo "=== Installiere Docker ==="
    if is_docker_installed; then
        echo "--> Docker ist bereits installiert, überspringe..."
        return
    fi
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

install_iperf3() {
    echo "=== Installiere iperf3 ==="
    DEBIAN_FRONTEND=noninteractive apt install -y iperf3
}

install_samba() {
    echo "=== Installiere Samba & WSDD ==="
    DEBIAN_FRONTEND=noninteractive apt install -y samba

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
    if DEBIAN_FRONTEND=noninteractive apt install -y wsdd 2>/dev/null; then
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

# =============================================================================
# Installations-Status ermitteln und Menü aufbauen
# =============================================================================
label_npm=""
label_docker=""
label_samba=""
label_iperf3=""

is_npm_installed    && is_pm2_installed    && label_npm="    [bereits installiert]" || label_npm=""
is_docker_installed                        && label_docker=" [bereits installiert]" || label_docker=""
is_samba_installed                         && label_samba="  [bereits installiert]" || label_samba=""
is_iperf3_installed                        && label_iperf3=" [bereits installiert]" || label_iperf3=""

echo ""
echo "================================================="
echo " Bitte wähle die Zusatzpakete für die Installation:"
echo " (Bereits installierte Pakete werden übersprungen)"
echo "================================================="
echo "1) Nur NPM + PM2          $label_npm"
echo "2) Nur Docker             $label_docker"
echo "3) Nur Samba              $label_samba"
echo "4) Nur iperf3             $label_iperf3"
echo "5) NPM + Docker           $label_npm $label_docker"
echo "6) Docker + Samba         $label_docker $label_samba"
echo "7) NPM + Docker + Samba   $label_npm $label_docker $label_samba"
echo "8) Alles (inkl. iperf3)   $label_npm $label_docker $label_samba $label_iperf3"
echo "9) Keine weiteren Pakete installieren"
echo "================================================="
read -p "Auswahl [1-9]: " choice </dev/tty

# Auswahl bestätigen lassen
case $choice in
    1) choice_label="NPM + PM2" ;;
    2) choice_label="Docker" ;;
    3) choice_label="Samba" ;;
    4) choice_label="iperf3" ;;
    5) choice_label="NPM + PM2 + Docker" ;;
    6) choice_label="Docker + Samba" ;;
    7) choice_label="NPM + PM2 + Docker + Samba" ;;
    8) choice_label="Alles (NPM + PM2 + Docker + Samba + iperf3)" ;;
    9) choice_label="Keine weiteren Pakete" ;;
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

# Bereits installierte Pakete überspringen mit Hinweis
maybe_install_npm_pm2() {
    if is_npm_installed && is_pm2_installed; then
        echo "--> NPM + PM2 bereits installiert, überspringe..."
    else
        install_npm_pm2
    fi
}

maybe_install_samba() {
    if is_samba_installed; then
        echo "--> Samba bereits installiert, überspringe..."
    else
        install_samba
    fi
}

maybe_install_iperf3() {
    if is_iperf3_installed; then
        echo "--> iperf3 bereits installiert, überspringe..."
    else
        install_iperf3
    fi
}

case $choice in
    1) maybe_install_npm_pm2 ;;
    2) install_docker ;;
    3) maybe_install_samba ;;
    4) maybe_install_iperf3 ;;
    5) maybe_install_npm_pm2; install_docker ;;
    6) install_docker; maybe_install_samba ;;
    7) maybe_install_npm_pm2; install_docker; maybe_install_samba ;;
    8) maybe_install_npm_pm2; install_docker; maybe_install_samba; maybe_install_iperf3 ;;
    9) echo "Keine Zusatzpakete ausgewählt." ;;
    *) echo "Ungültige Auswahl. Überspringe Zusatzinstallationen." ;;
esac

# =============================================================================
# Abschlussmeldung
# =============================================================================
echo ""
echo "=========================================="
echo "=== Setup erfolgreich abgeschlossen    ==="
echo "=== $(date '+%Y-%m-%d %H:%M:%S')        ==="
echo "=========================================="
if [ -n "$SAMBA_SHARE_DIR" ]; then
    echo "  Samba-Freigabe:        $SAMBA_SHARE_DIR"
fi
echo "  Log gespeichert unter: $LOG_FILE"
if [ "$REAL_USER" != "root" ]; then
    echo "  Hinweis: Bitte einmal neu einloggen,"
    echo "  damit neue Gruppenrechte für '$REAL_USER' aktiv werden."
fi
echo "=========================================="
