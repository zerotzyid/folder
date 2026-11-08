#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  Reviactyl Auto Installer — Panel + Agent (node)
#  Docs  : https://docs.reviactyl.app/
#  OS    : Ubuntu 22.04 / 24.04 / 26.04, Debian 12 / 13
#
#  Mode 1: Panel saja
#  Mode 2: Agent (node) saja  -> untuk panel yang sudah ada
#  Mode 3: Panel + Agent di server yang sama (node dibuat otomatis)
# ──────────────────────────────────────────────────────────────
set -Eeuo pipefail

PANEL_DIR="/var/www/reviactyl"
AGENT_DIR="/etc/reviactyl"
LOG="/var/log/reviactyl-install.log"
CRED="/root/reviactyl-credentials.txt"
DB_NAME="panel"
DB_USER="reviactyl"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LC_ALL=C.UTF-8

# ── UI ───────────────────────────────────────────────────────
C_O=$'\033[38;5;208m'; C_G=$'\033[90m'; C_R=$'\033[31m'; C_OK=$'\033[32m'; C_B=$'\033[1m'; C_0=$'\033[0m'
info() { echo -e "  ${C_G}›${C_0} $*"; }
ok()   { echo -e "  ${C_OK}✓${C_0} $*"; }
warn() { echo -e "  ${C_O}!${C_0} $*"; }
err()  { echo -e "  ${C_R}✗${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }
step() { echo; echo -e "  ${C_O}───${C_0} ${C_B}$*${C_0}"; echo; }

trap 'err "Gagal di baris $LINENO. Detail: $LOG"' ERR

ask() {            # ask "Prompt" [default]
    local p="$1" d="${2:-}" r
    if [[ -n "$d" ]]; then read -r -p "  › $p [$d]: " r; else read -r -p "  › $p: " r; fi
    echo "${r:-$d}"
}
ask_secret() { local r; read -r -s -p "  › $1: " r; echo >&2; echo "$r"; }
ask_yn() {         # ask_yn "Prompt" [y|n]  -> status 0 = ya
    local p="$1" d="${2:-y}" r hint="Y/n"
    [[ "$d" == "n" ]] && hint="y/N"
    read -r -p "  › $p [$hint]: " r
    r="${r:-$d}"; [[ "$r" =~ ^[Yy] ]]
}
ask_choice() {     # ask_choice "Prompt" opt1 opt2 ...
    local p="$1"; shift; local i=1 o c
    echo -e "  ${C_G}›${C_0} $p" >&2
    for o in "$@"; do echo "      $i) $o" >&2; i=$((i+1)); done
    read -r -p "  › Pilihan [1]: " c
    if [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -le $# ]]; then echo "$c"; else echo 1; fi
}
ask_req() { local v=""; while [[ -z "$v" ]]; do v="$(ask "$1" "${2:-}")"; done; echo "$v"; }

FQDN_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'
ask_fqdn() {
    local v=""
    while ! [[ "$v" =~ $FQDN_RE ]]; do
        v="$(ask "$1" "${2:-}")"
        [[ "$v" =~ $FQDN_RE ]] || warn "FQDN tidak valid, contoh: panel.example.com" >&2
    done
    echo "$v"
}

run() {            # run "Label" perintah...   (log ke $LOG)
    local label="$1"; shift
    printf "  %s›%s %s ... " "$C_G" "$C_0" "$label"
    echo "=== [$(date +%H:%M:%S)] $label ===" >> "$LOG"
    if "$@" >> "$LOG" 2>&1; then
        echo -e "${C_OK}OK${C_0}"
    else
        echo -e "${C_R}GAGAL${C_0}"
        echo "  --- 20 baris terakhir log ---"; tail -20 "$LOG" | sed 's/^/  | /'
        exit 1
    fi
}

rand_hex() { openssl rand -hex "${1:-16}"; }

set_env() {        # set_env KEY VALUE  -> tulis ke .env panel
    local k="$1" v="$2" f="$PANEL_DIR/.env"
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    { grep -v "^${k}=" "$f" || true; } > "$f.tmp"
    printf '%s="%s"\n' "$k" "$v" >> "$f.tmp"
    mv "$f.tmp" "$f"
}

# ── Preflight ────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Jalankan sebagai root: sudo -i"
[[ -t 0 ]] || exec </dev/tty

# shellcheck source=/dev/null
. /etc/os-release
case "${ID}-${VERSION_ID}" in
    ubuntu-22.04|ubuntu-24.04|ubuntu-26.04|debian-12|debian-13) ;;
    *) die "OS ${PRETTY_NAME} tidak didukung (Ubuntu 22.04/24.04/26.04, Debian 12/13)." ;;
