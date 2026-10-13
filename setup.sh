#!/usr/bin/env bash
# =============================================================================
# Ubuntu Server Setup
#
# Interaktiv:       sudo ./setup.sh
# Nur Updates:      sudo ./setup.sh --update-only
# Nicht-interaktiv: sudo ./setup.sh --yes --install docker,samba,ufw
#
# Getestet gedacht für Ubuntu 22.04 / 24.04 (VM und LXC).
# =============================================================================

# -E: ERR-Trap auch in Funktionen, -e/-u/-o pipefail: bei Fehlern abbrechen
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/setup.log"
APT_OPTS=(-y -o 'Dpkg::Options::=--force-confdef' -o 'Dpkg::Options::=--force-confold')

# -----------------------------------------------------------------------------
# Argumente
# -----------------------------------------------------------------------------
ASSUME_YES=0
UPDATE_ONLY=0
INSTALL_LIST=""
SAMBA_PATH_ARG=""
SAMBA_USER_ARG=""

usage() {
    cat <<'EOT'
Verwendung: setup.sh [Optionen]

  -y, --yes               Rückfragen automatisch mit "ja" beantworten
      --update-only       Nur apt update/upgrade/autoremove ausführen
      --install LISTE     Komma-getrennt: nodejs,docker,samba,iperf3,fail2ban,ufw,ssh
                          (ssh = SSH-Härtung, ufw = Firewall)
      --samba-path PFAD   Samba-Freigabepfad (Standard: /shares/Daten)
      --samba-user NAME   Samba-Nutzer anlegen (Passwort danach: smbpasswd -a NAME)
  -h, --help              Diese Hilfe
EOT
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)       ASSUME_YES=1 ;;
        --update-only)  UPDATE_ONLY=1 ;;
        --install)      INSTALL_LIST="${2:?--install benötigt eine Liste}"; shift ;;
        --samba-path)   SAMBA_PATH_ARG="${2:?--samba-path benötigt einen Pfad}"; shift ;;
        --samba-user)   SAMBA_USER_ARG="${2:?--samba-user benötigt einen Namen}"; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unbekannte Option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# Root-Check
# -----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "FEHLER: Dieses Skript muss als root ausgeführt werden (sudo)." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Logging – Konsole + Logdatei (Logdatei nur für root lesbar)
# -----------------------------------------------------------------------------
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "=== Skript gestartet: $(date '+%Y-%m-%d %H:%M:%S') ==="

trap 'rc=$?; echo ""; echo "FEHLER: Skript abgebrochen in Zeile $LINENO (Exit-Code: $rc). Siehe $LOG_FILE" >&2' ERR

# -----------------------------------------------------------------------------
# Hilfsfunktionen
# -----------------------------------------------------------------------------
die()  { echo "FEHLER: $*" >&2; exit 1; }
warn() { echo "WARNUNG: $*" >&2; }

# Gibt es ein Terminal für Rückfragen? (auch bei curl | bash)
HAS_TTY=0
if (exec </dev/tty) 2>/dev/null; then HAS_TTY=1; fi

# ask "Prompt" VARNAME [Default]
ask() {
    local prompt=$1 var=$2 default=${3:-} reply=""
    if [ "$HAS_TTY" -eq 1 ]; then
        read -rp "$prompt" reply </dev/tty || true
    fi
    printf -v "$var" '%s' "${reply:-$default}"
}

# confirm "Frage" -> Exit 0 bei "ja"; ohne TTY nur mit --yes
confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "$HAS_TTY" -eq 1 ] || return 1
    local r=""
    read -rp "$1 (j/n): " r </dev/tty || return 1
    [[ "$r" =~ ^[JjYy]$ ]]
}

apt_install() { apt-get install "${APT_OPTS[@]}" "$@"; }

# Normalen User ermitteln (für Docker-Gruppe, PM2, SSH-Check)
REAL_USER=${SUDO_USER:-${USER:-root}}
if [ "$REAL_USER" = "root" ]; then
    REAL_USER=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1; exit}' /etc/passwd)
    REAL_USER=${REAL_USER:-root}
fi
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

check_installed()     { command -v "$1" >/dev/null 2>&1; }
is_node_ready()       { check_installed node && check_installed pm2; }
is_docker_installed() { check_installed docker; }
is_iperf3_installed() { check_installed iperf3; }
is_fail2ban_installed() { check_installed fail2ban-client; }
is_ufw_active()       { check_installed ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }
is_samba_installed()  { [ "$(dpkg-query -W -f='${Status}' samba 2>/dev/null)" = "install ok installed" ]; }
label()               { "$@" && printf ' [bereits installiert]' || true; }

do_update() {
    echo "=== System aktualisieren ==="
    apt-get update
    apt-get "${APT_OPTS[@]}" upgrade
    apt-get -y autoremove
}

