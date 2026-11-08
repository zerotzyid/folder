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
PANEL_PORT="${PANEL_PORT:-3000}"; PANEL_URL=""; PANEL_PUBLIC=""
ADMIN_USER="${ADMIN_USER:-admin}"; ADMIN_PASS="${ADMIN_PASS:-}"; ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost.local}"
NODE_NAME="${NODE_NAME:-node-$(hostname -s)}"; NODE_FQDN=""
DAEMON_PORT="${DAEMON_PORT:-8080}"; SFTP_PORT="${SFTP_PORT:-2022}"
DEV=0; INTERACTIVE=0
LOG="/var/log/sodium-installer.log"; ROUTES="/tmp/sodium-routes.txt"
TOKEN=""; RESP_BODY=""; RESP_CODE=""; NODE_ID=""; NODE_TOKEN=""; NODES_PATH=""; NODE_RAW=""; USED_PATH=""
STEP_NOW=0; STEP_TOTAL=1
TTY=/dev/tty; [[ -r $TTY ]] || TTY=/dev/stdin

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) DEV=1;;
    --panel-url) PANEL_URL="${2%/}"; shift;;
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
    ask "FQDN/IP node (kosong = deteksi otomatis)" ""; NODE_FQDN=$ASK_RES
  fi
  echo
  box "Ringkasan" "$ACC" \
    "Mode       : ${B}$MODE${R}" \
    "Panel port : $PANEL_PORT   ${MUT}(dev=$DEV)${R}" \
    "Admin      : $ADMIN_USER" \
    "Node       : $NODE_NAME" "" "${MUT}Tekan Enter untuk mulai, Ctrl+C untuk batal${R}"
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

