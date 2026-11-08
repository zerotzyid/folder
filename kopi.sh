#!/usr/bin/env bash
# ==============================================================================
# Espresso Cockpit - Pterodactyl Panel Theme Installer (fixed)
# GitHub : https://github.com/suzirz/pterodactyl-espresso-theme
# Support: Ubuntu 20.04 / 22.04 / 24.04 / 26.04 (dan Debian-based lain)
#
# Perbaikan:
#  - Yarn palsu dari paket apt "cmdtest" (penyebab error "no scenarios" /
#    "no such option: --frozen-lockfile") dihapus, diganti Yarn asli.
#  - Node.js otomatis dipasang/diupgrade (minimal v16, default v20).
#  - NODE_OPTIONS=--openssl-legacy-provider untuk webpack 4 di Node 17+.
#  - Rollback otomatis dari backup jika build gagal.
#  - Tampilan baru (step, spinner, log file).
# ==============================================================================

set -Eeuo pipefail

# ---------- Konfigurasi ----------
PTERO_DIR="${PTERO_DIR:-/var/www/pterodactyl}"
REPO_TARBALL="https://github.com/suzirz/pterodactyl-espresso-theme/archive/refs/heads/main.tar.gz"
NODE_MAJOR_TARGET=20   # default; otomatis dinaikkan sesuai "engines.node" di package.json panel
NODE_MIN_MAJOR=16
LOG_FILE="/tmp/espresso-install-$(date +%Y%m%d_%H%M%S).log"
TOTAL_STEPS=6

# ---------- Warna ----------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_CYAN=$'\033[1;36m'; C_BROWN=$'\033[38;5;137m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BROWN=""
fi

BACKUP_DIR=""
TEMP_DIR=""
STEP=0
BUILD_STARTED=0

# ---------- Helper tampilan ----------
banner() {
  clear 2>/dev/null || true
  echo -e "${C_BROWN}"
  echo "  ┌──────────────────────────────────────────────────────┐"
  echo "  │                                                      │"
  echo "  │   ☕  ESPRESSO COCKPIT  ·  Pterodactyl Theme         │"
  echo "  │        Installer v2 (Ubuntu 20 / 22 / 24 / 26)       │"
  echo "  │                                                      │"
  echo "  └──────────────────────────────────────────────────────┘"
  echo -e "${C_RESET}"
}

step()  { STEP=$((STEP+1)); echo -e "\n${C_CYAN}[${STEP}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()    { echo -e "  ${C_GREEN}✔${C_RESET} $*"; }
info()  { echo -e "  ${C_DIM}•${C_RESET} $*"; }
warn()  { echo -e "  ${C_YELLOW}⚠${C_RESET} $*"; }
fail()  { echo -e "\n  ${C_RED}✘ ERROR:${C_RESET} $*" >&2; echo -e "  ${C_DIM}Log lengkap: ${LOG_FILE}${C_RESET}" >&2; exit 1; }

# Jalankan perintah di background dengan spinner, output ke log
run() {
  local msg="$1"; shift
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  echo -e "\n>>> $msg\n>>> $*" >> "$LOG_FILE"
  "$@" >> "$LOG_FILE" 2>&1 &
  local pid=$!
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r  ${C_CYAN}%s${C_RESET} %s" "${spin:i++%${#spin}:1}" "$msg"
      sleep 0.1
    done
    printf "\r\033[K"
  fi
  if wait "$pid"; then
    ok "$msg"
  else
    echo -e "  ${C_RED}✘${C_RESET} $msg"
    echo -e "${C_DIM}--- 25 baris terakhir log ---${C_RESET}" >&2
    tail -n 25 "$LOG_FILE" >&2
    return 1
  fi
}

# ---------- Cleanup & rollback ----------
cleanup() {
  [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
  return 0
}

on_error() {
  local code=$?
  trap - ERR
  echo -e "\n  ${C_RED}✘ Instalasi gagal (kode $code).${C_RESET}" >&2
  if [ "$BUILD_STARTED" = "1" ] && [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/resources" ]; then
    warn "Mengembalikan file asli dari backup..."
    rm -rf "$PTERO_DIR/resources"
    cp -a "$BACKUP_DIR/resources" "$PTERO_DIR/resources" && ok "Resources dikembalikan ke kondisi semula."
  fi
  echo -e "  ${C_DIM}Log lengkap: ${LOG_FILE}${C_RESET}" >&2
  cleanup
  exit "$code"
}
trap on_error ERR
trap cleanup EXIT

# ---------- Pengecekan awal ----------
banner

[ "${EUID:-$(id -u)}" -eq 0 ] || fail "Jalankan sebagai root (sudo -i)."
: > "$LOG_FILE"

step "Memeriksa sistem"

OS_ID=""; OS_VER=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi

case "$OS_ID" in
  ubuntu)
    case "$OS_VER" in
      20.04|22.04|24.04|26.04) ok "Ubuntu $OS_VER didukung." ;;
      *) warn "Ubuntu $OS_VER tidak ada di daftar resmi (20.04/22.04/24.04/26.04), tetap dilanjutkan." ;;
    esac ;;
  debian) ok "Debian $OS_VER terdeteksi (kompatibel)." ;;
  *) warn "OS '$OS_ID' tidak diuji, tetap dilanjutkan." ;;