reboot_hint() {
    if [ -f /var/run/reboot-required ]; then
        echo ""
        echo ">>> Neustart erforderlich (/var/run/reboot-required vorhanden)."
    fi
}

# -----------------------------------------------------------------------------
# Modus: Update-only oder vollständiges Setup
# -----------------------------------------------------------------------------
if [ "$UPDATE_ONLY" -eq 0 ] && [ -z "$INSTALL_LIST" ] && [ "$HAS_TTY" -eq 1 ]; then
    echo ""
    echo "================================================="
    echo " Was soll das Skript tun?"
    echo "================================================="
    echo "1) Vollständiges Setup (System + optionale Pakete)"
    echo "2) Nur System aktualisieren (apt update + upgrade)"
    echo "================================================="
    ask "Auswahl [1-2]: " mode_choice "1"
    [ "$mode_choice" = "2" ] && UPDATE_ONLY=1
fi

if [ "$UPDATE_ONLY" -eq 1 ]; then
    do_update
    reboot_hint
    echo ""
    echo "=== System erfolgreich aktualisiert: $(date '+%Y-%m-%d %H:%M:%S') ==="
    exit 0
fi

# -----------------------------------------------------------------------------
# Auswahl der Zusatzkomponenten (Mehrfachauswahl, Validierung VOR der Bestätigung)
# -----------------------------------------------------------------------------
declare -A SEL=()
ALL_PACKAGES=(nodejs docker samba iperf3 fail2ban)

parse_selection() {
    local tok item input=${1//,/ }
    for tok in $input; do
        case "${tok,,}" in
            1|nodejs|npm|pm2) item=nodejs ;;
            2|docker)         item=docker ;;
            3|samba)          item=samba ;;
            4|iperf3)         item=iperf3 ;;
            5|fail2ban)       item=fail2ban ;;
            6|ufw)            item=ufw ;;
            7|ssh)            item=ssh ;;
            a|alle|all)       for item in "${ALL_PACKAGES[@]}"; do SEL[$item]=1; done; continue ;;
            0|keine|none)     continue ;;
            *) echo "Ungültige Auswahl: '$tok'" >&2; return 1 ;;
        esac
        SEL[$item]=1
    done
}

if [ -n "$INSTALL_LIST" ]; then
    parse_selection "$INSTALL_LIST" || die "Ungültige Liste für --install."
elif [ "$HAS_TTY" -eq 1 ]; then
    echo ""
    echo "================================================="
    echo " Zusatzkomponenten wählen (Mehrfachauswahl, z.B. '2 3 6')"
    echo "================================================="
    echo "1) Node.js (LTS) + PM2$(label is_node_ready)"
    echo "2) Docker (offizielles apt-Repo)$(label is_docker_installed)"
    echo "3) Samba$(label is_samba_installed)"
    echo "4) iperf3$(label is_iperf3_installed)"
    echo "5) fail2ban$(label is_fail2ban_installed)"
    echo "6) Firewall (ufw)$(label is_ufw_active)"
    echo "7) SSH-Härtung (nur Key-Login, kein Root-Login)"
    echo "a) Alle Pakete (1-5, ohne Firewall/SSH-Härtung)"
    echo "0) Nichts weiter installieren"
    echo "================================================="
    while true; do
        ask "Auswahl: " reply "0"
        if parse_selection "$reply"; then break; fi
        SEL=()
    done
fi

if [ "${#SEL[@]}" -gt 0 ]; then
    echo ""
    echo "--> Gewählt: ${!SEL[*]}"
    confirm "Fortfahren?" || { echo "Abgebrochen. (Ohne Terminal: --yes verwenden.)"; exit 0; }
else
    echo "--> Keine Zusatzkomponenten gewählt."
fi

# =============================================================================
# Basis-Setup
# =============================================================================
do_update

echo "=== Zeitzone auf Europe/Berlin setzen ==="
set_timezone() {
    if [ -d /run/systemd/system ] && timedatectl set-timezone Europe/Berlin 2>/dev/null; then
        return 0
    fi
    # Fallback ohne systemd (z.B. manche Container)
    ln -snf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
    echo "Europe/Berlin" > /etc/timezone
}
apt_install tzdata
set_timezone

echo "=== Basis-Pakete installieren ==="
apt_install curl wget git ca-certificates
apt_install btop || { echo "--> btop nicht verfügbar, installiere htop..."; apt_install htop; }

echo "=== unattended-upgrades konfigurieren ==="
apt_install unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOT

# Drop-in statt Überschreiben der Hauptdatei: Ubuntu-Defaults (Security-Origins)
# bleiben erhalten, eigene Änderungen an 50unattended-upgrades auch.
cat > /etc/apt/apt.conf.d/51local-unattended <<'EOT'
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOT

