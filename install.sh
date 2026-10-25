#!/bin/bash
# ============================================================
#   CHANELOG VPN SCRIPT - INSTALLER (ALL-IN-ONE)
#   Supports: VMess, VLess, Trojan, Shadowsocks (WS+gRPC)
#             SSH-WS/SSL, SlowDNS
#   Repository: https://github.com/oghc93/xray-tun
# ============================================================

REPO="https://raw.githubusercontent.com/chanelog/bin/main"
RAW="https://raw.githubusercontent.com/oghc93/xray-tun/main"
SCRIPT_DIR="/etc/vpn-script"
BIN_DIR="/usr/local/bin"

# ─── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
DIM='\033[2m'

# ─── Check Root ────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} Script harus dijalankan sebagai root!"
  exit 1
fi

# ─── Check OS ──────────────────────────────────────────────
. /etc/os-release 2>/dev/null
if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
  echo -e "${RED}[ERROR]${NC} Script hanya mendukung Ubuntu/Debian!"
  exit 1
fi

# ─── Banner ────────────────────────────────────────────────
clear
echo -e "${CYAN}"
cat <<'EOF'
  ██████╗██╗  ██╗ █████╗ ███╗   ██╗███████╗██╗      ██████╗  ██████╗
 ██╔════╝██║  ██║██╔══██╗████╗  ██║██╔════╝██║     ██╔═══██╗██╔════╝
 ██║     ███████║███████║██╔██╗ ██║█████╗  ██║     ██║   ██║██║  ███╗
 ██║     ██╔══██║██╔══██║██║╚██╗██║██╔══╝  ██║     ██║   ██║██║   ██║
 ╚██████╗██║  ██║██║  ██║██║ ╚████║███████╗███████╗╚██████╔╝╚██████╔╝
  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝ ╚═════╝  ╚═════╝
EOF
echo -e "${NC}"
echo -e "${WHITE}        VPN TUNNEL SCRIPT - ALL-IN-ONE EDITION${NC}"
echo -e "${YELLOW}        ══════════════════════════════════════${NC}"
echo -e "${WHITE}        VMess | VLess | Trojan | SS | SSH-WS${NC}"
echo ""

