#!/usr/bin/env bash
# =====================================================================
#  SODIUM PANEL AUTO INSTALLER  (TUI edition)
#  Panel : https://github.com/sodiumpanel/panel
#  Daemon: https://github.com/zt3xdv/sodium-reaction
#
#  Interaktif : sudo bash sodium-installer.sh
#  Non-interaktif:
#    sudo bash sodium-installer.sh full
#    sudo bash sodium-installer.sh panel --dev
#    sudo bash sodium-installer.sh addnode --panel-url https://panel.domain.com \
#         --admin-user admin --admin-pass 'RAHASIA' --node-name node-2
# =====================================================================
set -Eeuo pipefail
export LC_ALL="${LC_ALL:-C.UTF-8}" 2>/dev/null || true

# ---------- default ----------
MODE="${1:-}"; [[ $# -gt 0 ]] && shift || true
BASE_DIR="/opt/sodium"; PANEL_DIR="$BASE_DIR/panel"; DAEMON_DIR="$BASE_DIR/reaction"
PANEL_REPO="https://github.com/sodiumpanel/panel.git"
DAEMON_REPO="https://github.com/zt3xdv/sodium-reaction.git"
PANEL_PORT="${PANEL_PORT:-3000}"; PANEL_URL=""; PANEL_PUBLIC=""; PANEL_DOMAIN=""; NODE_SCHEME="http"; SSL_OK=0
ADMIN_USER="${ADMIN_USER:-admin}"; ADMIN_PASS="${ADMIN_PASS:-}"; ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost.local}"
NODE_NAME="${NODE_NAME:-node-$(hostname -s)}"; NODE_FQDN=""
DAEMON_PORT="${DAEMON_PORT:-8080}"; SFTP_PORT="${SFTP_PORT:-2022}"
DEV=0; INTERACTIVE=0
LOG="/var/log/sodium-installer.log"; ROUTES="/tmp/sodium-routes.txt"
TOKEN=""; RESP_BODY=""; RESP_CODE=""; NODE_ID=""; NODE_TOKEN=""; NODE_TOKEN_ID=""; NODE_STATE=""; GEN_PASS=0
STEP_NOW=0; STEP_TOTAL=1
TTY=/dev/tty; [[ -r $TTY ]] || TTY=/dev/stdin

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) DEV=1;;
    --panel-url) PANEL_URL="${2%/}"; shift;;
    --panel-domain) PANEL_DOMAIN="$2"; shift;;
    --admin-user) ADMIN_USER="$2"; shift;;
    --admin-pass) ADMIN_PASS="$2"; shift;;
    --admin-email) ADMIN_EMAIL="$2"; shift;;
    --node-name) NODE_NAME="$2"; shift;;
    --node-fqdn) NODE_FQDN="$2"; shift;;
    --port) PANEL_PORT="$2"; shift;;
    --daemon-port) DAEMON_PORT="$2"; shift;;
    *) echo "Opsi tidak dikenal: $1"; exit 1;;
  esac; shift
done

# =====================================================================
#  TUI
# =====================================================================
W=64
R=$'\e[0m'; B=$'\e[1m'; D=$'\e[2m'
c(){ printf '\e[38;5;%sm' "$1"; }
ACC=$(c 45); OK=$(c 82); ERR=$(c 203); WRN=$(c 221); MUT=$(c 245); PUR=$(c 141)
HIDE=$'\e[?25l'; SHOW=$'\e[?25h'
restore(){ printf '%s' "$SHOW$R"; }
trap restore EXIT