esac
: > "$LOG"

clear 2>/dev/null || true
echo
echo -e "  ${C_O}Reviactyl${C_0} ${C_G}— Auto Installer (Panel + Agent)${C_0}"
echo -e "  ${C_G}${PRETTY_NAME} · docs.reviactyl.app${C_0}"
echo

SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
LOCAL_IP="$(hostname -I | awk '{print $1}')"
info "IP publik server ini: ${SERVER_IP:-tidak terdeteksi}"
echo

resolve_ip() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}' || true; }
check_dns() {
    local fqdn="$1" ip
    ip="$(resolve_ip "$fqdn")"
    if [[ -z "$ip" ]]; then
        warn "$fqdn belum ter-resolve. Buat A record ke ${SERVER_IP}."
    elif [[ "$ip" != "$SERVER_IP" ]]; then
        warn "$fqdn mengarah ke $ip, bukan ke server ini ($SERVER_IP). Kalau pakai proxy Cloudflare, matikan dulu (DNS only)."
    else
        ok "DNS $fqdn OK ($ip)"; return 0
    fi
    ask_yn "Lanjut tetap? (SSL bisa gagal)" "n" || exit 1
}

# ── Pertanyaan ───────────────────────────────────────────────
MODE="$(ask_choice "Mau install apa?" "Panel saja" "Agent (node) saja — untuk panel yang sudah ada" "Panel + Agent di server yang sama")"

PANEL_FQDN=""; NODE_FQDN=""; USE_SSL="y"
TZ_DEFAULT="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"

step "Domain & SSL"
if [[ "$MODE" == "2" ]]; then
    ask_yn "Panel Anda memakai HTTPS? (agent harus punya SSL juga)" "y" || USE_SSL="n"
else
    ask_yn "Pakai domain + SSL Let's Encrypt?" "y" || USE_SSL="n"
fi

if [[ "$MODE" != "2" ]]; then
    if [[ "$USE_SSL" == "y" ]]; then
        PANEL_FQDN="$(ask_fqdn "FQDN Panel (mis. panel.example.com)")"
        check_dns "$PANEL_FQDN"
        PANEL_URL="https://${PANEL_FQDN}"
    else
        PANEL_FQDN="${SERVER_IP}"
        PANEL_URL="http://${PANEL_FQDN}"
        info "Tanpa SSL: panel diakses lewat ${PANEL_URL}"
    fi
fi
if [[ "$MODE" != "1" ]]; then
    if [[ "$USE_SSL" == "y" ]]; then
        NODE_FQDN="$(ask_fqdn "FQDN Node (mis. node1.example.com)")"
        check_dns "$NODE_FQDN"
    else
        NODE_FQDN="$(ask_req "FQDN atau IP Node" "${SERVER_IP}")"
    fi
fi

