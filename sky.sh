#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  Skyport Auto Installer — Panel + Node (skyportd)
#  OS: Ubuntu 22.04 / 24.04, Debian 13
#
#  Cara kerja: membungkus installer resmi skyportsh/installer,
#  mem-patch check_os agar Ubuntu 22.04 diterima, lalu mengisi
#  jawaban pertanyaan otomatis (FQDN, admin, dll).
# ──────────────────────────────────────────────────────────────
set -euo pipefail

BASE="https://raw.githubusercontent.com/skyportsh/installer/main"
WORK="/tmp/skyport-auto"

if [[ $EUID -ne 0 ]]; then
    echo "Jalankan sebagai root: sudo -i"
    exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release
case "${ID}-${VERSION_ID}" in
    ubuntu-22.04|ubuntu-24.04|debian-13) ;;
    *) echo "OS ${PRETTY_NAME} tidak didukung (Ubuntu 22.04/24.04, Debian 13)."; exit 1 ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq curl >/dev/null 2>&1
fi

# ── Unduh installer resmi + patch OS check ───────────────────
rm -rf "$WORK"
mkdir -p "$WORK/lib"
curl -fsSL "$BASE/install-panel.sh"  -o "$WORK/install-panel.sh"
curl -fsSL "$BASE/install-daemon.sh" -o "$WORK/install-daemon.sh"
curl -fsSL "$BASE/lib/ui.sh"         -o "$WORK/lib/ui.sh"

# Izinkan Ubuntu 22.04 di check_os()
sed -i 's/24\.04) ;;/22.04|24.04) ;;/' "$WORK/lib/ui.sh"
if ! grep -q '22.04|24.04' "$WORK/lib/ui.sh"; then
    echo "Patch OS gagal: struktur ui.sh upstream berubah. Hubungi pembuat skrip."
    exit 1
fi

# shellcheck source=/dev/null
source "$WORK/lib/ui.sh"

# ── Helper ───────────────────────────────────────────────────
FQDN_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'

ask_required() {
    local v=""
    while [[ -z "$v" ]]; do v=$(ask "$1" ""); done
    echo "$v"
}

ask_fqdn() {
    local v=""
    while ! [[ "$v" =~ $FQDN_RE ]]; do
        v=$(ask "$1" "")
        [[ "$v" =~ $FQDN_RE ]] || warn "FQDN tidak valid, contoh: panel.example.com"
    done
    echo "$v"
}

resolve_ip() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}' || true; }

check_dns() {
    local fqdn="$1" ip
    ip=$(resolve_ip "$fqdn")
    if [[ -z "$ip" ]]; then
        warn "$fqdn belum ter-resolve. Buat A record ke ${SERVER_IP:-IP server ini}."
    elif [[ -n "${SERVER_IP:-}" && "$ip" != "$SERVER_IP" ]]; then
        warn "$fqdn mengarah ke $ip, bukan ke server ini ($SERVER_IP)."
    else
        success "DNS $fqdn OK ($ip)"
        return 0
    fi
    ask_yes_no "Lanjut tetap?" "n" || exit 1
}

# ── Pertanyaan ───────────────────────────────────────────────
banner "Auto Installer — Panel + Node                          "
SERVER_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
[[ -n "$SERVER_IP" ]] && info "IP publik server ini: $SERVER_IP"
echo ""

MODE=$(ask_choice "Mau install apa?" \
    "Panel saja" \
    "Node (skyportd) saja" \
    "Panel + Node di server yang sama")

PANEL_FQDN=""; NODE_FQDN=""

step "Domain"
if [[ "$MODE" == "2" ]]; then
    PANEL_FQDN=$(ask_fqdn "FQDN Panel (yang sudah terpasang)")
else
    PANEL_FQDN=$(ask_fqdn "FQDN Panel (mis. panel.example.com)")
    check_dns "$PANEL_FQDN"
fi
if [[ "$MODE" != "1" ]]; then
    NODE_FQDN=$(ask_fqdn "FQDN Node (mis. node1.example.com)")
    check_dns "$NODE_FQDN"
fi

if [[ "$MODE" != "2" ]]; then
    step "Akun admin panel"
    SP_ADMIN_NAME=$(ask "Nama admin" "Admin")
    SP_ADMIN_EMAIL=""
    while [[ ! "$SP_ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
        SP_ADMIN_EMAIL=$(ask "Email admin" "")
    done
    while true; do
        SP_ADMIN_PASS=$(ask_password "Password admin (min. 8 karakter)")
        [[ ${#SP_ADMIN_PASS} -ge 8 ]] || { warn "Password minimal 8 karakter."; continue; }
        P2=$(ask_password "Ulangi password")
        [[ "$SP_ADMIN_PASS" == "$P2" ]] && break
        warn "Password tidak sama."
    done

    step "Database & telemetri"
    SP_DB=$(ask_choice "Database panel" "SQLite (mudah, tanpa setup)" "MySQL / MariaDB (akan ditanya detailnya)")
    if ask_yes_no "Aktifkan telemetri anonim?" "y"; then SP_TELEMETRY="y"; else SP_TELEMETRY="n"; fi
fi

# ── Ringkasan ────────────────────────────────────────────────
step "Ringkasan"
case "$MODE" in
    1) info "Mode:        Panel saja" ;;
    2) info "Mode:        Node saja" ;;
    3) info "Mode:        Panel + Node" ;;
esac
[[ -n "$PANEL_FQDN" ]] && info "Panel:       https://$PANEL_FQDN"
[[ -n "$NODE_FQDN"  ]] && info "Node:        $NODE_FQDN (daemon :2800, SFTP :2022)"
[[ "$MODE" != "2" ]] && info "Admin:       $SP_ADMIN_EMAIL"
echo ""
ask_yes_no "Mulai instalasi?" "y" || { info "Dibatalkan."; exit 0; }

# ── Suntik jawaban otomatis ke ui.sh (hanya untuk run ini) ───
cat >> "$WORK/lib/ui.sh" <<'PRESEED'

# ===== Preseed jawaban dari skyport-auto-install.sh =====
eval "orig_$(declare -f ask)"
eval "orig_$(declare -f ask_password)"
eval "orig_$(declare -f ask_yes_no)"
eval "orig_$(declare -f ask_choice)"

ask() {
    local var=""
    case "$1" in
        "Domain name")                      var=SP_PANEL_FQDN ;;
        "Port to listen on")                var=SP_PORT ;;
        "Admin name")                       var=SP_ADMIN_NAME ;;
        "Admin email")                      var=SP_ADMIN_EMAIL ;;
        "Panel URL")                        var=SP_PANEL_URL ;;
        "Configuration token (from panel)") var=SP_TOKEN ;;
    esac
    if [[ -n "$var" && -n "${!var:-}" ]]; then echo "${!var}"; return 0; fi
    orig_ask "$@"
}