strip(){ sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g'; }
vlen(){ printf '%s' "$1" | strip | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '; }
rep(){ local n=$1 ch=$2 out="" i; for ((i=0;i<n;i++)); do out+="$ch"; done; printf '%s' "$out"; }

banner(){
  clear 2>/dev/null || printf '\e[2J\e[H'
  local cols=(51 45 39 33 27 63) i=0 line
  while IFS= read -r line; do
    printf '  %s%s%s\n' "$B$(c "${cols[$i]}")" "$line" "$R"; i=$((i+1))
  done <<'EOF'
 ____   ___  ____ ___ _   _ __  __
/ ___| / _ \|  _ \_ _| | | |  \/  |
\___ \| | | | | | | || | | | |\/| |
 ___) | |_| | |_| | || |_| | |  | |
|____/ \___/|____/___|\___/|_|  |_|
EOF
  printf '  %s%s%s\n' "$MUT" "Auto Installer  ·  Panel  ·  Node  ·  Multi-VPS" "$R"
  printf '  %s%s%s\n\n' "$D$MUT" "$(rep $((W-2)) '─')" "$R"
}

# kotak: box "Judul" warna baris1 baris2 ...
box(){
  local title=$1 col=$2; shift 2
  local inner=$((W-2)) t="─ $title "
  local tl; tl=$(vlen "$t")
  printf '  %s╭%s%s%s╮%s\n' "$col" "$t" "$(rep $((inner-tl)) '─')" "" "$R"
  local l pad
  for l in "$@"; do
    pad=$((inner-2-$(vlen "$l"))); ((pad<0)) && pad=0
    printf '  %s│%s %s%*s %s│%s\n' "$col" "$R" "$l" "$pad" "" "$col" "$R"
  done
  printf '  %s╰%s╯%s\n' "$col" "$(rep $inner '─')" "$R"
}

log(){ printf '[%s] %s\n' "$(date +%T)" "$*" >>"$LOG"; }
say(){  log "$*"; printf '  %s›%s %s\n' "$ACC" "$R" "$*"; }
ok(){   log "OK $*"; printf '  %s✔%s %s\n' "$OK" "$R" "$*"; }
warn(){ log "WARN $*"; printf '  %s!%s %s%s%s\n' "$WRN" "$R" "$WRN" "$*" "$R"; }
die(){  log "FATAL $*"; printf '\n'; box "GAGAL" "$ERR" "$*" "" "${MUT}Log lengkap: $LOG${R}"; exit 1; }
trap 'die "Error di baris $LINENO (lihat log)."' ERR

# progress bar langkah
step(){
  STEP_NOW=$((STEP_NOW+1))
  local w=24 f=$(( STEP_NOW*24/STEP_TOTAL )) bar
  bar="$ACC$(rep $f '█')$MUT$(rep $((w-f)) '░')$R"
  printf '\n  %s[%s%s]%s %s%d/%d%s  %s%s%s\n' "$MUT" "$R" "$bar" "$MUT" "$B" "$STEP_NOW" "$STEP_TOTAL" "$R" "$B" "$1" "$R"
  log "STEP $STEP_NOW/$STEP_TOTAL $1"
}

SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
# run "pesan" cmd... : jalankan di background dengan spinner, output ke log
run(){
  local msg=$1; shift
  "$@" >>"$LOG" 2>&1 & local pid=$! i=0 t0=$SECONDS
  printf '%s' "$HIDE"
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s %s(%ds)%s\e[K' "$ACC" "${SPIN[i%10]}" "$R" "$msg" "$MUT" $((SECONDS-t0)) "$R"
    i=$((i+1)); sleep 0.1
  done
  if wait "$pid"; then printf '\r  %s✔%s %s %s(%ds)%s\e[K\n' "$OK" "$R" "$msg" "$MUT" $((SECONDS-t0)) "$R"
  else
    printf '\r  %s✘%s %s\e[K\n' "$ERR" "$R" "$msg"; printf '%s' "$SHOW"
    echo; tail -n 12 "$LOG" | sed "s/^/    ${MUT}│ /;s/\$/${R}/"; die "Langkah gagal: $msg"
  fi
  printf '%s' "$SHOW"
}
# poll "pesan" detik cmd... : ulangi cmd tiap 1 dtk dengan spinner (foreground)
poll(){
  local msg=$1 secs=$2; shift 2; local i=0 n
  printf '%s' "$HIDE"
  for ((n=0;n<secs;n++)); do
    if "$@" >/dev/null 2>&1; then printf '\r  %s✔%s %s\e[K\n' "$OK" "$R" "$msg"; printf '%s' "$SHOW"; return 0; fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do printf '\r  %s%s%s %s %s(%ds)%s\e[K' "$ACC" "${SPIN[i%10]}" "$R" "$msg" "$MUT" "$n" "$R"; i=$((i+1)); sleep 0.1; done
  done
  printf '\r  %s✘%s %s\e[K\n' "$ERR" "$R" "$msg"; printf '%s' "$SHOW"; return 1
}

# menu "Judul" opsi... -> MENU_IDX
menu(){
  local title=$1; shift; local opts=("$@") sel=0 n=$# key rest i
  printf '%s' "$HIDE"
  printf '  %s%s%s\n' "$B" "$title" "$R"
  while true; do
    for ((i=0;i<n;i++)); do
      if ((i==sel)); then printf '   %s❯ %s%s%s\e[K\n' "$ACC" "$B" "${opts[i]}" "$R"
      else printf '     %s%s%s\e[K\n' "$MUT" "${opts[i]}" "$R"; fi
    done
    IFS= read -rsn1 key <"$TTY" || true
    if [[ $key == $'\e' ]]; then read -rsn2 -t 0.1 rest <"$TTY" || true; key=$rest; fi
    case "$key" in
      '[A'|k) ((sel=(sel+n-1)%n));;
      '[B'|j) ((sel=(sel+1)%n));;
      ''|$'\n') break;;
      [1-9]) ((key<=n)) && { sel=$((key-1)); break; };;
    esac
    printf '\e[%dA' "$n"
  done
  printf '%s' "$SHOW"; MENU_IDX=$sel
}
# ask "Label" "default" [secret]  -> ASK_RES
ask(){
  local label=$1 def=${2:-} secret=${3:-} v=""
  printf '  %s?%s %s%s%s %s' "$PUR" "$R" "$B" "$label" "$R" "$MUT${def:+[$def] }$R"
  if [[ $secret == secret ]]; then read -rs v <"$TTY" || true; echo; else read -r v <"$TTY" || true; fi
  ASK_RES=${v:-$def}
}