# =====================================================================
#  HTTP helper
# =====================================================================
call(){
  local m=$1 p=$2 d=${3:-} out
  local a=(-sS -m 40 -X "$m" -H 'Content-Type: application/json' -w $'\n%{http_code}')
  [[ -n $TOKEN ]] && a+=(-H "Authorization: Bearer $TOKEN" -H "X-API-Key: $TOKEN")
  [[ -n $d ]] && a+=(-d "$d")
  out=$(curl "${a[@]}" "$PANEL_URL$p" 2>/dev/null) || { RESP_CODE=000; RESP_BODY=""; return 1; }
  RESP_CODE=${out##*$'\n'}; RESP_BODY=${out%$'\n'*}
  [[ $RESP_CODE =~ ^2 ]]
}
first_ok(){ local m=$1 d=$2; shift 2; for p in "$@"; do call "$m" "$p" "$d" && { USED_PATH=$p; return 0; }; done; return 1; }
http_up(){ curl -sS -m 3 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null | grep -qE '^[1-4]'; }

discover_routes(){
  : > "$ROUTES"; [[ -d $PANEL_DIR ]] || return 0
  grep -rhoE "(app|router|r|api|admin)\.(get|post|put|patch|delete|use)\(\s*['\"\`][^'\"\`]+" \
    --include=*.js --include=*.mjs --include=*.ts "$PANEL_DIR" --exclude-dir=node_modules --exclude-dir=public 2>/dev/null \
    | sed -E "s/.*\(\s*['\"\`]//" | sort -u > "$ROUTES" || true
  ok "Route API terdeteksi otomatis: ${B}$(wc -l < "$ROUTES")${R}"
}
routes_like(){ grep -iE "$1" "$ROUTES" 2>/dev/null | grep -v ':' | head -8 || true; }

# =====================================================================
#  Panel
# =====================================================================
panel_fetch(){ clone "$PANEL_REPO" "$PANEL_DIR"; cd "$PANEL_DIR"; npm install --no-audit --no-fund; npm run build; }
panel_start(){
  PANEL_URL="http://127.0.0.1:$PANEL_PORT"
  if [[ $DEV -eq 1 ]]; then
    (cd "$PANEL_DIR" && PORT=$PANEL_PORT nohup npm start >"$BASE_DIR/panel.out" 2>&1 &)
    ok "Mode DEV: ${B}npm start${R} berjalan di background (log: $BASE_DIR/panel.out)"
  else
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
    systemctl daemon-reload; systemctl enable --now sodium-panel >>"$LOG" 2>&1
    ok "Service systemd ${B}sodium-panel${R} aktif"
  fi
  open_ports "$PANEL_PORT"
  poll "Menunggu panel merespon di port $PANEL_PORT" 90 http_up "$PANEL_URL" || die "Panel tidak merespon. Cek $BASE_DIR/panel.out / journalctl -u sodium-panel"
}
wizard_done(){ [[ -f $PANEL_DIR/data/config.json ]]; }
setup_panel_admin(){
  [[ -z $ADMIN_PASS ]] && ADMIN_PASS=$(rand 16) && GEN_PASS=1
  if wizard_done; then ok "Panel sudah ter-setup (data/config.json ada)"; return; fi
  say "Mencoba setup wizard otomatis lewat API..."
  local body url; url="http://$(public_ip):$PANEL_PORT"
  body=$(jq -nc --arg u "$ADMIN_USER" --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASS" --arg url "$url" --argjson port "$PANEL_PORT" \
    '{panelName:"Sodium",name:"Sodium",url:$url,panelUrl:$url,port:$port,database:{type:"file"},db:{type:"file"},redis:{enabled:false},
      limits:{servers:0,memory:0,disk:0,cpu:0},defaultLimits:{servers:0,memory:0,disk:0,cpu:0},
      admin:{username:$u,email:$e,password:$p},username:$u,email:$e,password:$p}')
  local cands=($(routes_like 'setup') /api/setup /api/setup/complete /api/setup/finish /setup)
  if first_ok POST "$body" "${cands[@]}"; then ok "Setup selesai via ${B}$USED_PATH${R}"; sleep 3; return; fi
  echo
  box "Selesaikan wizard di browser" "$WRN" \
    "Buka : ${B}$url${R}" "Pilih DB ${B}File${R}, buat akun admin." "" "${MUT}Script menunggu otomatis...${R}"
  poll "Menunggu wizard selesai (data/config.json)" 1800 wizard_done || die "Wizard belum selesai"
  ask "Username admin yang Anda buat" "$ADMIN_USER"; ADMIN_USER=$ASK_RES
  ask "Password admin" "" secret; ADMIN_PASS=$ASK_RES; GEN_PASS=0; sleep 3
}
panel_login(){
  local paths=($(routes_like 'login') /api/auth/login /api/login /api/v1/auth/login /auth/login) b
  local bodies=(
    "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')"
    "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{email:$u,password:$p}')"
    "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{login:$u,password:$p}')")
  for b in "${bodies[@]}"; do
    if first_ok POST "$b" "${paths[@]}"; then
      TOKEN=$(echo "$RESP_BODY" | jq -r '.token // .accessToken // .access_token // .jwt // .data.token // .data.accessToken // empty')
      [[ -n $TOKEN ]] && { ok "Login admin berhasil"; return; }
    fi
  done
  die "Login gagal. Cek username/password admin atau URL panel."
}

# =====================================================================
#  Node + Daemon
# =====================================================================
create_node(){
  NODE_FQDN="${NODE_FQDN:-$(public_ip)}"
  local paths=($(routes_like 'node') /api/admin/nodes /api/nodes /api/admin/node) loc="" lp
  for lp in $(routes_like 'location') /api/admin/locations /api/locations; do
    if call GET "$lp"; then loc=$(echo "$RESP_BODY" | jq -r '(.[0] // .locations[0] // .data[0] // empty) | (.id // .uuid // empty)' 2>/dev/null || true); [[ -n $loc ]] && break; fi
  done
  if [[ -z $loc ]]; then
    for lp in /api/admin/locations /api/locations; do
      if call POST "$lp" '{"name":"Default","short":"default","description":"Default"}'; then
        loc=$(echo "$RESP_BODY" | jq -r '.id // .uuid // .location.id // .data.id // empty'); [[ -n $loc ]] && break; fi
    done
  fi
  local trial m d o body
  for trial in "0 0 -1" "999999999 999999999 0"; do
    read -r m d o <<<"$trial"
    body=$(jq -nc --arg n "$NODE_NAME" --arg f "$NODE_FQDN" --arg loc "$loc" \
      --argjson m "$m" --argjson d "$d" --argjson o "$o" --argjson dp "$DAEMON_PORT" --argjson sp "$SFTP_PORT" \
      '{name:$n,fqdn:$f,host:$f,address:$f,ip:$f,scheme:"http",port:$dp,daemonPort:$dp,daemonListen:$dp,daemonSftp:$sp,sftpPort:$sp,
        memory:$m,disk:$d,memoryOverallocate:$o,diskOverallocate:$o,overallocate:$o,cpu:0,public:true,maintenanceMode:false,
        locationId:(if $loc=="" then null else $loc end),location:(if $loc=="" then null else $loc end),location_id:(if $loc=="" then null else $loc end)}')
    if first_ok POST "$body" "${paths[@]}"; then
      NODES_PATH=${USED_PATH%/}
      NODE_ID=$(echo "$RESP_BODY" | jq -r '.id // .uuid // .node.id // .data.id // .node.uuid // empty')
      NODE_TOKEN=$(echo "$RESP_BODY" | jq -r '.token // .daemonToken // .daemon_token // .node.token // .data.token // empty')
      NODE_RAW="$RESP_BODY"
      [[ -n $NODE_ID ]] && { ok "Node ${B}$NODE_NAME${R} dibuat  ${MUT}id=$NODE_ID · RAM/Disk unlimited${R}"; return; }
    fi
  done
  die "Gagal membuat node. Respons ($RESP_CODE): ${RESP_BODY:0:200}"
}
fetch_daemon_config(){
  mkdir -p /etc/sodium; local p
  for p in config configuration config-yaml config.yml deploy; do
    if call GET "$NODES_PATH/$NODE_ID/$p"; then printf '%s' "$RESP_BODY" > /etc/sodium/node-config.raw; ok "Config daemon diambil dari panel ${MUT}(/$p)${R}"; return 0; fi
  done
  if [[ -n $NODE_TOKEN ]]; then
    jq -n --arg id "$NODE_ID" --arg t "$NODE_TOKEN" --arg u "$PANEL_PUBLIC" --argjson p "$DAEMON_PORT" --argjson s "$SFTP_PORT" \
      '{uuid:$id,token:$t,panel:$u,remote:$u,api:{host:"0.0.0.0",port:$p},sftp:{port:$s}}' > /etc/sodium/node-config.raw
    warn "Endpoint config tidak ada; memakai token dari pembuatan node"; return 0
  fi
  echo "$NODE_RAW" > /etc/sodium/node-config.raw; warn "Respons mentah disimpan di /etc/sodium/node-config.raw"
}
daemon_fetch(){
  clone "$DAEMON_REPO" "$DAEMON_DIR"; cd "$DAEMON_DIR"
  if [[ -f go.mod ]]; then command -v go >/dev/null || do_go; go build -o reaction .
  elif [[ -f package.json ]]; then npm install --no-audit --no-fund; npm run build || true
  else echo "Struktur repo daemon tidak dikenali"; return 1; fi
}
daemon_service(){
  local start raw=/etc/sodium/node-config.raw ext=yml t
  if [[ -f $DAEMON_DIR/go.mod ]]; then start="$DAEMON_DIR/reaction"; else start="$(command -v npm) start"; fi
  head -c1 "$raw" | grep -q '[{[]' && ext=json
  if [[ $ext == json ]]; then jq . "$raw" > /etc/sodium/config.json 2>/dev/null || cp "$raw" /etc/sodium/config.json; else cp "$raw" /etc/sodium/config.yml; fi
  for t in "$DAEMON_DIR/config.$ext" "$DAEMON_DIR/config/config.$ext" "/etc/sodium-reaction/config.$ext"; do
    mkdir -p "$(dirname "$t")"; cp "/etc/sodium/config.$ext" "$t"; done
  cat >/etc/systemd/system/sodium-reaction.service <<EOF
[Unit]
Description=Sodium Reaction Daemon
After=network.target docker.service
Requires=docker.service
[Service]
WorkingDirectory=$DAEMON_DIR
ExecStart=$start
Restart=always
RestartSec=3
LimitNOFILE=4096000
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now sodium-reaction >>"$LOG" 2>&1
  open_ports "$DAEMON_PORT" "$SFTP_PORT"
  ok "Service systemd ${B}sodium-reaction${R} aktif"
}
node_green(){
  call GET "$NODES_PATH/$NODE_ID" && echo "$RESP_BODY" | grep -qiE '"(online|connected|alive)"[[:space:]]*:[[:space:]]*true|"status"[[:space:]]*:[[:space:]]*"(online|connected|ready|running)"'
}
wait_green(){
  if poll "Menunggu node hijau (online)" 180 node_green; then NODE_STATE="${OK}● ONLINE (hijau)${R}"
  else NODE_STATE="${WRN}● belum terdeteksi online${R}"
    warn "Cek: journalctl -u sodium-reaction -n 50 --no-pager  · pastikan port $DAEMON_PORT terbuka dari panel"; fi
}

summary(){
  echo; local l=()
  if [[ $MODE == panel || $MODE == full ]]; then
    l+=("Panel   : ${B}http://$(public_ip):$PANEL_PORT${R}" "Admin   : ${B}$ADMIN_USER${R}   Pass: ${B}$ADMIN_PASS${R}")
  fi
  [[ -n $NODE_ID ]] && l+=("Node    : ${B}$NODE_NAME${R} ($NODE_FQDN)" "Status  : ${NODE_STATE:-}" "Resource: RAM ∞  ·  Disk ∞")
  l+=("" "${MUT}Log     : $LOG${R}")
  [[ $MODE == panel || $MODE == full ]] && l+=("${MUT}Service : systemctl status sodium-panel${R}")
  [[ -n $NODE_ID ]] && l+=("${MUT}Daemon  : systemctl status sodium-reaction${R}")
  box "✔ INSTALASI SELESAI" "$OK" "${l[@]}"
  [[ ${GEN_PASS:-0} == 1 ]] && echo -e "\n  ${WRN}Simpan password admin di atas — dibuat acak dan hanya tampil sekali.${R}"
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
fi
box "Mode: $MODE" "$MUT" "Host : $(hostname)   IP: $(public_ip)" "OS   : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-linux}")"
detect_pm

step "Paket dasar & Node.js"
run "Memasang paket dasar (curl, git, jq, build tools)" do_base
if have_node; then ok "Node.js $(node -v) sudah ada"; else run "Memasang Node.js 20 LTS" do_node; fi

if [[ $MODE == full || $MODE == panel ]]; then
  step "Mengunduh & build Sodium Panel"
  run "Clone + npm install + build panel" panel_fetch
  discover_routes
  step "Menjalankan panel"
  panel_start
  step "Setup admin panel"
  setup_panel_admin
fi
if [[ $MODE == full ]]; then PANEL_PUBLIC="http://$(public_ip):$PANEL_PORT"; fi
if [[ $MODE == node || $MODE == addnode ]]; then PANEL_PUBLIC="$PANEL_URL"; fi

if [[ $MODE != panel ]]; then
  step "Login & membuat node"
  panel_login; create_node
  step "Memasang daemon (Docker + Sodium Reaction)"
  if command -v docker >/dev/null; then ok "Docker sudah ada"; else run "Memasang Docker" do_docker; fi
  run "Clone + build Sodium Reaction" daemon_fetch
  step "Konfigurasi & start daemon"
  fetch_daemon_config; daemon_service
  step "Verifikasi node hijau"
  wait_green
fi
summary