# ─── Resolve domain -> IPv4 (tanpa bergantung dig; dig baru ada setelah install_deps) ─
resolve_a() {
  local d="$1" out=""
  if command -v dig >/dev/null 2>&1; then
    out=$(dig +short "$d" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
  fi
  if [[ -z "$out" ]] && command -v getent >/dev/null 2>&1; then
    out=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
  fi
  if [[ -z "$out" ]] && command -v host >/dev/null 2>&1; then
    out=$(host -t A "$d" 2>/dev/null | awk '/has address/{print $NF}')
  fi
  if [[ -z "$out" ]] && command -v nslookup >/dev/null 2>&1; then
    out=$(nslookup -type=A "$d" 2>/dev/null | awk '/^Address: /{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
  fi
  if [[ -z "$out" ]]; then
    out=$(curl -s --max-time 6 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${d}&type=A" 2>/dev/null \
          | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
  fi
  echo "$out"
}

# ─── Input Domain ──────────────────────────────────────────
ask_domain() {
  while true; do
    echo -e "${CYAN}[*]${NC} Masukkan domain yang sudah diarahkan ke IP server ini:"
    echo -ne "  ${WHITE}Domain${NC}: "
    read -r DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -z "$DOMAIN" ]]; then
      echo -e "${RED}[ERROR]${NC} Domain tidak boleh kosong!"
      continue
    fi

    if ! echo "$DOMAIN" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
      echo -e "${RED}[ERROR]${NC} Format domain tidak valid!"
      continue
    fi

    echo -e "${CYAN}[*]${NC} Memverifikasi domain ${WHITE}$DOMAIN${NC} → IP server..."
    SERVER_IP=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s4 --max-time 5 https://ipv4.icanhazip.com 2>/dev/null)
    DOMAIN_IPS=$(resolve_a "$DOMAIN")
    DOMAIN_IP=$(echo "$DOMAIN_IPS" | head -1)

    if [[ -z "$SERVER_IP" ]]; then
      echo -e "${YELLOW}[WARN]${NC} Tidak bisa cek IP server, lanjut tanpa verifikasi..."
      break
    fi

    if [[ -z "$DOMAIN_IP" ]]; then
      echo -e "${RED}[WARN]${NC} DNS domain belum ditemukan."
      echo -ne "  Lanjutkan meski DNS belum propagasi? [y/N]: "
      read -r FORCE
      [[ "$FORCE" =~ ^[Yy]$ ]] && break
      continue
    fi

    if echo "$DOMAIN_IPS" | grep -qxF "$SERVER_IP"; then
      echo -e "${GREEN}[OK]${NC} Domain ${WHITE}$DOMAIN${NC} → ${GREEN}$SERVER_IP${NC} ✓ VERIFIED"
      break
    else
      echo -e "${YELLOW}[WARN]${NC} Domain → $DOMAIN_IP, Server → $SERVER_IP (tidak cocok)"
      echo -ne "  Lanjutkan? [y/N]: "
      read -r FORCE
      [[ "$FORCE" =~ ^[Yy]$ ]] && break
    fi
  done
  echo "$DOMAIN" > /tmp/vpn_domain.tmp
}

# ─── Install Dependencies ──────────────────────────────────
install_deps() {
  echo -e "\n${CYAN}[*]${NC} Menginstall dependensi sistem..."
  apt-get update -qq 2>/dev/null
  apt-get install -y -qq \
    curl wget unzip zip socat tar \
    dnsutils net-tools \
    openssl ca-certificates \
    cron jq uuid-runtime python3 \
    iptables 2>/dev/null
  echo -e "${GREEN}[OK]${NC} Dependensi terinstall"
}

# ─── Install Nginx ─────────────────────────────────────────
install_nginx() {
  echo -e "\n${CYAN}[*]${NC} Menginstall Nginx..."
  apt-get install -y -qq nginx 2>/dev/null
  systemctl enable nginx 2>/dev/null
  echo -e "${GREEN}[OK]${NC} Nginx terinstall"
}

# ─── Install Dropbear ──────────────────────────────────────
install_dropbear() {
  echo -e "\n${CYAN}[*]${NC} Menginstall Dropbear SSH..."
  apt-get install -y -qq dropbear 2>/dev/null

  cat > /etc/default/dropbear <<EOF2
NO_START=0
DROPBEAR_PORT=442
DROPBEAR_EXTRA_ARGS="-p 109 -p 143 -b /etc/vpn-script/banner.txt"
DROPBEAR_BANNER="/etc/vpn-script/banner.txt"
DROPBEAR_RECEIVE_WINDOW=65536
EOF2

  systemctl enable dropbear 2>/dev/null
  systemctl restart dropbear 2>/dev/null

  # PENTING: Dropbear menolak login (dianggap 'incorrect password') untuk
  # akun dengan shell yang TIDAK terdaftar di /etc/shells - ini bawaan
  # Dropbear sendiri (bukan PAM). create_ssh() di lib.sh pakai -s /bin/false
  # supaya akun cuma bisa tunnel (gak bisa exec shell beneran), tapi kalau
  # /bin/false gak terdaftar di /etc/shells, SEMUA akun bakal gagal login
  # walau password benar. Daftarkan supaya diizinkan Dropbear, sementara
  # /bin/false sendiri tetap mencegah eksekusi shell interaktif.
  grep -qxF "/bin/false" /etc/shells 2>/dev/null || echo "/bin/false" >> /etc/shells

  echo -e "${GREEN}[OK]${NC} Dropbear terinstall (port: 442, 109, 143)"
}

# ─── Install Xray ──────────────────────────────────────────
install_xray() {
  echo -e "\n${CYAN}[*]${NC} Menginstall Xray dari chanelog/bin..."
  mkdir -p /usr/local/bin /etc/xray /var/log/xray

  ARCH=$(uname -m)
  if [[ "$ARCH" == "aarch64" ]]; then
    XRAY_ZIP="Xray-linux-arm64-v8a.zip"
  else
    XRAY_ZIP="Xray-linux-64.zip"
  fi

  # Coba dari chanelog/bin dulu
  wget -q "$REPO/$XRAY_ZIP" -O /tmp/xray.zip 2>/dev/null
  if [[ $? -ne 0 ]] || [[ ! -s /tmp/xray.zip ]]; then
    echo -e "${YELLOW}[WARN]${NC} Gagal dari chanelog/bin, coba install-release.sh..."
    wget -q "$REPO/install-release.sh" -O /tmp/install-release.sh 2>/dev/null
    if [[ -s /tmp/install-release.sh ]]; then
      chmod +x /tmp/install-release.sh
      bash /tmp/install-release.sh 2>/dev/null
    else
      # Fallback official GitHub
      echo -e "${YELLOW}[WARN]${NC} Fallback ke GitHub release..."
      XRAY_VER=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
      [[ -z "$XRAY_VER" ]] && XRAY_VER="v25.4.30"
      wget -q "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ZIP}" \
        -O /tmp/xray.zip 2>/dev/null
    fi
  fi

  if [[ -s /tmp/xray.zip ]]; then
    cd /tmp && unzip -qo xray.zip xray 2>/dev/null
    [[ -f /tmp/xray ]] && mv /tmp/xray /usr/local/bin/xray
  fi

  # Pastikan xray binary ada
  if [[ ! -f /usr/local/bin/xray ]]; then
    echo -e "${RED}[ERROR]${NC} Xray binary tidak ditemukan! Install manual."
    exit 1
  fi

  chmod +x /usr/local/bin/xray

  # jq
  if ! command -v jq &>/dev/null; then
    wget -q "$REPO/jq-linux-amd64" -O /usr/local/bin/jq 2>/dev/null
    chmod +x /usr/local/bin/jq 2>/dev/null
    command -v jq &>/dev/null || apt-get install -y -qq jq 2>/dev/null
  fi

  # Systemd service
  cat > /etc/systemd/system/xray.service <<EOF2
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable xray
  echo -e "${GREEN}[OK]${NC} Xray terinstall ($(xray version 2>/dev/null | head -1))"
}

# ─── Configure Nginx (ALL-IN-ONE) ──────────────────────────
configure_nginx() {
  local domain="$1"
  mkdir -p /etc/nginx/conf.d /var/www/html

  # Hapus default nginx config yang conflict
  rm -f /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/conf.d/default.conf

  cat > /etc/nginx/conf.d/xray.conf <<EOF2
# ============================================================
#   CHANELOG VPN - NGINX ALL-IN-ONE CONFIG
#   Port 80  : VMess nTLS | VLess nTLS | SSH-WS nTLS | SlowDNS
#   Port 443 : VMess TLS | VLess TLS | Trojan TLS | SS TLS
#              VMess gRPC | VLess gRPC | Trojan gRPC | SS gRPC
#              SSH-WS TLS
#   Port 8880/8080/2080/2082 : SSH-WS nTLS (alternatif)
# ============================================================

# ─── Port 80 — non-TLS ───
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    include /etc/nginx/snippets/vpn-ovpn-*.conf; # vpn-ovpn-ws

    # VMess WebSocket non-TLS
    location /vmess-ntls {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    # VLess WebSocket non-TLS
    location /vless-ntls {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10004;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    # SSH-WS non-TLS (backend: Dropbear)
    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2095;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    # SSH-WS-SSH non-TLS (backend: OpenSSH)
    location /ssh-ws-ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2093;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    # SSH-WS nTLS path "/" -> OpenSSH (ws-openssh). Dipakai payload bertipe
    # "BMOVE / [protocol] ... Upgrade: websocket". Request biasa tetap di-redirect ke HTTPS.
    location / {
        if (\$http_upgrade !~* "websocket") { return 301 https://\$host\$request_uri; }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2093;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }
}

# ─── Port 8880 — SSH-WS nTLS (alt) ───
server {
    listen 8880;
    listen [::]:8880;
    server_name ${domain};

    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2095;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location /ssh-ws-ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2093;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# ─── Port 8080 — SSH-WS nTLS (alt) ───
server {
    listen 8080;
    listen [::]:8080;
    server_name ${domain};

    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2095;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location /ssh-ws-ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2093;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# ─── Port 2080 — SSH-WS nTLS (alt) ───
server {
    listen 2080;
    listen [::]:2080;
    server_name ${domain};

    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2095;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location /ssh-ws-ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2093;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# ─── Port 2082 — SSH-WS nTLS (alt) ───
server {
    listen 2082;
    listen [::]:2082;
    server_name ${domain};

    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2095;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location /ssh-ws-ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2093;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# ─── Port 443 — HTTPS/TLS (ALL PROTOCOLS) ───
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};
    include /etc/nginx/snippets/vpn-ovpn-*.conf; # vpn-ovpn-ws

    ssl_certificate /etc/ssl/xray/xray.crt;
    ssl_certificate_key /etc/ssl/xray/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # ═══════════════════════════════════════════════════════════
    #  TROJAN
    # ═══════════════════════════════════════════════════════════
    location /trojan-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10005;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location /trojan-grpc {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header Host \$host;
        grpc_pass grpc://127.0.0.1:10006;
        grpc_connect_timeout 60s;
        grpc_read_timeout 3600s;
    }

    # ═══════════════════════════════════════════════════════════
    #  SHADOWSOCKS
    # ═══════════════════════════════════════════════════════════
    location /ss-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10007;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location /ss-grpc {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header Host \$host;
        grpc_pass grpc://127.0.0.1:10008;
        grpc_connect_timeout 60s;
        grpc_read_timeout 3600s;
    }

    # ═══════════════════════════════════════════════════════════
    #  VLESS
    # ═══════════════════════════════════════════════════════════
    location /vless-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location /vless-grpc {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header Host \$host;
        grpc_pass grpc://127.0.0.1:10009;
        grpc_connect_timeout 60s;
        grpc_read_timeout 3600s;
    }

    # ═══════════════════════════════════════════════════════════
    #  VMESS
    # ═══════════════════════════════════════════════════════════
    location /vmess-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    location /vmess-grpc {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header Host \$host;
        grpc_pass grpc://127.0.0.1:10010;
        grpc_connect_timeout 60s;
        grpc_read_timeout 3600s;
    }

    # ═══════════════════════════════════════════════════════════
    #  SSH-WS TLS (backend: Dropbear)
    # ═══════════════════════════════════════════════════════════
    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2095;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    # ═══════════════════════════════════════════════════════════
    #  SSH-WS-SSH TLS (backend: OpenSSH)
    # ═══════════════════════════════════════════════════════════
    location /ssh-ws-ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2093;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
    }

    # ═══════════════════════════════════════════════════════════
    #  FAKE WEBSITE (fallback)
    # ═══════════════════════════════════════════════════════════
    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF2

  cat > /var/www/html/index.html <<EOF2
<!DOCTYPE html>
<html>
<head><title>${domain}</title></head>
<body style="background:#1a1a2e;color:#e0e0e0;font-family:monospace;text-align:center;padding:50px">
<h1 style="color:#00d4ff">Server Running</h1>
<p>Secure VPN Tunnel Server</p>
</body>
</html>
EOF2

  nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null
  echo -e "${GREEN}[OK]${NC} Nginx dikonfigurasi (All-in-One)"
}

# ─── Generate Xray Config (ALL-IN-ONE) ─────────────────────
generate_xray_config() {
  mkdir -p /etc/vpn-script/db
  touch /etc/vpn-script/db/vmess.db
  touch /etc/vpn-script/db/vless.db
  touch /etc/vpn-script/db/trojan.db
  touch /etc/vpn-script/db/ss.db

  cat > /etc/xray/config.json <<'XRAYEOF'
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log",
    "access": "/var/log/xray/access.log"
  },
  "inbounds": [
    {
      "tag": "vmess-ws-tls",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess-ws" }
      }
    },
    {
      "tag": "vless-ws-tls",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless-ws" }
      }
    },
    {
      "tag": "vmess-ws-ntls",
      "port": 10003,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess-ntls" }
      }
    },
    {
      "tag": "vless-ws-ntls",
      "port": 10004,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless-ntls" }
      }
    },
    {
      "tag": "trojan-ws-tls",
      "port": 10005,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/trojan-ws" }
      }
    },
    {
      "tag": "trojan-grpc-tls",
      "port": 10006,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": { "serviceName": "trojan-grpc" }
      }
    },
    {
      "tag": "ss-ws-tls",
      "port": 10007,
      "listen": "127.0.0.1",
      "protocol": "shadowsocks",
      "settings": {
        "clients": [],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/ss-ws" }
      }
    },
    {
      "tag": "ss-grpc-tls",
      "port": 10008,
      "listen": "127.0.0.1",
      "protocol": "shadowsocks",
      "settings": {
        "clients": [],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": { "serviceName": "ss-grpc" }
      }
    },
    {
      "tag": "vless-grpc-tls",
      "port": 10009,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": { "serviceName": "vless-grpc" }
      }
    },
    {
      "tag": "vmess-grpc-tls",
      "port": 10010,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": { "serviceName": "vmess-grpc" }
      }
    },
    {
      "tag": "api",
      "port": 10085,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} },
    { "protocol": "freedom", "tag": "api", "settings": {} }
  ],
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "levels": {
      "0": { "statsUserUplink": true, "statsUserDownlink": true, "statsUserOnline": true }
    },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" }
    ]
  }
}
XRAYEOF

  echo -e "${GREEN}[OK]${NC} Xray config dibuat (All-in-One)"
}