interactive_wizard(){
  INTERACTIVE=1; banner
  menu "Pilih yang ingin dipasang:" \
    "1  Panel + Node (VPS ini)      — paling cepat, node langsung hijau" \
    "2  Panel saja                   — hosting / dev lokal" \
    "3  Node saja (VPS ini)          — daftar ke panel yang sudah ada" \
    "4  Tambah Node dari VPS lain    — jalankan di VPS yang berbeda"
  case $MENU_IDX in 0) MODE=full;; 1) MODE=panel;; 2) MODE=node;; 3) MODE=addnode;; esac
  echo
  if [[ $MODE == full || $MODE == panel ]]; then
    menu "Tipe deployment:" "1  Hosting / Production (systemd, auto-start saat boot)" "2  Dev / Server lokal (npm start)"
    DEV=$MENU_IDX; echo
    ask "Port panel" "$PANEL_PORT"; PANEL_PORT=$ASK_RES
    ask "Domain/FQDN panel (kosong = pakai IP:port)" "$PANEL_DOMAIN"; PANEL_DOMAIN=$ASK_RES
    ask "Username admin" "$ADMIN_USER"; ADMIN_USER=$ASK_RES
    ask "Password admin (kosong = acak)" "" secret; ADMIN_PASS=$ASK_RES
  fi
  if [[ $MODE == node || $MODE == addnode ]]; then
    ask "URL panel (contoh https://panel.domain.com)" "$PANEL_URL"; PANEL_URL=${ASK_RES%/}
    ask "Username admin panel" "$ADMIN_USER"; ADMIN_USER=$ASK_RES
    ask "Password admin panel" "" secret; ADMIN_PASS=$ASK_RES
  fi
  if [[ $MODE != panel ]]; then
    ask "Nama node" "$NODE_NAME"; NODE_NAME=$ASK_RES
    ask "Domain/FQDN node (kosong = pakai IP VPS ini)" "$NODE_FQDN"; NODE_FQDN=$ASK_RES
  fi
  echo
  box "Ringkasan" "$ACC" \
    "Mode       : ${B}$MODE${R}" \
    "Panel port : $PANEL_PORT   ${MUT}(dev=$DEV)${R}" \
    "Panel FQDN : ${PANEL_DOMAIN:-${MUT}(IP:port)${R}}" \
    "Admin      : $ADMIN_USER" \
    "Node       : $NODE_NAME" \
    "Node FQDN  : ${NODE_FQDN:-${MUT}(IP VPS)${R}}" "" "${MUT}Tekan Enter untuk mulai, Ctrl+C untuk batal${R}"
  read -r _ <"$TTY" || true
}

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root: sudo bash $0"; exit 1; }
mkdir -p "$BASE_DIR"; : > "$LOG"
if [[ -z $MODE ]]; then interactive_wizard; else banner; fi