if [[ "$MODE" != "2" ]]; then
    step "Akun admin panel"
    ADMIN_USER="$(ask "Username admin" "admin")"
    ADMIN_FIRST="$(ask "Nama depan" "Admin")"
    ADMIN_LAST="$(ask "Nama belakang" "User")"
    ADMIN_EMAIL=""
    while [[ ! "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; do
        ADMIN_EMAIL="$(ask "Email admin")"
    done
    while true; do
        ADMIN_PASS="$(ask_secret "Password admin (min. 8 karakter)")"
        [[ ${#ADMIN_PASS} -ge 8 ]] || { warn "Password minimal 8 karakter."; continue; }
        P2="$(ask_secret "Ulangi password")"
        [[ "$ADMIN_PASS" == "$P2" ]] && break
        warn "Password tidak sama."
    done

    step "Pengaturan panel"
    TIMEZONE="$(ask "Timezone" "$TZ_DEFAULT")"
    if ask_yn "Aktifkan telemetri anonim Reviactyl?" "y"; then TELEMETRY="true"; else TELEMETRY="false"; fi
    SMTP="n"
    if ask_yn "Setel SMTP email sekarang? (bisa nanti)" "n"; then
        SMTP="y"
        SMTP_HOST="$(ask_req "SMTP host")"
        SMTP_PORT="$(ask "SMTP port" "587")"
        SMTP_USER="$(ask "SMTP username")"
        SMTP_PASS="$(ask_secret "SMTP password")"
        SMTP_ENC="$(ask "Enkripsi (tls/ssl/kosong)" "tls")"
        SMTP_FROM="$(ask "Alamat pengirim" "$ADMIN_EMAIL")"
    fi
fi

if [[ "$MODE" != "1" ]]; then
    step "Pengaturan node"
    DAEMON_PORT="$(ask "Port agent (API)" "8080")"
    SFTP_PORT="$(ask "Port SFTP" "2022")"
    if [[ "$MODE" == "3" ]]; then
        LOC_SHORT="$(ask "Nama location (kode singkat)" "default")"
        NODE_NAME="$(ask "Nama node" "Node 1")"
        RAM_MB="$(free -m | awk '/Mem:/{print $2}')"
        DISK_MB="$(df -m --output=avail / | tail -1 | tr -d ' ')"
        NODE_MEM="$(ask "Memori node (MB)" "$RAM_MB")"
        NODE_DISK="$(ask "Disk node (MB)" "$DISK_MB")"
        ALLOC_RANGE="$(ask "Range port allocation, mis. 25565-25575 (kosong = lewati)" "25565-25575")"
    fi
fi

step "Ringkasan"
case "$MODE" in 1) info "Mode        : Panel saja";; 2) info "Mode        : Agent saja";; 3) info "Mode        : Panel + Agent";; esac
[[ -n "$PANEL_FQDN" ]] && info "Panel       : ${PANEL_URL}"
[[ -n "$NODE_FQDN"  ]] && info "Node        : ${NODE_FQDN} (API :${DAEMON_PORT}, SFTP :${SFTP_PORT})"
[[ "$MODE" != "2" ]]  && info "Admin       : ${ADMIN_EMAIL}"
info "Log         : ${LOG}"
echo
ask_yn "Mulai instalasi?" "y" || { info "Dibatalkan."; exit 0; }

if [[ "$MODE" != "2" && -f "$PANEL_DIR/artisan" ]]; then
    die "Instalasi lama ditemukan di $PANEL_DIR. Hapus manual dulu bila ingin install ulang."
fi

# ── Fungsi instalasi ─────────────────────────────────────────
apt_base() {
    apt-get update -y
    apt-get install -y software-properties-common curl ca-certificates gnupg lsb-release \
        apt-transport-https tar unzip git openssl cron ufw
}

add_php_repo() {
    if [[ "$ID" == "ubuntu" && "$VERSION_ID" == "26.04" ]]; then
        return 0   # PHP 8.5 sudah ada di repo bawaan
    elif [[ "$ID" == "ubuntu" ]]; then
        add-apt-repository -y ppa:ondrej/php
    else
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor --yes -o /usr/share/keyrings/sury-php.gpg
        local cn; cn="$(lsb_release -sc)"
        curl -fsSL --head "https://packages.sury.org/php/dists/${cn}/Release" >/dev/null 2>&1 || cn="bookworm"
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${cn} main" \
            > /etc/apt/sources.list.d/sury-php.list
    fi
    apt-get update -y
}

PHP_VER="8.4"
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "26.04" ]] && PHP_VER="8.5"

install_panel_packages() {
    apt-get install -y "php${PHP_VER}" \
        php${PHP_VER}-{common,cli,gd,mbstring,bcmath,xml,fpm,curl,zip,intl,redis,sqlite3,mysql,pgsql} \
        nginx mariadb-server redis-server certbot
    update-alternatives --set php "/usr/bin/php${PHP_VER}" || true
    systemctl enable --now mariadb redis-server "php${PHP_VER}-fpm" nginx
}