# ─── Install SSL via acme.sh ───────────────────────────────
install_ssl() {
  local domain="$1"
  echo -e "\n${CYAN}[*]${NC} Menginstall acme.sh dari chanelog/bin..."
  mkdir -p /etc/ssl/xray

  wget -q "$REPO/acme.sh" -O /tmp/acme_install.sh 2>/dev/null
  if [[ -s /tmp/acme_install.sh ]]; then
    chmod +x /tmp/acme_install.sh
    bash /tmp/acme_install.sh --install-online -m "admin@${domain}" 2>/dev/null || \
    bash /tmp/acme_install.sh -m "admin@${domain}" 2>/dev/null
  fi

  if [[ ! -f /root/.acme.sh/acme.sh ]]; then
    echo -e "${YELLOW}[WARN]${NC} Fallback install acme.sh dari official..."
    curl -s https://get.acme.sh | bash -s email="admin@${domain}" 2>/dev/null
  fi

  if [[ ! -f /root/.acme.sh/acme.sh ]]; then
    echo -e "${RED}[ERROR]${NC} acme.sh gagal diinstall!"
    echo -e "${YELLOW}[WARN]${NC} Membuat self-signed cert sementara..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -keyout /etc/ssl/xray/xray.key \
      -out /etc/ssl/xray/xray.crt \
      -days 365 -nodes \
      -subj "/CN=${domain}" 2>/dev/null
    return
  fi

  systemctl stop nginx 2>/dev/null
  sleep 1

  echo -e "${CYAN}[*]${NC} Meminta SSL certificate untuk ${WHITE}$domain${NC}..."

  /root/.acme.sh/acme.sh --register-account -m "admin@${domain}" --server letsencrypt >/dev/null 2>&1

  /root/.acme.sh/acme.sh --issue \
    --standalone \
    -d "$domain" \
    --keylength ec-256 \
    --httpport 80 \
    --server letsencrypt \
    --force >/tmp/acme_issue.log 2>&1

  if [[ $? -ne 0 ]]; then
    echo -e "${YELLOW}[WARN]${NC} Let's Encrypt gagal, coba ZeroSSL... (sebab: $(grep -iE 'error|invalid|fail|timeout|refused' /tmp/acme_issue.log | tail -2 | tr '\n' ' '))"
    /root/.acme.sh/acme.sh --set-default-ca --server zerossl 2>/dev/null
    /root/.acme.sh/acme.sh --issue \
      --standalone \
      -d "$domain" \
      --keylength ec-256 \
      --httpport 80 \
      --force 2>/dev/null
  fi

  /root/.acme.sh/acme.sh --installcert -d "$domain" \
    --ecc \
    --key-file /etc/ssl/xray/xray.key \
    --fullchain-file /etc/ssl/xray/xray.crt \
    --reloadcmd "cat /etc/ssl/xray/xray.crt /etc/ssl/xray/xray.key > /etc/ssl/xray/xray.pem 2>/dev/null; chmod 600 /etc/ssl/xray/xray.pem; systemctl restart xray nginx 2>/dev/null; systemctl reload haproxy 2>/dev/null" 2>/dev/null

  chmod 644 /etc/ssl/xray/xray.key 2>/dev/null
  chmod 644 /etc/ssl/xray/xray.crt 2>/dev/null

  if [[ ! -s /etc/ssl/xray/xray.crt ]]; then
    echo -e "${YELLOW}[WARN]${NC} SSL gagal, membuat self-signed cert sementara..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -keyout /etc/ssl/xray/xray.key \
      -out /etc/ssl/xray/xray.crt \
      -days 365 -nodes \
      -subj "/CN=${domain}" 2>/dev/null
  fi

  # Selalu pastikan file gabungan (dibutuhkan HAProxy: SSH-SSL port 444 & multiplex 443)
  # ada dan sinkron dengan crt/key terbaru, apapun jalur di atas yang kepakai.
  cat /etc/ssl/xray/xray.crt /etc/ssl/xray/xray.key > /etc/ssl/xray/xray.pem 2>/dev/null
  chmod 600 /etc/ssl/xray/xray.pem 2>/dev/null

  systemctl start nginx 2>/dev/null

  # Tampilkan info sertifikat yang benar-benar terpasang
  local c_issuer c_subject c_end
  c_issuer=$(openssl x509 -in /etc/ssl/xray/xray.crt -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
  c_subject=$(openssl x509 -in /etc/ssl/xray/xray.crt -noout -subject 2>/dev/null | sed 's/^subject= *//')
  c_end=$(openssl x509 -in /etc/ssl/xray/xray.crt -noout -enddate 2>/dev/null | cut -d= -f2)
  echo -e "  ${DIM}Subject  :${NC} ${c_subject:-?}"
  echo -e "  ${DIM}Issuer   :${NC} ${c_issuer:-?}"
  echo -e "  ${DIM}Berlaku s/d:${NC} ${c_end:-?}"
  if [[ -n "$c_issuer" && "${c_issuer#CN = }" == "${c_subject#CN = }" ]] || [[ "$c_issuer" == "$c_subject" ]]; then
    echo -e "${YELLOW}[WARN]${NC} Sertifikat self-signed (cadangan), browser akan menampilkan 'tidak aman'."
    echo -e "       Terbitkan ulang nanti: menu 09 Change Domain, atau acme.sh --issue --server letsencrypt"
  else
    echo -e "${GREEN}[OK]${NC} SSL Certificate resmi terpasang untuk $domain"
  fi
}

# ─── Download & Install Script Files ──────────────────────
install_script_files() {
  local domain="$1"

  echo -e "\n${CYAN}[*]${NC} Mendownload script files dari GitHub..."
  mkdir -p $SCRIPT_DIR/db $SCRIPT_DIR/menu

  echo "$domain" > $SCRIPT_DIR/domain
  echo "$domain" > $SCRIPT_DIR/db/domain

  local ok=true
  for f in menu.sh lib.sh; do
    echo -ne "  Downloading $f..."
    wget -q --timeout=30 "$RAW/$f" -O "$SCRIPT_DIR/$f"
    if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/$f" ]]; then
      echo -e " ${RED}GAGAL${NC}"
      ok=false
    else
      echo -e " ${GREEN}OK${NC}"
    fi
  done

  for f in vmess vless trojan ss nginx dropbear haproxy sysinfo changedomain uninstall sshws services update telegram rebuild panel bbr openvpn security tools backup; do
    echo -ne "  Downloading menu/${f}.sh..."
    wget -q --timeout=30 "$RAW/menu/${f}.sh" -O "$SCRIPT_DIR/menu/${f}.sh"
    if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/menu/${f}.sh" ]]; then
      echo -e " ${RED}GAGAL${NC}"
      ok=false
    else
      echo -e " ${GREEN}OK${NC}"
    fi
  done

  mkdir -p "$SCRIPT_DIR/addon"
  echo -ne "  Downloading addon/torrent-block.sh..."
  if wget -q --timeout=30 "$RAW/addon/torrent-block.sh" -O "$SCRIPT_DIR/addon/torrent-block.sh" && [[ -s "$SCRIPT_DIR/addon/torrent-block.sh" ]]; then
    echo -e " ${GREEN}OK${NC}"
  else
    echo -e " ${RED}GAGAL${NC}"; ok=false
  fi

  echo -ne "  Downloading addon/tg-backup.py..."
  if wget -q --timeout=30 "$RAW/addon/tg-backup.py" -O "$SCRIPT_DIR/addon/tg-backup.py" && [[ -s "$SCRIPT_DIR/addon/tg-backup.py" ]]; then
    chmod +x "$SCRIPT_DIR/addon/tg-backup.py"
    echo -e " ${GREEN}OK${NC}"
  else
    echo -e " ${YELLOW}SKIP (fitur backup tidak terpasang)${NC}"
    rm -f "$SCRIPT_DIR/addon/tg-backup.py"
  fi

  if [[ "$ok" == "false" ]]; then
    echo -e "${RED}[ERROR]${NC} Beberapa file gagal didownload!"
    exit 1
  fi

  mkdir -p "$SCRIPT_DIR/addon"
  echo -ne "  Downloading addon/install-sshws.sh..."
  wget -q --timeout=30 "$RAW/addon/install-sshws.sh" -O "$SCRIPT_DIR/addon/install-sshws.sh"
  if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/addon/install-sshws.sh" ]]; then
    echo -e " ${YELLOW}SKIP (belum ada di repo)${NC}"
    rm -f "$SCRIPT_DIR/addon/install-sshws.sh"
  else
    echo -e " ${GREEN}OK${NC}"
  fi

  echo -ne "  Downloading addon/haproxy-sshws-ssl.sh..."
  wget -q --timeout=30 "$RAW/addon/haproxy-sshws-ssl.sh" -O "$SCRIPT_DIR/addon/haproxy-sshws-ssl.sh"
  if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/addon/haproxy-sshws-ssl.sh" ]]; then
    echo -e " ${YELLOW}SKIP (belum ada di repo)${NC}"
    rm -f "$SCRIPT_DIR/addon/haproxy-sshws-ssl.sh"
  else
    echo -e " ${GREEN}OK${NC}"
  fi

  echo -ne "  Downloading addon/enable-ssl-multiplex.sh..."
  wget -q --timeout=30 "$RAW/addon/enable-ssl-multiplex.sh" -O "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh"
  if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh" ]]; then
    echo -e " ${YELLOW}SKIP (belum ada di repo)${NC}"
    rm -f "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh"
  else
    echo -e " ${GREEN}OK${NC}"
  fi

  # sshws-pro.sh (orkestrator) & badvpn-udpgw.sh (UDPGW 7300) -- tanpa dua file
  # ini install.sh jatuh ke cabang elif dan UDPGW tidak pernah terpasang.
  for f in sshws-pro.sh badvpn-udpgw.sh; do
    echo -ne "  Downloading addon/$f..."
    wget -q --timeout=30 "$RAW/addon/$f" -O "$SCRIPT_DIR/addon/$f"
    if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/addon/$f" ]]; then
      echo -e " ${YELLOW}SKIP (belum ada di repo)${NC}"
      rm -f "$SCRIPT_DIR/addon/$f"
    else
      echo -e " ${GREEN}OK${NC}"
    fi
  done

  for f in ssh-maxlogin.sh dropbear-fastkick.sh xray-maxlogin-daemon.sh quota-limiter.sh; do
    echo -ne "  Downloading addon/$f..."
    wget -q --timeout=30 "$RAW/addon/$f" -O "$SCRIPT_DIR/addon/$f"
    if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/addon/$f" ]]; then
      echo -e " ${YELLOW}GAGAL, coba lagi dari cadangan lokal...${NC}"
      ok=false
    else
      echo -e " ${GREEN}OK${NC}"
    fi
  done

  mkdir -p "$SCRIPT_DIR/addon/maxlogin"
  for f in maxlogin_core.py maxlogin_service.py xray_adapter.py maxlogin-xray.sh install-maxlogin.sh \
           nginx-maxlogin.inc nginx-maxlogin-http.inc vpn-maxlogin.service maxlogin.json.example; do
    echo -ne "  Downloading addon/maxlogin/$f..."
    wget -q --timeout=30 "$RAW/addon/maxlogin/$f" -O "$SCRIPT_DIR/addon/maxlogin/$f"
    if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/addon/maxlogin/$f" ]]; then
      echo -e " ${YELLOW}SKIP${NC}"; rm -f "$SCRIPT_DIR/addon/maxlogin/$f"
    else
      echo -e " ${GREEN}OK${NC}"
    fi
  done
  chmod +x "$SCRIPT_DIR"/addon/maxlogin/*.sh 2>/dev/null

  for f in dropbear-fastkick.service xray-maxlogin.service; do
    echo -ne "  Downloading systemd/$f..."
    mkdir -p "$SCRIPT_DIR/systemd"
    wget -q --timeout=30 "$RAW/systemd/$f" -O "$SCRIPT_DIR/systemd/$f"
    if [[ $? -ne 0 ]] || [[ ! -s "$SCRIPT_DIR/systemd/$f" ]]; then
      echo -e " ${YELLOW}GAGAL${NC}"
      ok=false
    else
      echo -e " ${GREEN}OK${NC}"
    fi
  done

  wget -q --timeout=30 "$RAW/VERSION" -O "$SCRIPT_DIR/VERSION" 2>/dev/null
  [[ -s "$SCRIPT_DIR/VERSION" ]] || echo "2.0.0" > "$SCRIPT_DIR/VERSION"

  chmod +x $SCRIPT_DIR/*.sh 2>/dev/null
  chmod +x $SCRIPT_DIR/menu/*.sh 2>/dev/null
  chmod +x $SCRIPT_DIR/addon/*.sh 2>/dev/null

  ln -sf $SCRIPT_DIR/menu.sh $BIN_DIR/vpn
  chmod +x $BIN_DIR/vpn

  # vpn-update: updater panel web (dipakai menu 14 "Update Panel Web")
  wget -q --timeout=30 "https://raw.githubusercontent.com/oghc93/cocote-3x-ui/main/deploy/update.sh" -O "$BIN_DIR/vpn-update" 2>/dev/null
  if [[ -s "$BIN_DIR/vpn-update" ]]; then chmod +x "$BIN_DIR/vpn-update"; else rm -f "$BIN_DIR/vpn-update"; fi

  # Server Message (banner SSH) -- tampil berwarna di DarkTunnel & app sejenis (tag HTML)
  cat > "$SCRIPT_DIR/banner.txt" <<'BANNER_EOF'
<br><br>
<font color="#2979FF">━━━━━━━━━━</font><font color="#A020F0">ஜ۩۞۩ஜ</font><font color="#2979FF">━━━━━━━━━━</font><br><br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<b><font color="#006D8F">--- ✦ by CHANEL-OG ✦ ---</font></b><br><br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<font color="#FF1744">! TERM OF SERVICE !</font><br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<font color="#2979FF">NO SPAM</font><br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<font color="#2979FF">NO DDOS</font><br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<font color="#00B0FF">NO HACKING AND CARDING</font><br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<font color="#FF1744">NO TORRENT!!</font><br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<font color="#FF1493">NO MULTI LOGIN!!</font><br>
<br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<font color="#00B0FF">==ENJOOOOY==</font><br><br>
<font color="#2979FF">━━━━━━━━━━</font><font color="#A020F0">ஜ۩۞۩ஜ</font><font color="#2979FF">━━━━━━━━━━</font><br>
BANNER_EOF

  # Banner yang sama untuk OpenSSH (WS-TLS 443 & SSL)
  ( source "$SCRIPT_DIR/lib.sh" 2>/dev/null; ensure_ssh_banner ) >/dev/null 2>&1 || true

  echo -e "${GREEN}[OK]${NC} Script files terinstall"
}

# ─── Setup Cron ────────────────────────────────────────────
setup_cron() {
  crontab -l 2>/dev/null | grep -v "vpn-script\|acme.sh --cron" | crontab -
  (crontab -l 2>/dev/null; echo "*/5 * * * * bash $SCRIPT_DIR/lib.sh delete_expired >> /var/log/vpn-cleanup.log 2>&1") | crontab -
  (crontab -l 2>/dev/null; echo "0 3 * * * /root/.acme.sh/acme.sh --cron >> /var/log/acme-renew.log 2>&1") | crontab -
  echo -e "${GREEN}[OK]${NC} Cron jobs dikonfigurasi"
}

# ─── Setup Maxlogin (PAM OpenSSH + daemon Dropbear + daemon Xray) ─
# Arsitektur: Dropbear = WS nTLS saja, OpenSSH = WS-TLS (443) + SSL.
# OpenSSH dilindungi PAM maxlogins (preventive); Dropbear & Xray
# dilindungi daemon reaktif (poll 5s + cooldown 30s per akun).
setup_maxlogin() {
  chmod +x "$SCRIPT_DIR/addon/ssh-maxlogin.sh" 2>/dev/null

  if [[ -x "$SCRIPT_DIR/addon/ssh-maxlogin.sh" ]]; then
    bash "$SCRIPT_DIR/addon/ssh-maxlogin.sh" install
  else
    echo -e "${YELLOW}[SKIP]${NC} addon/ssh-maxlogin.sh tidak ada, PAM maxlogins dilewati."
  fi

  if [[ -f "$SCRIPT_DIR/systemd/dropbear-fastkick.service" ]]; then
    cp "$SCRIPT_DIR/systemd/dropbear-fastkick.service" /etc/systemd/system/dropbear-fastkick.service
    chmod +x "$SCRIPT_DIR/addon/dropbear-fastkick.sh" 2>/dev/null
    systemctl daemon-reload
    systemctl enable dropbear-fastkick.service >/dev/null 2>&1
    systemctl restart dropbear-fastkick.service 2>/dev/null
    echo -e "${GREEN}[OK]${NC} dropbear-fastkick aktif (limiter nTLS)"
  fi

  if [[ -f "$SCRIPT_DIR/systemd/xray-maxlogin.service" ]]; then
    cp "$SCRIPT_DIR/systemd/xray-maxlogin.service" /etc/systemd/system/xray-maxlogin.service
    chmod +x "$SCRIPT_DIR/addon/xray-maxlogin-daemon.sh" 2>/dev/null
    systemctl daemon-reload
    systemctl enable xray-maxlogin.service >/dev/null 2>&1
    systemctl restart xray-maxlogin.service 2>/dev/null
    echo -e "${GREEN}[OK]${NC} xray-maxlogin-daemon aktif"
  fi
}

# ─── Firewall ──────────────────────────────────────────────
setup_firewall() {
  for port in 22 80 443 109 143 442 8880 8080 2080 2082 5300; do
    iptables -I INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
  done
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null
  echo -e "${GREEN}[OK]${NC} Firewall dikonfigurasi"
}

# ─── BadVPN UDPGW (default 127.0.0.1:7300) ───────────────────
# Selalu dipastikan terpasang, apa pun cabang addon SSH-WS yang jalan.
# Idempotent: kalau port 7300 sudah listen (mis. dari sshws-pro.sh) dilewati.
setup_udpgw() {
  if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:7300"; then
    echo -e "${GREEN}[OK]${NC} BadVPN UDPGW sudah aktif di 127.0.0.1:7300"
    return 0
  fi
  if [[ -f "$SCRIPT_DIR/addon/badvpn-udpgw.sh" ]]; then
    echo ""
    echo -e "${CYAN}[*]${NC} Memasang BadVPN UDPGW (default port 7300)..."
    bash "$SCRIPT_DIR/addon/badvpn-udpgw.sh" install \
      || echo -e "${YELLOW}[WARN]${NC} UDPGW gagal terpasang, bisa diulang: bash $SCRIPT_DIR/addon/badvpn-udpgw.sh install"
  else
    echo -e "${YELLOW}[INFO]${NC} addon/badvpn-udpgw.sh tidak ada di repo, UDPGW dilewati."
  fi
}

# ─── Main ──────────────────────────────────────────────────
main() {
  clear
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  echo -e "${WHITE}   CHANELOG VPN SCRIPT - ALL-IN-ONE INSTALLER   ${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  echo ""

  ask_domain
  DOMAIN=$(cat /tmp/vpn_domain.tmp)
  rm -f /tmp/vpn_domain.tmp

  echo -e "\n${YELLOW}[INFO]${NC} Domain : ${WHITE}$DOMAIN${NC}"
  echo -ne "  Lanjutkan instalasi? [Y/n]: "
  read -r CONFIRM
  [[ "$CONFIRM" =~ ^[Nn]$ ]] && exit 0

  # Bot Telegram (opsional): untuk notifikasi akun + Backup/Restore. Enter = lewati,
  # bisa diisi nanti lewat menu "Backup & Restore" atau "Bot Telegram".
  echo ""
  echo -e "${CYAN}[*]${NC} Bot Telegram ${DIM}(opsional, Enter untuk lewati; bisa diisi nanti lewat menu)${NC}"
  echo -e "  ${DIM}Token dari @BotFather, Chat ID dari @userinfobot${NC}"
  echo -ne "  ${WHITE}Bot Token${NC}: "
  read -r TG_TOKEN_IN
  TG_CHAT_IN=""
  if [[ -n "$TG_TOKEN_IN" ]]; then
    echo -ne "  ${WHITE}Chat ID${NC}  : "
    read -r TG_CHAT_IN
  fi

  install_deps
  install_nginx
  install_dropbear
  install_xray
  generate_xray_config
  configure_nginx "$DOMAIN"
  install_ssl "$DOMAIN"
  install_script_files "$DOMAIN"
  setup_cron
  setup_maxlogin
  # MaxLogin Xray (batas perangkat via token): aktif otomatis di instalasi baru
  if [[ -f "$SCRIPT_DIR/addon/maxlogin/maxlogin-xray.sh" ]]; then
    if bash "$SCRIPT_DIR/addon/maxlogin/maxlogin-xray.sh" on >/tmp/maxlogin-install.log 2>&1; then
      echo -e "${GREEN}[OK]${NC} MaxLogin Xray aktif (batas perangkat via token)"
    else
      echo -e "${YELLOW}[SKIP]${NC} MaxLogin Xray belum aktif (lihat /tmp/maxlogin-install.log; aktifkan nanti: bash $SCRIPT_DIR/addon/maxlogin/maxlogin-xray.sh on)"
    fi
  fi
  ( source "$SCRIPT_DIR/lib.sh"; setup_quota_limiter ) >/dev/null 2>&1 && echo -e "${GREEN}[OK]${NC} Pencatat pemakaian & kuota (quota-limiter) aktif"
  setup_firewall

  systemctl daemon-reload 2>/dev/null
  systemctl restart xray 2>/dev/null
  systemctl restart nginx 2>/dev/null
  systemctl restart dropbear 2>/dev/null

  if [[ -f "$SCRIPT_DIR/addon/sshws-pro.sh" ]]; then
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}   MELANJUTKAN INSTALL: SSH-WS/SSL + MULTIPLEX + PRO   ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${DIM}   (SSH-WS, HAProxy, Multiplex 443, BadVPN UDPGW,${NC}"
    echo -e "${DIM}    auto-restart semua service -- otomatis sekali jalan)${NC}"
    bash "$SCRIPT_DIR/addon/sshws-pro.sh" install
    ADDON_INSTALLED=true
  elif [[ -f "$SCRIPT_DIR/addon/install-sshws.sh" ]]; then
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}   MELANJUTKAN INSTALL ADDON: SSH-WS / SSH-SSL    ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    bash "$SCRIPT_DIR/addon/install-sshws.sh"
    ADDON_INSTALLED=true

    if [[ -f "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh" ]]; then
      echo ""
      echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
      echo -e "${WHITE}   MENGAKTIFKAN MULTIPLEX 443 (SNI bebas)   ${NC}"
      echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
      chmod +x "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh"
      bash "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh" enable
    else
      echo -e "\n${YELLOW}[INFO]${NC} addon/enable-ssl-multiplex.sh tidak ditemukan di repo, multiplex 443 dilewati (SSH-WS TLS & SSH-SSL tetap jalan lewat path/port masing-masing, tapi gak bisa pakai SNI bebas di 443)."
    fi
  else
    echo -e "\n${YELLOW}[INFO]${NC} addon SSH-WS tidak ditemukan di repo, fitur SSH-WS/SSL dilewati."
    ADDON_INSTALLED=false
  fi

  setup_udpgw

  # Simpan token Telegram (kalau diisi) lalu pasang bot Backup/Restore
  if [[ -n "$TG_TOKEN_IN" && -n "$TG_CHAT_IN" ]]; then
    TELEGRAM_BOT_TOKEN="$TG_TOKEN_IN"; TELEGRAM_CHAT_ID="$TG_CHAT_IN"
    ( source "$SCRIPT_DIR/lib.sh"; TELEGRAM_BOT_TOKEN="$TG_TOKEN_IN"; TELEGRAM_CHAT_ID="$TG_CHAT_IN"; save_pro_config ) >/dev/null 2>&1
  elif [[ -n "$TG_TOKEN_IN" ]]; then
    echo -e "${YELLOW}[INFO]${NC} Chat ID kosong, token Telegram tidak disimpan. Isi lewat menu Backup & Restore."
  fi
  [[ -f "$SCRIPT_DIR/menu/backup.sh" ]] && bash "$SCRIPT_DIR/menu/backup.sh" install
  # Rotasi log (cegah log membengkak); aman kalau gagal
  bash "$SCRIPT_DIR/menu/tools.sh" logrotate -y >/dev/null 2>&1 || true

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║       ✓  INSTALASI BERHASIL SELESAI!             ║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║${NC}  Domain     : ${WHITE}$DOMAIN${NC}"
  echo -e "${GREEN}║${NC}  Xray       : $(systemctl is-active xray 2>/dev/null)"
  echo -e "${GREEN}║${NC}  Nginx      : $(systemctl is-active nginx 2>/dev/null)"
  echo -e "${GREEN}║${NC}  Dropbear   : $(systemctl is-active dropbear 2>/dev/null)"
  echo -e "${GREEN}║${NC}  PAM maxlogins (OpenSSH) : terpasang"
  echo -e "${GREEN}║${NC}  dropbear-fastkick       : $(systemctl is-active dropbear-fastkick 2>/dev/null)"
  echo -e "${GREEN}║${NC}  xray-maxlogin-daemon    : $(systemctl is-active xray-maxlogin 2>/dev/null)"
  if [[ "$ADDON_INSTALLED" == "true" ]]; then
    echo -e "${GREEN}║${NC}  Stunnel4    : $(systemctl is-active stunnel4 2>/dev/null)"
    echo -e "${GREEN}║${NC}  WS-Dropbear : $(systemctl is-active ws-dropbear 2>/dev/null)"
    echo -e "${GREEN}║${NC}  WS-OpenSSH  : $(systemctl is-active ws-openssh 2>/dev/null)"
    echo -e "${GREEN}║${NC}  HAProxy     : $(systemctl is-active haproxy 2>/dev/null)"
    if [[ -f "$SCRIPT_DIR/.multiplex-443-active" ]]; then
      echo -e "${GREEN}║${NC}  Multiplex 443: aktif (SNI bebas)"
    fi
  fi
  echo -e "${GREEN}║${NC}  BadVPN UDPGW: $(systemctl is-active badvpn-udpgw 2>/dev/null || echo 'tidak terinstall') (127.0.0.1:7300)"
  echo -e "${GREEN}║${NC}  Jalankan   : ${CYAN}vpn${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""

  bash $SCRIPT_DIR/menu.sh
}

main "$@"