# =====================================================================
#  Sistem
# =====================================================================
detect_pm(){
  if command -v apt-get >/dev/null; then PM=apt
  elif command -v dnf >/dev/null; then PM=dnf
  elif command -v yum >/dev/null; then PM=yum
  else die "Package manager tidak didukung (butuh apt/dnf/yum)"; fi
}
pkg(){ if [[ $PM == apt ]]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"; else "$PM" install -y -q "$@"; fi; }
public_ip(){
  [[ -n ${_PIP:-} ]] && { echo "$_PIP"; return; }
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]') && [[ $ip =~ ^[0-9a-fA-F:.]+$ ]] && break || ip=""
  done
  [[ -n $ip ]] || ip=$(hostname -I | awk '{print $1}')
  _PIP=$ip; echo "$ip"
}
rand(){ head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-20}"; }

do_base(){
  [[ $PM == apt ]] && apt-get update -qq
  pkg curl git jq ca-certificates tar gzip openssl
  if [[ $PM == apt ]]; then pkg build-essential python3; else pkg gcc gcc-c++ make python3; fi
}
do_node(){
  if [[ $PM == apt ]]; then curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  else curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -; fi
  pkg nodejs
}
have_node(){ command -v node >/dev/null && [[ $(node -v | tr -dc '0-9.' | cut -d. -f1) -ge 18 ]]; }
do_docker(){ curl -fsSL https://get.docker.com | sh; systemctl enable --now docker || true; }
do_go(){
  local arch v; arch=$(uname -m); [[ $arch == x86_64 ]] && arch=amd64; [[ $arch == aarch64 ]] && arch=arm64
  v=$(curl -fsS "https://go.dev/VERSION?m=text" | head -1)
  curl -fsSL "https://go.dev/dl/${v}.linux-${arch}.tar.gz" | tar -C /usr/local -xz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
}
open_ports(){
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active; then for p in "$@"; do ufw allow "$p" >>"$LOG" 2>&1 || true; done; fi
  if command -v firewall-cmd >/dev/null; then for p in "$@"; do firewall-cmd --permanent --add-port="$p/tcp" >>"$LOG" 2>&1 || true; done; firewall-cmd --reload >>"$LOG" 2>&1 || true; fi
}
clone(){ if [[ -d "$2/.git" ]]; then git -C "$2" pull --ff-only || true; else git clone --depth 1 "$1" "$2"; fi; }

is_ip(){ [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $1 == *:* ]]; }
dns_ok(){ local ip; ip=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'); [[ -n $ip && $ip == "$(public_ip)" ]]; }
do_web(){ pkg nginx certbot python3-certbot-nginx; systemctl enable --now nginx || true; }
do_certbot(){ pkg certbot; }

# =====================================================================
#  HTTP helper (API asli Sodium Panel)
# =====================================================================
call(){ # METHOD PATH [JSON]
  local m=$1 p=$2 d=${3:-} out
  local a=(-sS -m 40 -X "$m" -H 'Content-Type: application/json' -w $'\n%{http_code}')
  [[ -n $TOKEN ]] && a+=(-H "Authorization: Bearer $TOKEN")
  [[ -n $d ]] && a+=(-d "$d")
  out=$(curl "${a[@]}" "$PANEL_URL$p" 2>/dev/null) || { RESP_CODE=000; RESP_BODY=""; return 1; }
  RESP_CODE=${out##*$'\n'}; RESP_BODY=${out%$'\n'*}
  [[ $RESP_CODE =~ ^2 ]]
}
http_up(){ curl -sS -m 3 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null | grep -qE '^[1-4]'; }
panel_installed(){ curl -fsS -m 5 "$PANEL_URL/api/setup/status" 2>/dev/null | jq -e '.installed == true' >/dev/null; }

# =====================================================================
#  Panel
# =====================================================================
panel_fetch(){ clone "$PANEL_REPO" "$PANEL_DIR"; cd "$PANEL_DIR"; npm install --no-audit --no-fund; npm run build; }

panel_unit(){
  cat >/etc/systemd/system/sodium-panel.service <<EOF
[Unit]
Description=Sodium Panel
After=network.target
[Service]
WorkingDirectory=$PANEL_DIR
Environment=PORT=$PANEL_PORT
ExecStart=$(command -v npm) start
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
panel_run(){ # start / restart
  if [[ $DEV -eq 1 ]]; then
    [[ -f $BASE_DIR/panel.pid ]] && kill -- "-$(cat "$BASE_DIR/panel.pid")" 2>/dev/null || true
    pkill -f "node src/server/index.js" 2>/dev/null || true; sleep 1
    (cd "$PANEL_DIR" && PORT=$PANEL_PORT setsid nohup npm start >"$BASE_DIR/panel.out" 2>&1 & echo $! >"$BASE_DIR/panel.pid")
  else
    panel_unit; systemctl enable sodium-panel >>"$LOG" 2>&1; systemctl restart sodium-panel
  fi
}
panel_start(){
  PANEL_URL="http://127.0.0.1:$PANEL_PORT"
  panel_run
  if [[ $DEV -eq 1 ]]; then ok "Mode DEV: ${B}npm start${R} berjalan di background (log: $BASE_DIR/panel.out)"
  else ok "Service systemd ${B}sodium-panel${R} aktif"; fi
  open_ports "$PANEL_PORT"
  poll "Menunggu panel merespon di port $PANEL_PORT" 90 http_up "$PANEL_URL" || die "Panel tidak merespon. Cek $BASE_DIR/panel.out / journalctl -u sodium-panel"
}

# Domain panel: nginx reverse proxy (+ SSL Let's Encrypt jika DNS mengarah ke VPS ini)
panel_domain_setup(){
  PANEL_PUBLIC="http://$(public_ip):$PANEL_PORT"
  [[ -n $PANEL_DOMAIN ]] || return 0
  [[ $PM == apt ]] || { warn "Reverse proxy otomatis hanya untuk apt; domain panel dilewati"; return 0; }
  run "Memasang nginx + certbot" do_web
  cat >/etc/nginx/sites-available/sodium-panel <<'EOF'
server {
  listen 80;
  server_name __DOMAIN__;
  client_max_body_size 200m;
  location / {
    proxy_pass http://127.0.0.1:__PORT__;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 300s;
  }
}
EOF
  sed -i "s/__DOMAIN__/$PANEL_DOMAIN/;s/__PORT__/$PANEL_PORT/" /etc/nginx/sites-available/sodium-panel
  ln -sf /etc/nginx/sites-available/sodium-panel /etc/nginx/sites-enabled/sodium-panel
  rm -f /etc/nginx/sites-enabled/default
  nginx -t >>"$LOG" 2>&1 && systemctl reload nginx >>"$LOG" 2>&1 || die "Konfigurasi nginx tidak valid (lihat log)"
  open_ports 80 443
  PANEL_PUBLIC="http://$PANEL_DOMAIN"
  if dns_ok "$PANEL_DOMAIN"; then
    if certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect >>"$LOG" 2>&1; then
      PANEL_PUBLIC="https://$PANEL_DOMAIN"; ok "SSL aktif untuk ${B}$PANEL_DOMAIN${R}"
    else warn "Certbot gagal untuk $PANEL_DOMAIN; panel tetap lewat HTTP"; fi
  else
    warn "DNS $PANEL_DOMAIN belum mengarah ke $(public_ip) (atau diproxy Cloudflare). SSL dilewati."
  fi
  ok "Panel via domain: ${B}$PANEL_PUBLIC${R}"
}

setup_panel_admin(){
  if [[ -z $ADMIN_PASS ]]; then ADMIN_PASS=$(rand 16); GEN_PASS=1; fi
  [[ $ADMIN_USER =~ ^[A-Za-z0-9_]{3,20}$ ]] || die "Username admin harus 3-20 karakter (huruf, angka, underscore)"
  [[ ${#ADMIN_PASS} -ge 8 ]] || die "Password admin minimal 8 karakter"
  if panel_installed; then ok "Panel sudah ter-setup sebelumnya (installed=true)"; return; fi
  local body
  body=$(jq -nc --arg url "$PANEL_PUBLIC" --argjson port "$PANEL_PORT" --arg u "$ADMIN_USER" --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASS" \
    '{panel:{name:"Sodium",url:$url,port:$port},database:{type:"file"},redis:{enabled:false},registration:{enabled:true},
      defaults:{servers:999,memory:999999,disk:9999999,cpu:100000,allocations:999,backups:999},
      admin:{username:$u,email:$e,password:$p}}')
  say "Setup panel via API (/api/setup/complete)..."
  call POST /api/setup/complete "$body" || die "Setup gagal ($RESP_CODE): ${RESP_BODY:0:200}"
  ok "Wizard selesai & akun admin ${B}$ADMIN_USER${R} dibuat"
  panel_run
  poll "Memuat ulang panel dengan konfigurasi baru" 90 panel_installed || die "Panel belum 'installed' setelah restart"
}

panel_login(){
  local body; body=$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')
  call POST /api/auth/login "$body" || die "Login gagal ($RESP_CODE): $(echo "$RESP_BODY" | jq -r '.error // empty' 2>/dev/null)"
  TOKEN=$(echo "$RESP_BODY" | jq -r '.token // empty')
  if [[ -z $TOKEN ]]; then
    echo "$RESP_BODY" | jq -e '.requires2FA' >/dev/null 2>&1 && die "Akun admin memakai 2FA email; matikan 2FA dulu lalu ulangi."
    die "Login tidak mengembalikan token."
  fi
  ok "Login admin ${B}$ADMIN_USER${R} berhasil"
}

# =====================================================================
#  Node + Daemon (Sodium Reaction = fork Wings)
# =====================================================================
node_cert(){ # dapatkan SSL untuk FQDN node; set NODE_SCHEME
  NODE_SCHEME=http; SSL_OK=0
  is_ip "$NODE_FQDN" && return 0
  if [[ -f /etc/letsencrypt/live/$NODE_FQDN/fullchain.pem ]]; then NODE_SCHEME=https; SSL_OK=1; ok "Memakai sertifikat SSL yang sudah ada untuk $NODE_FQDN"; return 0; fi
  if ! dns_ok "$NODE_FQDN"; then warn "DNS $NODE_FQDN belum mengarah ke $(public_ip) (atau diproxy Cloudflare) → node pakai HTTP"; return 0; fi
  [[ $PM == apt ]] || { warn "SSL otomatis hanya untuk apt → node pakai HTTP"; return 0; }
  run "Memasang certbot" do_certbot
  if certbot certonly --standalone -d "$NODE_FQDN" --non-interactive --agree-tos --register-unsafely-without-email \
       --pre-hook "systemctl stop nginx || true" --post-hook "systemctl start nginx || true" >>"$LOG" 2>&1; then
    NODE_SCHEME=https; SSL_OK=1; ok "SSL node aktif untuk ${B}$NODE_FQDN${R}"
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nsystemctl restart wings || true\n' >/etc/letsencrypt/renewal-hooks/deploy/wings.sh; chmod +x /etc/letsencrypt/renewal-hooks/deploy/wings.sh
  else warn "Certbot gagal untuk $NODE_FQDN → node pakai HTTP"; fi
}

create_node(){
  NODE_FQDN="${NODE_FQDN:-$(public_ip)}"
  node_cert
  # lokasi
  local loc=""
  call GET /api/admin/locations && loc=$(echo "$RESP_BODY" | jq -r '.locations[0].id // empty')
  if [[ -z $loc ]]; then
    call POST /api/admin/locations '{"location":{"short":"default","long":"Default Location"}}' || die "Gagal membuat location ($RESP_CODE): ${RESP_BODY:0:200}"
    loc=$(echo "$RESP_BODY" | jq -r '.location.id // empty')
  fi
  [[ -n $loc ]] || die "Location tidak ditemukan"
  # panel membaca angka; 0 diganti default, jadi "unlimited" = angka sangat besar (+ overallocation 1000%)
  local body
  body=$(jq -nc --arg n "$NODE_NAME" --arg f "$NODE_FQDN" --arg loc "$loc" --arg sc "$NODE_SCHEME" \
    --argjson dp "$DAEMON_PORT" --argjson sp "$SFTP_PORT" \
    '{node:{name:$n,description:"Dibuat oleh sodium-installer",location_id:$loc,fqdn:$f,scheme:$sc,
      memory:999999999,disk:999999999,memory_overallocation:1000,disk_overallocation:1000,
      daemon_port:$dp,daemon_sftp_port:$sp,upload_size:1000,behind_proxy:false,
      allocation_start:25565,allocation_end:26565}}')
  call POST /api/admin/nodes "$body" || die "Gagal membuat node ($RESP_CODE): ${RESP_BODY:0:200}"
  NODE_ID=$(echo "$RESP_BODY" | jq -r '.node.id // empty')
  NODE_TOKEN=$(echo "$RESP_BODY" | jq -r '.node.daemon_token // empty')
  NODE_TOKEN_ID=$(echo "$RESP_BODY" | jq -r '.node.daemon_token_id // empty')
  [[ -n $NODE_ID && -n $NODE_TOKEN ]] || die "Respons node tidak lengkap: ${RESP_BODY:0:200}"
  ok "Node ${B}$NODE_NAME${R} dibuat  ${MUT}$NODE_SCHEME://$NODE_FQDN:$DAEMON_PORT · RAM/Disk unlimited${R}"
}

daemon_install(){
  local arch; arch=$(uname -m); [[ $arch == x86_64 ]] && arch=amd64 || arch=arm64
  mkdir -p /etc/sodium
  curl -fL --retry 3 -o /usr/local/bin/wings "https://github.com/sodiumpanel/reaction/releases/latest/download/wings_linux_$arch"
  chmod +x /usr/local/bin/wings
}

daemon_config(){
  local remote ssl=false cert="" key=""
  if [[ $MODE == full ]]; then remote="http://127.0.0.1:$PANEL_PORT"; else remote="$PANEL_PUBLIC"; fi
  if [[ $SSL_OK -eq 1 ]]; then ssl=true; cert="/etc/letsencrypt/live/$NODE_FQDN/fullchain.pem"; key="/etc/letsencrypt/live/$NODE_FQDN/privkey.pem"; fi
  mkdir -p /etc/sodium /var/sodium
  cat >/etc/sodium/config.yml <<EOF
debug: false
uuid: "$NODE_ID"
token_id: "$NODE_TOKEN_ID"
token: "$NODE_TOKEN"
api:
  host: "0.0.0.0"
  port: $DAEMON_PORT
  ssl:
    enabled: $ssl
    cert: "$cert"
    key: "$key"
  upload_limit: 1000
system:
  root_directory: "/var/sodium"
  log_directory: "/var/sodium/logs"
  data: "/var/sodium/volumes"
  archive_directory: "/var/sodium/archives"
  backup_directory: "/var/sodium/backups"
  tmp_directory: "/tmp/sodium"
  username: "sodium"
  sftp:
    bind_port: $SFTP_PORT
docker:
  network:
    name: "sodium_nw"
    interfaces:
      v4:
        subnet: "172.50.0.0/16"
        gateway: "172.50.0.1"
remote: "$remote"
allowed_origins:
  - "*"
EOF
  chmod 600 /etc/sodium/config.yml
  cat >/etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Sodium Reaction Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/sodium
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings --config /etc/sodium/config.yml
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable wings >>"$LOG" 2>&1; systemctl restart wings
  open_ports "$DAEMON_PORT" "$SFTP_PORT" 25565:26565
  ok "Config ${B}/etc/sodium/config.yml${R} ditulis & service ${B}wings${R} aktif"
}

node_green(){
  call GET /api/admin/nodes/health && echo "$RESP_BODY" | jq -e --arg id "$NODE_ID" '.health[$id].status | IN("online","degraded")' >/dev/null
}
wait_green(){
  say "Panel mengecek node tiap 60 detik — bisa sampai ~1-2 menit."
  if poll "Menunggu node hijau (online)" 240 node_green; then NODE_STATE="${OK}● ONLINE (hijau)${R}"
  else NODE_STATE="${WRN}● belum online${R}"
    warn "Cek: journalctl -u wings -n 50 --no-pager"
    warn "Pastikan port $DAEMON_PORT terbuka (firewall provider/VPS) dari panel ke node."
  fi
}

summary(){
  echo; local l=()
  if [[ $MODE == panel || $MODE == full ]]; then
    l+=("Panel   : ${B}$PANEL_PUBLIC${R}" "Admin   : ${B}$ADMIN_USER${R}   Pass: ${B}$ADMIN_PASS${R}")
  fi
  [[ -n $NODE_ID ]] && l+=("Node    : ${B}$NODE_NAME${R}" "Alamat  : $NODE_SCHEME://$NODE_FQDN:$DAEMON_PORT" "Status  : $NODE_STATE" "Resource: RAM ∞  ·  Disk ∞")
  l+=("" "${MUT}Log     : $LOG${R}")
  [[ $MODE == panel || $MODE == full ]] && l+=("${MUT}Service : systemctl status sodium-panel${R}")
  [[ -n $NODE_ID ]] && l+=("${MUT}Daemon  : systemctl status wings${R}")
  box "✔ INSTALASI SELESAI" "$OK" "${l[@]}"
  [[ $GEN_PASS == 1 ]] && echo -e "\n  ${WRN}Simpan password admin di atas — dibuat acak dan hanya tampil sekali.${R}"
  [[ $NODE_SCHEME == http && $PANEL_PUBLIC == https://* ]] && echo -e "  ${WRN}Panel HTTPS tapi node HTTP: console/upload di browser bisa diblokir (mixed content). Pakai domain node + SSL.${R}"
  echo
}

# =====================================================================
#  Alur
# =====================================================================
case "$MODE" in
  full)    STEP_TOTAL=8;;
  panel)   STEP_TOTAL=4;;
  node)    STEP_TOTAL=5;;
  addnode) STEP_TOTAL=5;;
  *) die "Mode salah. Pakai: panel | node | full | addnode";;
esac
if [[ $MODE == node || $MODE == addnode ]]; then
  [[ -n $PANEL_URL ]] || { [[ $MODE == node ]] && PANEL_URL="http://127.0.0.1:$PANEL_PORT" || die "Butuh --panel-url"; }
  [[ -n $ADMIN_PASS ]] || die "Butuh --admin-pass"
  PANEL_PUBLIC="$PANEL_URL"
fi
box "Mode: $MODE" "$MUT" "Host : $(hostname)   IP: $(public_ip)" "OS   : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-linux}")"
detect_pm

step "Paket dasar & Node.js"
run "Memasang paket dasar (curl, git, jq, build tools)" do_base
if have_node; then ok "Node.js $(node -v) sudah ada"; else run "Memasang Node.js 20 LTS" do_node; fi

if [[ $MODE == full || $MODE == panel ]]; then
  step "Mengunduh & build Sodium Panel"
  run "Clone + npm install + build panel" panel_fetch
  step "Menjalankan panel & domain"
  panel_start
  panel_domain_setup
  step "Setup admin panel"
  setup_panel_admin
fi

if [[ $MODE != panel ]]; then
  step "Login & membuat node"
  panel_login; create_node
  step "Memasang daemon (Docker + Sodium Reaction)"
  if command -v docker >/dev/null; then ok "Docker sudah ada"; else run "Memasang Docker" do_docker; fi
  run "Mengunduh binary Sodium Reaction" daemon_install
  step "Konfigurasi & start daemon"
  daemon_config
  step "Verifikasi node hijau"
  wait_green
fi
summary