systemctl enable --now unattended-upgrades || true
echo "--> Security-Updates aktiv, Auto-Reboot 03:00 Uhr (nur wenn niemand eingeloggt ist)"

# =============================================================================
# Installations-Funktionen
# =============================================================================
SAMBA_SHARE_DIR=""
ADDED_TO_DOCKER_GROUP=0

install_nodejs() {
    echo "=== Installiere Node.js (LTS) + PM2 ==="
    if ! check_installed node; then
        local tmp
        tmp=$(mktemp)
        curl -fsSL https://deb.nodesource.com/setup_lts.x -o "$tmp"
        bash "$tmp"
        rm -f "$tmp"
        apt_install nodejs
    else
        echo "--> Node.js bereits vorhanden ($(node --version)), überspringe NodeSource."
    fi

    if ! check_installed pm2; then
        npm install -g pm2
    fi

    echo "--> Richte PM2-Autostart für '$REAL_USER' ein..."
    pm2 startup systemd -u "$REAL_USER" --hp "$REAL_HOME" \
        || warn "pm2 startup fehlgeschlagen – manuell prüfen."
    echo "--> Hinweis: Nach dem Starten deiner Apps als '$REAL_USER' einmal 'pm2 save' ausführen."
}

install_docker() {
    echo "=== Installiere Docker (offizielles apt-Repo) ==="
    if is_docker_installed; then
        echo "--> Docker ist bereits installiert, überspringe..."
        return
    fi

    local codename arch
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")
    [ -n "$codename" ] || die "Konnte Ubuntu-Codename nicht ermitteln."
    arch=$(dpkg --print-architecture)

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker || true

    if [ "$REAL_USER" != "root" ]; then
        usermod -aG docker "$REAL_USER"
        ADDED_TO_DOCKER_GROUP=1
        echo "--> '$REAL_USER' zur Gruppe 'docker' hinzugefügt (Achtung: faktisch root-äquivalent)."
    fi
}

install_iperf3() {
    echo "=== Installiere iperf3 ==="
    apt_install iperf3
}

install_fail2ban() {
    echo "=== Installiere fail2ban ==="
    apt_install fail2ban
    systemctl enable --now fail2ban || true
    echo "--> Ubuntu-Standard: sshd-Jail ist aktiv."
}