ask_password() {
    if [[ "$1" == "Admin password" && -n "${SP_ADMIN_PASS:-}" ]]; then
        echo "$SP_ADMIN_PASS"; return 0
    fi
    orig_ask_password "$@"
}

ask_yes_no() {
    local var=""
    case "$1" in
        "Set up with a domain name (with SSL)?") var=SP_USE_DOMAIN ;;
        "Enable anonymous telemetry?")           var=SP_TELEMETRY ;;
        "Begin installation?")                   var=SP_YES ;;
        "Install Docker?")                       var=SP_YES ;;
        "Continue with bleeding edge?")          var=SP_YES ;;
        "Configure skyportd now?")               var=SP_CONFIGURE ;;
        "Remove it and start fresh?")            var=SP_REMOVE ;;
    esac
    if [[ -n "$var" && -n "${!var:-}" ]]; then
        if [[ "${!var}" == "y" ]]; then return 0; else return 1; fi
    fi
    orig_ask_yes_no "$@"
}

ask_choice() {
    case "$1" in
        "Which release channel?") echo "${SP_CHANNEL:-1}"; return 0 ;;
        "Database engine")        echo "${SP_DB:-1}"; return 0 ;;
    esac
    orig_ask_choice "$@"
}
# ===== end preseed =====
PRESEED

# ── Install panel ────────────────────────────────────────────
if [[ "$MODE" != "2" ]]; then
    export SP_PANEL_FQDN="$PANEL_FQDN" SP_USE_DOMAIN="y" SP_YES="y" SP_CHANNEL="1"
    export SP_ADMIN_NAME SP_ADMIN_EMAIL SP_ADMIN_PASS SP_DB SP_TELEMETRY
    bash "$WORK/install-panel.sh"
    unset SP_PANEL_FQDN SP_USE_DOMAIN SP_ADMIN_NAME SP_ADMIN_EMAIL SP_ADMIN_PASS SP_DB SP_TELEMETRY
fi

# ── Install node ─────────────────────────────────────────────
if [[ "$MODE" != "1" ]]; then
    step "Buat node di panel"
    info "Buka https://${PANEL_FQDN} lalu login sebagai admin."
    info "1. Locations → buat location (mis. Singapore)"
    info "2. Nodes → buat node dengan isian:"
    info "     FQDN        : ${NODE_FQDN}"
    info "     Daemon Port : 2800"
    info "     SFTP Port   : 2022"
    info "3. Buka detail node → Generate configuration token"
    echo ""
    TOKEN=$(ask "Paste configuration token (kosongkan untuk konfigurasi nanti)" "")

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "UFW aktif, membuka port 2800 dan 2022..."
        ufw allow 2800/tcp >/dev/null
        ufw allow 2022/tcp >/dev/null
        [[ "$MODE" == "3" ]] && { ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; }
    fi

    export SP_YES="y" SP_CHANNEL="1" SP_PANEL_URL="https://${PANEL_FQDN}"
    if [[ -n "$TOKEN" ]]; then
        export SP_TOKEN="$TOKEN" SP_CONFIGURE="y"
    else
        export SP_CONFIGURE="n"
    fi
    bash "$WORK/install-daemon.sh"

    # Binary prebuilt bisa butuh glibc lebih baru dari Ubuntu 22.04
    if ldd /etc/skyportd/skyportd 2>&1 | grep -q "not found"; then
        warn "Binary skyportd tidak kompatibel dengan OS ini (library/glibc kurang)."
        if ask_yes_no "Build skyportd dari source (Rust, beberapa menit)?" "y"; then
            export SP_CHANNEL="2" SP_REMOVE="y"
            bash "$WORK/install-daemon.sh"
        fi
    fi
fi

# ── Selesai ──────────────────────────────────────────────────
step "Selesai"
[[ "$MODE" != "2" ]] && success "Panel : https://${PANEL_FQDN}"
if [[ "$MODE" != "1" ]]; then
    success "Node  : ${NODE_FQDN}"
    info "Cek node : systemctl status skyportd"
    info "Log node : journalctl -u skyportd -f"
    info "Lanjut   : tambah Allocations di detail node, lalu buat server."
fi
info "Log install: ${LOG_FILE}"
echo ""