esac

[ -d "$PTERO_DIR" ] || fail "Direktori Pterodactyl tidak ditemukan di $PTERO_DIR."
[ -f "$PTERO_DIR/package.json" ] || fail "$PTERO_DIR/package.json tidak ada. Apakah ini panel Pterodactyl?"
ok "Panel ditemukan di $PTERO_DIR"

for bin in curl tar; do
  command -v "$bin" >/dev/null 2>&1 || {
    info "Memasang $bin..."
    run "apt-get install $bin" apt-get install -y "$bin" || fail "Gagal memasang $bin."
  }
done

# ---------- Node.js ----------
step "Memeriksa Node.js"

node_major() { node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'; }

# Baca versi Node minimal dari package.json panel (contoh: ">=22" -> 22)
REQ_MAJOR="$(grep -A3 '"engines"' "$PTERO_DIR/package.json" 2>/dev/null \
  | grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -oE '[0-9]+' | head -n1 || true)"
if [ -n "${REQ_MAJOR:-}" ]; then
  info "Panel meminta Node.js >= ${REQ_MAJOR}."
  if [ "$REQ_MAJOR" -gt "$NODE_MIN_MAJOR" ]; then NODE_MIN_MAJOR="$REQ_MAJOR"; fi
  if [ "$REQ_MAJOR" -gt "$NODE_MAJOR_TARGET" ]; then NODE_MAJOR_TARGET="$REQ_MAJOR"; fi
fi

install_node() {
  export DEBIAN_FRONTEND=noninteractive
  run "apt-get update" apt-get update -y || true
  run "Memasang prasyarat (ca-certificates, gnupg)" apt-get install -y ca-certificates curl gnupg || return 1
  mkdir -p /etc/apt/keyrings
  run "Mengunduh GPG key NodeSource" bash -c \
    "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg" || return 1
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR_TARGET}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  run "apt-get update (NodeSource)" apt-get update -y || return 1
  run "Memasang Node.js ${NODE_MAJOR_TARGET}.x" apt-get install -y nodejs || return 1
}

if ! command -v node >/dev/null 2>&1; then
  warn "Node.js belum terpasang, memasang v${NODE_MAJOR_TARGET}..."
  install_node || fail "Gagal memasang Node.js."
elif [ "$(node_major)" -lt "$NODE_MIN_MAJOR" ]; then
  warn "Node.js $(node -v) terlalu lama (minimal v${NODE_MIN_MAJOR}), upgrade ke v${NODE_MAJOR_TARGET}..."
  install_node || fail "Gagal upgrade Node.js."
fi
hash -r
ok "Node.js $(node -v) siap."

# ---------- Yarn (perbaikan utama) ----------
step "Memeriksa Yarn"