install_samba() {
    echo "=== Installiere Samba & wsdd ==="
    apt_install samba

    if apt_install wsdd; then
        systemctl enable --now wsdd || true
    else
        warn "wsdd nicht verfügbar – Windows-Netzwerkumgebung findet den Server evtl. nicht automatisch."
    fi

    # --- Freigabepfad ---
    local SHARE_DIR="${SAMBA_PATH_ARG:-}"
    if [ -z "$SHARE_DIR" ]; then
        ask "Samba-Freigabepfad [/shares/Daten]: " SHARE_DIR "/shares/Daten"
    fi
    SHARE_DIR="${SHARE_DIR%/}"
    [[ "$SHARE_DIR" == /* ]] || die "Samba-Pfad muss absolut sein: '$SHARE_DIR'"
    echo "--> Freigabe-Pfad: $SHARE_DIR"

    # Nur das Top-Level-Verzeichnis anfassen, vorhandene Daten bleiben unberührt
    groupadd -f smbusers
    mkdir -p "$SHARE_DIR"
    chown root:smbusers "$SHARE_DIR"
    chmod 2775 "$SHARE_DIR"

    # --- smb.conf (Backup nur einmalig, Original bleibt erhalten) ---
    local SMB_CONF="/etc/samba/smb.conf"
    if [ -f "$SMB_CONF" ] && [ ! -f "${SMB_CONF}.bak" ]; then
        cp "$SMB_CONF" "${SMB_CONF}.bak"
    fi

    local NB_NAME
    NB_NAME=$(hostname -s | cut -c1-15)

    cat > "$SMB_CONF" <<EOT
# Von setup.sh erzeugt
[global]
   workgroup = WORKGROUP
   server string = Samba Server %v
   netbios name = ${NB_NAME}
   security = user
   map to guest = never
   dns proxy = no

   server signing = mandatory
   server min protocol = SMB3

[Daten]
   path = ${SHARE_DIR}
   browsable = yes
   read only = no
   guest ok = no
   force create mode = 0660
   force directory mode = 0770
   valid users = @smbusers
EOT

    if ! testparm -s "$SMB_CONF" >/dev/null 2>&1; then
        [ -f "${SMB_CONF}.bak" ] && cp "${SMB_CONF}.bak" "$SMB_CONF"
        die "smb.conf ungültig – Original wiederhergestellt."
    fi

    systemctl enable smbd nmbd || true
    systemctl restart smbd nmbd || true

    # --- Samba-Nutzer ---
    local smb_username="${SAMBA_USER_ARG:-}"
    if [ -z "$smb_username" ] && [ "$HAS_TTY" -eq 1 ] && confirm "Jetzt einen Samba-Nutzer anlegen?"; then
        ask "Benutzername: " smb_username ""
    fi

    if [ -n "$smb_username" ]; then
        [[ "$smb_username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Ungültiger Benutzername: '$smb_username'"

        if id "$smb_username" &>/dev/null; then
            echo "--> Nutzer '$smb_username' existiert bereits im System."
        else
            useradd -M -s /usr/sbin/nologin "$smb_username"
        fi
        usermod -aG smbusers "$smb_username"

        if [ "$HAS_TTY" -eq 1 ]; then
            echo "--> Samba-Passwort für '$smb_username' festlegen:"
            smbpasswd -a "$smb_username" </dev/tty
            smbpasswd -e "$smb_username"
            echo "--> Samba-Nutzer '$smb_username' angelegt."
        else
            warn "Kein Terminal: Passwort später setzen mit 'smbpasswd -a $smb_username'."
        fi
    fi

    SAMBA_SHARE_DIR="$SHARE_DIR"
}

harden_ssh() {
    echo "=== SSH-Härtung ==="
    check_installed sshd || { warn "sshd nicht installiert – überspringe."; return 0; }

    if [ "$REAL_USER" = "root" ] || [ ! -s "${REAL_HOME}/.ssh/authorized_keys" ]; then
        warn "Kein normaler User mit ~/.ssh/authorized_keys gefunden – überspringe (Aussperr-Gefahr)."
        return 0
    fi
    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
        warn "sshd_config bindet sshd_config.d nicht ein – überspringe."
        return 0
    fi

    # Dateiname "00-": bei sshd gilt "first match wins", cloud-init legt sonst
    # z.B. 50-cloud-init.conf mit PasswordAuthentication yes an.
    local CONF="/etc/ssh/sshd_config.d/00-hardening.conf"
    cat > "$CONF" <<'EOT'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOT

    mkdir -p /run/sshd
    if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
        echo "--> SSH gehärtet (Key-only, kein Root-Login) für '$REAL_USER'."
        echo "--> WICHTIG: Teste den Login in einer ZWEITEN Sitzung, bevor du diese schließt!"
    else
        rm -f "$CONF"
        die "sshd-Konfiguration ungültig – Härtung zurückgenommen."
    fi
}

setup_ufw() {
    echo "=== Firewall (ufw) einrichten ==="
    apt_install ufw

    local ssh_port
    ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    ssh_port=${ssh_port:-22}

    ufw default deny incoming
    ufw default allow outgoing
    ufw limit "${ssh_port}/tcp"

    if is_samba_installed; then
        ufw allow Samba
        ufw allow 3702/udp   # wsdd
        ufw allow 5357/tcp   # wsdd
    fi
    if is_iperf3_installed; then
        ufw allow 5201/tcp
        ufw allow 5201/udp
    fi

    ufw --force enable
    echo "--> ufw aktiv (SSH-Port ${ssh_port}). Weitere Ports: 'ufw allow <port>/tcp'."
    if is_docker_installed; then
        echo "--> Hinweis: Von Docker veröffentlichte Ports (-p) umgehen ufw!"
    fi
}

# =============================================================================
# Ausführung (feste, sinnvolle Reihenfolge: Pakete -> SSH-Härtung -> Firewall)
# =============================================================================
[ -n "${SEL[nodejs]:-}" ]   && install_nodejs
[ -n "${SEL[docker]:-}" ]   && install_docker
[ -n "${SEL[samba]:-}" ]    && { is_samba_installed && echo "--> Samba bereits installiert, passe Konfiguration an..."; install_samba; }
[ -n "${SEL[iperf3]:-}" ]   && install_iperf3
[ -n "${SEL[fail2ban]:-}" ] && install_fail2ban
[ -n "${SEL[ssh]:-}" ]      && harden_ssh
[ -n "${SEL[ufw]:-}" ]      && setup_ufw

# =============================================================================
# Abschluss
# =============================================================================
echo ""
echo "=========================================="
echo "=== Setup erfolgreich abgeschlossen"
echo "=== $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
[ -n "$SAMBA_SHARE_DIR" ] && echo "  Samba-Freigabe:        $SAMBA_SHARE_DIR"
echo "  Log gespeichert unter: $LOG_FILE"
if [ "$ADDED_TO_DOCKER_GROUP" -eq 1 ]; then
    echo "  Hinweis: Bitte neu einloggen, damit die Docker-Gruppe für '$REAL_USER' aktiv wird."
fi
reboot_hint
echo "=========================================="