install_composer() {
    command -v composer >/dev/null && return 0
    curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
}

download_panel() {
    mkdir -p "$PANEL_DIR"; cd "$PANEL_DIR"
    curl -fL -o panel.tar.gz https://github.com/reviactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz
    rm -f panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/
}

panel_dependencies() {
    cd "$PANEL_DIR"
    cp .env.example .env
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
    php artisan key:generate --force
}

setup_database() {
    mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

configure_environment() {
    cd "$PANEL_DIR"
    # Perintah resmi panel (flag mengikuti Pterodactyl); lanjut meski ada yang ditolak,
    # nilai penting dipaksa lewat .env di bawah.
    php artisan p:environment:setup --author="$ADMIN_EMAIL" --url="$PANEL_URL" --timezone="$TIMEZONE" \
        --cache=redis --session=redis --queue=redis --redis-host=127.0.0.1 --redis-pass= --redis-port=6379 \
        --telemetry="$TELEMETRY" --no-interaction < /dev/null || true

    set_env APP_URL "$PANEL_URL"
    set_env APP_TIMEZONE "$TIMEZONE"
    set_env APP_SERVICE_AUTHOR "$ADMIN_EMAIL"
    set_env APP_ENVIRONMENT_ONLY "false"
    set_env CACHE_DRIVER redis
    set_env SESSION_DRIVER redis
    set_env QUEUE_CONNECTION redis
    set_env QUEUE_DRIVER redis
    set_env REDIS_HOST 127.0.0.1
    set_env REDIS_PORT 6379
    set_env DB_CONNECTION mysql
    set_env DB_HOST 127.0.0.1
    set_env DB_PORT 3306
    set_env DB_DATABASE "$DB_NAME"
    set_env DB_USERNAME "$DB_USER"
    set_env DB_PASSWORD "$DB_PASS"
    set_env PANEL_TELEMETRY_ENABLED "$TELEMETRY"
    if [[ "$USE_SSL" == "y" ]]; then set_env TRUSTED_PROXIES "127.0.0.1"; fi

    if [[ "$SMTP" == "y" ]]; then
        set_env MAIL_MAILER smtp;  set_env MAIL_DRIVER smtp
        set_env MAIL_HOST "$SMTP_HOST"; set_env MAIL_PORT "$SMTP_PORT"
        set_env MAIL_USERNAME "$SMTP_USER"; set_env MAIL_PASSWORD "$SMTP_PASS"
        set_env MAIL_ENCRYPTION "$SMTP_ENC"
        set_env MAIL_FROM_ADDRESS "$SMTP_FROM"; set_env MAIL_FROM_NAME "Reviactyl"
    else
        set_env MAIL_MAILER log; set_env MAIL_DRIVER log
    fi
    php artisan optimize:clear || true
}

migrate_db() { cd "$PANEL_DIR"; php artisan migrate --seed --force; }

create_admin() {
    cd "$PANEL_DIR"
    php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" \
        --name-first="$ADMIN_FIRST" --name-last="$ADMIN_LAST" --password="$ADMIN_PASS" \
        --admin=1 --no-interaction
}

set_permissions() { chown -R www-data:www-data "$PANEL_DIR"; chmod 640 "$PANEL_DIR/.env"; }

setup_cron_and_queue() {
    echo "* * * * * www-data php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/reviactyl
    chmod 644 /etc/cron.d/reviactyl
    cat > /etc/systemd/system/reviq.service <<'UNIT'
[Unit]
Description=Reviactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/reviactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now reviq.service
}

write_nginx() {   # $1 = http | ssl
    local conf="/etc/nginx/sites-available/reviactyl.conf" domain="$PANEL_FQDN"
    [[ "$USE_SSL" != "y" ]] && domain="_"
    if [[ "$1" == "http" ]]; then
        cat > "$conf" <<'NGINX'
server {
    listen 80 default_server;
    server_name __DOMAIN__;
    root __DIR__/public;
    index index.php;
    charset utf-8;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / { try_files $uri $uri/ /index.php?$query_string; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/reviactyl.app-error.log error;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php__PHP__-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht { deny all; }
}
NGINX
    else
        cat > "$conf" <<'NGINX'
server {
    listen 80 default_server;
    server_name __DOMAIN__;

    # Jalur validasi Let's Encrypt (untuk pembaruan sertifikat otomatis)
    location ^~ /.well-known/acme-challenge/ { root __DIR__/public; }
    location / { return 301 https://__DOMAIN__$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name __DOMAIN__;

    root __DIR__/public;
    index index.php;

    access_log /var/log/nginx/reviactyl.app-access.log;
    error_log  /var/log/nginx/reviactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / { try_files $uri $uri/ /index.php?$query_string; }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php__PHP__-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht { deny all; }
}
NGINX
    fi
    sed -i -e "s#__DOMAIN__#${domain}#g" -e "s#__DIR__#${PANEL_DIR}#g" -e "s#__PHP__#${PHP_VER}#g" "$conf"
    rm -f /etc/nginx/sites-enabled/default
    ln -sf "$conf" /etc/nginx/sites-enabled/reviactyl.conf
    nginx -t
    systemctl restart nginx
}

issue_cert_webroot() {   # $1 = domain
    certbot certonly --webroot -w "$PANEL_DIR/public" -d "$1" -m "$ADMIN_EMAIL" \
        --agree-tos --no-eff-email --non-interactive
}
issue_cert_standalone() { # $1 = domain
    certbot certonly --standalone -d "$1" --register-unsafely-without-email \
        --agree-tos --non-interactive
}

renewal_hook() {
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reviactyl.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx 2>/dev/null || true
systemctl restart agent 2>/dev/null || true
exit 0
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reviactyl.sh
}

install_docker() {
    command -v docker >/dev/null && { systemctl enable --now docker; return 0; }
    curl -fsSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
}

install_agent_binary() {
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo "Arsitektur $(uname -m) tidak didukung"; return 1 ;;
    esac
    mkdir -p "$AGENT_DIR"
    curl -fL -o /usr/local/bin/agent "https://github.com/reviactyl/agent/releases/latest/download/agent_linux_${arch}"
    chmod u+x /usr/local/bin/agent
}

install_agent_service() {
    cat > /etc/systemd/system/agent.service <<'UNIT'
[Unit]
Description=Reviactyl Agent
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/reviactyl
LimitNOFILE=4096
PIDFile=/var/run/agent/daemon.pid
ExecStart=/usr/local/bin/agent
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable agent
}

open_firewall() {
    ufw status 2>/dev/null | grep -q "Status: active" || return 0
    [[ "$MODE" != "2" ]] && { ufw allow 80/tcp; ufw allow 443/tcp; }
    if [[ "$MODE" != "1" ]]; then
        ufw allow "${DAEMON_PORT}/tcp"; ufw allow "${SFTP_PORT}/tcp"
        [[ "$USE_SSL" == "y" ]] && ufw allow 80/tcp
    fi
}

# Buat location + node + config agent langsung dari panel lokal (mode 3)
create_node_local() {
    cd "$PANEL_DIR"
    php artisan list --raw 2>/dev/null | grep -q '^p:node:make' || return 1
    php artisan p:location:make --short="$LOC_SHORT" --long="Dibuat oleh auto installer" --no-interaction
    local loc_id node_id scheme="http"
    [[ "$USE_SSL" == "y" ]] && scheme="https"
    loc_id="$(mysql -N -e "SELECT id FROM ${DB_NAME}.locations ORDER BY id DESC LIMIT 1")"
    php artisan p:node:make --name="$NODE_NAME" --description="Dibuat oleh auto installer" \
        --locationId="$loc_id" --fqdn="$NODE_FQDN" --public=1 --scheme="$scheme" --proxy=0 \
        --maintenance=0 --maxMemory="$NODE_MEM" --overallocateMemory=0 \
        --maxDisk="$NODE_DISK" --overallocateDisk=0 --uploadSize=100 \
        --daemonListeningPort="$DAEMON_PORT" --daemonSFTPPort="$SFTP_PORT" \
        --daemonBase="/var/lib/pterodactyl/volumes" --no-interaction
    node_id="$(mysql -N -e "SELECT id FROM ${DB_NAME}.nodes ORDER BY id DESC LIMIT 1")"
    [[ -n "$node_id" ]] || return 1

    mkdir -p "$AGENT_DIR"
    php artisan p:node:configuration "$node_id" > "$AGENT_DIR/config.yml"
    grep -q '^token' "$AGENT_DIR/config.yml" || return 1
    chmod 600 "$AGENT_DIR/config.yml"

    if [[ "$ALLOC_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" p sql=""
        if (( a >= 1024 && b <= 65535 && a <= b && b - a < 2000 )); then
            for ((p=a; p<=b; p++)); do sql+="(${node_id},'${LOCAL_IP}',${p},NOW(),NOW()),"; done
            mysql -e "INSERT INTO ${DB_NAME}.allocations (node_id, ip, port, created_at, updated_at) VALUES ${sql%,};" \
                || echo "Allocation otomatis gagal; tambahkan manual lewat panel." >&2
        fi
    fi
    NODE_ID="$node_id"
}

# Validasi + jalankan perintah "agent configure ..." yang disalin dari panel
run_configure_command() {
    local cmd="$1"
    cmd="${cmd#cd /etc/reviactyl && }"; cmd="${cmd#sudo }"
    if [[ "$cmd" =~ ^agent\ configure(\ --[a-z-]+(\ [A-Za-z0-9_:/.@-]+)?)*$ ]]; then
        mkdir -p "$AGENT_DIR"; cd "$AGENT_DIR"
        # shellcheck disable=SC2086
        /usr/local/bin/$cmd
    else
        return 1
    fi
}

obtain_agent_config() {   # mode 2, atau mode 3 bila otomatis gagal
    echo
    info "Di panel: Admin → Nodes → (buat node dengan FQDN ${NODE_FQDN}, port ${DAEMON_PORT}, SFTP ${SFTP_PORT})"
    info "lalu buka node tersebut dan salah satu dari:"
    local c; c="$(ask_choice "Cara memasukkan konfigurasi agent" \
        "Tempel perintah dari tombol 'Generate Token'" \
        "Tempel isi config.yml (tab Configuration)" \
        "Lewati — konfigurasi nanti")"
    case "$c" in
        1)
            local line; line="$(ask_req "Tempel perintahnya (1 baris)")"
            if run_configure_command "$line"; then ok "Konfigurasi agent tersimpan."
            else warn "Perintah tidak dikenali/aman. Jalankan manual dari panel."; fi ;;
        2)
            mkdir -p "$AGENT_DIR"
            info "Tempel isi config.yml, lalu tekan Ctrl+D di baris baru:"
            cat > "$AGENT_DIR/config.yml"
            chmod 600 "$AGENT_DIR/config.yml"
            grep -q '^token' "$AGENT_DIR/config.yml" && ok "config.yml tersimpan." \
                || warn "config.yml tampak tidak lengkap." ;;
        *) info "Dilewati." ;;
    esac
}

# ── Eksekusi ─────────────────────────────────────────────────
run "Menyiapkan paket dasar" apt_base

if [[ "$MODE" != "2" ]]; then
    step "Memasang Panel"
    DB_PASS="$(rand_hex 16)"
    run "Menambah repo PHP" add_php_repo
    run "Memasang PHP ${PHP_VER}, Nginx, MariaDB, Redis, Certbot" install_panel_packages
    run "Memasang Composer" install_composer
    run "Mengunduh panel" download_panel
    run "Memasang dependensi panel" panel_dependencies
    APP_KEY_BACKUP="$(grep '^APP_KEY=' "$PANEL_DIR/.env" | cut -d= -f2-)"
    run "Membuat database" setup_database
    run "Mengonfigurasi environment" configure_environment
    run "Migrasi database + seed" migrate_db
    run "Membuat akun admin" create_admin
    run "Mengatur permission" set_permissions
    run "Cron + queue worker (autostart)" setup_cron_and_queue

    run "Konfigurasi Nginx" write_nginx http
    if [[ "$USE_SSL" == "y" ]]; then
        run "Sertifikat SSL panel" issue_cert_webroot "$PANEL_FQDN"
        [[ "$MODE" == "3" ]] && run "Sertifikat SSL node" issue_cert_webroot "$NODE_FQDN"
        run "Hook pembaruan sertifikat" renewal_hook
        run "Nginx + SSL" write_nginx ssl
    fi
    run "Restart service panel" systemctl restart php${PHP_VER}-fpm nginx reviq
    ok "Panel aktif di ${PANEL_URL}"
fi

if [[ "$MODE" != "1" ]]; then
    step "Memasang Agent (node)"
    case "$(systemd-detect-virt 2>/dev/null || echo none)" in
        openvz|lxc*) warn "Virtualisasi OpenVZ/LXC biasanya tidak bisa menjalankan Docker. Lanjut dengan risiko sendiri." ;;
    esac
    run "Memasang Docker" install_docker
    run "Mengunduh agent" install_agent_binary
    run "Service agent (autostart)" install_agent_service

    if [[ "$MODE" == "2" && "$USE_SSL" == "y" ]]; then
        if ss -tln 2>/dev/null | grep -q ':80 '; then
            warn "Port 80 terpakai; sertifikat node mungkin gagal."
        fi
        run "Memasang Certbot" apt-get install -y certbot
        run "Sertifikat SSL node" issue_cert_standalone "$NODE_FQDN"
        run "Hook pembaruan sertifikat" renewal_hook
    fi
    run "Firewall (jika UFW aktif)" open_firewall

    if [[ "$MODE" == "3" ]]; then
        printf "  %s›%s Membuat location + node + konfigurasi otomatis ... " "$C_G" "$C_0"
        if create_node_local >> "$LOG" 2>&1; then
            echo -e "${C_OK}OK${C_0}"
        else
            echo -e "${C_O}TIDAK OTOMATIS${C_0}"
            warn "Perintah pembuatan node tidak tersedia/gagal. Buat node manual di panel."
            obtain_agent_config
        fi
    else
        obtain_agent_config
    fi

    if [[ -s "$AGENT_DIR/config.yml" ]]; then
        run "Menjalankan agent" systemctl restart agent
        sleep 4
        if systemctl is-active --quiet agent; then ok "Agent berjalan."; else
            warn "Agent belum aktif. Cek: journalctl -u agent -n 50"; fi
    else
        warn "Belum ada config.yml. Setelah dibuat: systemctl start agent"
    fi
fi

# ── Simpan kredensial ────────────────────────────────────────
{
    echo "# Reviactyl — dibuat $(date -u +%FT%TZ)"
    if [[ "$MODE" != "2" ]]; then
        echo "PANEL_URL=${PANEL_URL}"
        echo "ADMIN_EMAIL=${ADMIN_EMAIL}"
        echo "ADMIN_USERNAME=${ADMIN_USER}"
        echo "DB_NAME=${DB_NAME}"
        echo "DB_USER=${DB_USER}"
        echo "DB_PASSWORD=${DB_PASS}"
        echo "APP_KEY=${APP_KEY_BACKUP}   # SIMPAN! Tanpa ini data terenkripsi tidak bisa dipulihkan"
    fi
    [[ "$MODE" != "1" ]] && echo "NODE_FQDN=${NODE_FQDN}"
} > "$CRED"
chmod 600 "$CRED"

# ── Selesai ──────────────────────────────────────────────────
step "Selesai"
[[ "$MODE" != "2" ]] && ok "Panel : ${PANEL_URL}  (login: ${ADMIN_EMAIL})"
[[ "$MODE" != "1" ]] && ok "Node  : ${NODE_FQDN}"
ok "Kredensial & APP_KEY tersimpan di ${CRED} (chmod 600) — salin ke tempat aman"
echo
info "Autostart aktif: nginx, php${PHP_VER}-fpm, mariadb, redis-server, reviq, docker, agent"
info "Cek    : systemctl status reviq agent nginx"
info "Log    : journalctl -u agent -f   |   ${LOG}"
[[ "$MODE" != "1" ]] && info "Lanjut : panel → Nodes → pastikan node hijau, cek Allocation, lalu buat server."
echo