# Yarn yang valid mengeluarkan versi seperti 1.22.22 / 3.x / 4.x.
yarn_ok() {
  command -v yarn >/dev/null 2>&1 || return 1
  local v
  v="$(yarn --version 2>/dev/null | head -n1 || true)"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

if ! yarn_ok; then
  if command -v yarn >/dev/null 2>&1; then
    warn "Binary 'yarn' ($(command -v yarn)) bukan Yarn asli (kemungkinan paket apt 'cmdtest')."
  else
    info "Yarn belum terpasang."
  fi

  if dpkg -s cmdtest >/dev/null 2>&1; then
    run "Menghapus paket 'cmdtest' (yarn palsu)" apt-get remove -y cmdtest || fail "Gagal menghapus cmdtest."
  fi
  if dpkg -s yarn >/dev/null 2>&1 && ! yarn_ok; then
    run "Menghapus paket apt 'yarn' yang rusak" apt-get remove -y yarn || true
  fi
  hash -r

  run "Memasang Yarn asli via npm" npm install -g --force yarn || fail "Gagal memasang Yarn via npm."
  hash -r
fi

yarn_ok || fail "Yarn masih tidak valid setelah perbaikan. Cek: which -a yarn"
ok "Yarn $(yarn --version | head -n1) siap ($(command -v yarn))."

# ---------- Backup ----------
step "Membuat backup"

BACKUP_DIR="$PTERO_DIR/.espresso-theme-backup/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
if [ -d "$PTERO_DIR/resources" ]; then
  cp -a "$PTERO_DIR/resources" "$BACKUP_DIR/"
  ok "Backup disimpan di $BACKUP_DIR"
else
  fail "Folder $PTERO_DIR/resources tidak ada."
fi

# ---------- Ambil & terapkan tema ----------
step "Menerapkan file tema"

SCRIPT_SRC="${BASH_SOURCE[0]:-}"
SOURCE_DIR=""
if [ -n "$SCRIPT_SRC" ] && [ -f "$SCRIPT_SRC" ]; then
  LOCAL_ROOT="$(cd "$(dirname "$SCRIPT_SRC")/.." 2>/dev/null && pwd || true)"
  [ -n "$LOCAL_ROOT" ] && [ -d "$LOCAL_ROOT/resources" ] && SOURCE_DIR="$LOCAL_ROOT/resources"
fi

if [ -z "$SOURCE_DIR" ]; then
  TEMP_DIR="$(mktemp -d /tmp/espresso-theme.XXXXXX)"
  info "Mengunduh tema terbaru dari GitHub..."
  run "Download & ekstrak tema" bash -c \
    "curl -fsSL '$REPO_TARBALL' | tar -xz -C '$TEMP_DIR' --strip-components=1" \
    || fail "Gagal mengunduh tema. Cek koneksi ke github.com."
  SOURCE_DIR="$TEMP_DIR/resources"
fi

[ -d "$SOURCE_DIR" ] || fail "Folder resources tema tidak ditemukan di $SOURCE_DIR."
cp -a "$SOURCE_DIR/." "$PTERO_DIR/resources/"
ok "File tema disalin."

# ---------- Build ----------
step "Build aset production (1-5 menit)"

BUILD_STARTED=1
cd "$PTERO_DIR"

# Webpack 4 (Pterodactyl 1.x) butuh ini di Node >= 17
if [ "$(node_major)" -ge 17 ]; then
  export NODE_OPTIONS="--openssl-legacy-provider ${NODE_OPTIONS:-}"
  info "NODE_OPTIONS=--openssl-legacy-provider diaktifkan (Node $(node -v))."
fi

if [ -f yarn.lock ]; then
  run "yarn install (frozen lockfile)" yarn install --frozen-lockfile \
    || run "yarn install (fallback)" yarn install \
    || fail "yarn install gagal."
else
  run "yarn install" yarn install || fail "yarn install gagal."
fi

if grep -q '"build:production"' package.json; then
  run "yarn build:production" yarn build:production || fail "Build gagal."
else
  fail "Script 'build:production' tidak ada di package.json."
fi
BUILD_STARTED=0

# ---------- Permission & cache ----------
step "Permission & bersihkan cache"

WEB_USER="www-data"
id "$WEB_USER" >/dev/null 2>&1 || WEB_USER="nginx"
id "$WEB_USER" >/dev/null 2>&1 || WEB_USER="apache"

chown -R "$WEB_USER:$WEB_USER" "$PTERO_DIR" 2>/dev/null || warn "chown ke $WEB_USER gagal."
chmod -R 755 "$PTERO_DIR/storage" "$PTERO_DIR/bootstrap/cache" 2>/dev/null || true
ok "Permission diatur ($WEB_USER)."

if command -v php >/dev/null 2>&1; then
  php artisan view:clear   >> "$LOG_FILE" 2>&1 || true
  php artisan config:clear >> "$LOG_FILE" 2>&1 || true
  php artisan cache:clear  >> "$LOG_FILE" 2>&1 || true
  ok "Cache Laravel dibersihkan."
else
  warn "PHP CLI tidak ditemukan, lewati clear cache."
fi

# ---------- Selesai ----------
echo -e "\n${C_GREEN}  ┌──────────────────────────────────────────────────────┐"
echo -e "  │   ✔  Espresso Cockpit berhasil dipasang!             │"
echo -e "  └──────────────────────────────────────────────────────┘${C_RESET}"
echo -e "  ${C_DIM}Refresh browser dengan Ctrl+F5 / Shift+Reload.${C_RESET}"
echo -e "  ${C_DIM}Backup : ${BACKUP_DIR}${C_RESET}"
echo -e "  ${C_DIM}Log    : ${LOG_FILE}${C_RESET}"
echo -e "  ${C_DIM}Uninstall: bash <(curl -s https://raw.githubusercontent.com/suzirz/pterodactyl-espresso-theme/main/scripts/uninstall.sh)${C_RESET}\n"
