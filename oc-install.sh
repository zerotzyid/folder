#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# OpenCode Web GUI installer for Ubuntu
# Safe default: listen on localhost; access via SSH tunnel.

if [[ $EUID -ne 0 ]]; then
  echo "Jalankan dengan: sudo bash oc-install.sh"
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "OS tidak dikenali."
  exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "Installer ini ditujukan untuk Ubuntu."
  exit 1
fi

echo "========================================"
echo "       OPENCODE WEB GUI INSTALLER"
echo "========================================"

read -r -p "Username [zerotzyid]: " OC_USER
OC_USER="${OC_USER:-zerotzyid}"

if [[ ! "$OC_USER" =~ ^[a-zA-Z0-9._-]{3,32}$ ]]; then
  echo "Username tidak valid."
  exit 1
fi

read -r -s -p "Password [zerotzyid]: " OC_PASS
echo
OC_PASS="${OC_PASS:-zerotzyid}"

if [[ ! "$OC_PASS" =~ ^[a-zA-Z0-9._-]{8,128}$ ]]; then
  echo "Password harus 8-128 karakter: huruf, angka, titik, _ atau -."
  exit 1
fi

if [[ "$OC_PASS" == "zerotzyid" ]]; then
  echo "PERINGATAN: password default mudah ditebak."
  echo "Ganti dengan password unik untuk keamanan lebih baik."
fi

OC_HOME="/home/opencode"
OC_CONFIG="/etc/opencode-web.env"
OC_PORT="4096"

echo "[1/6] Memasang dependensi..."
apt-get update
apt-get install -y curl ca-certificates

echo "[2/6] Menyiapkan akun service..."
if ! id opencode >/dev/null 2>&1; then
  useradd --system --create-home \
    --home-dir "$OC_HOME" \
    --shell /usr/sbin/nologin opencode
fi

mkdir -p "$OC_HOME/workspace"
chown -R opencode:opencode "$OC_HOME"

echo "[3/6] Menginstal OpenCode resmi..."
runuser -u opencode -- env HOME="$OC_HOME" \
  bash -c 'curl -fsSL https://opencode.ai/install | bash'

OC_BIN="$OC_HOME/.opencode/bin/opencode"

if [[ ! -x "$OC_BIN" ]]; then
  OC_BIN="$(find "$OC_HOME" -type f -name opencode -perm /111 \
    -print -quit 2>/dev/null || true)"
fi

if [[ -z "$OC_BIN" || ! -x "$OC_BIN" ]]; then
  echo "Binary OpenCode tidak ditemukan. Periksa instalasi."
  exit 1
fi

echo "[4/6] Menyimpan kredensial..."
umask 077
{
  printf 'OPENCODE_SERVER_USERNAME=%s\n' "$OC_USER"
  printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$OC_PASS"
} > "$OC_CONFIG"

chown root:root "$OC_CONFIG"
chmod 600 "$OC_CONFIG"

echo "[5/6] Membuat service systemd..."
cat > /etc/systemd/system/opencode-web.service <<UNIT
[Unit]
Description=OpenCode Web GUI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=opencode
Group=opencode
WorkingDirectory=/home/opencode/workspace
EnvironmentFile=/etc/opencode-web.env
Environment=HOME=/home/opencode
ExecStart=$OC_BIN web --hostname 127.0.0.1 --port $OC_PORT
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now opencode-web.service

echo "[6/6] Memeriksa status..."
sleep 2
systemctl --no-pager --full status opencode-web.service || true

echo
echo "========================================"
echo "       INSTALASI SELESAI"
echo "========================================"
echo "Port       : $OC_PORT (localhost saja)"
echo "Username   : $OC_USER"
echo "Password   : tersimpan di $OC_CONFIG"
echo "Izin file  : 600 (root only)"
echo
echo "Perintah status:"
echo "  systemctl status opencode-web"
echo
echo "Log:"
echo "  journalctl -u opencode-web -f"
echo
echo "Restart:"
echo "  systemctl restart opencode-web"
echo
echo "Jangan buka port 4096 ke internet."
echo "Gunakan SSH tunnel untuk akses browser."
