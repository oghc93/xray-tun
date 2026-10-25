#!/bin/bash
# ============================================================
#   CHANELOG VPN SCRIPT - OPENVPN (ADDON)
#
#   OpenVPN TCP + UDP yang login-nya memakai AKUN SSH YANG SAMA
#   (username & password dari menu SSH). Jadi tidak ada database
#   akun baru: buat/hapus/perpanjang akun SSH = otomatis berlaku
#   untuk OpenVPN juga (akun expired dihapus cron, dan pam_unix
#   menolak akun yang sudah lewat tanggal expired-nya).
#
#   Lewat menu : vpn -> [16] OpenVPN
#   Langsung   : bash openvpn.sh install [-y]
#                bash openvpn.sh uninstall [-y]
#                bash openvpn.sh status | online | client-files
#                bash openvpn.sh kick USERNAME
#                bash openvpn.sh nat-apply | nat-remove   (dipakai service boot)
#
#   Catatan desain:
#   - Tanpa sertifikat client (verify-client-cert none): cukup file
#     .ovpn + username/password. CA & sertifikat server dibuat dengan
#     openssl, dan dipakai ulang kalau install diulang.
#   - 1 sesi per akun: login kedua dengan username yang sama memutus
#     sesi pertama (perilaku bawaan OpenVPN tanpa duplicate-cn).
#   - Tanpa tls-crypt supaya kompatibel dengan app OpenVPN bawaan
#     HTTP Injector/HTTP Custom dan sejenisnya.
# ============================================================

SCRIPT_DIR="${VPN_SCRIPT_DIR:-/etc/vpn-script}"
source "$SCRIPT_DIR/lib.sh"

OVPN_DIR="${OVPN_DIR:-/etc/openvpn/vpn-script}"
OVPN_SERVER_DIR="${OVPN_SERVER_DIR:-/etc/openvpn/server}"
OVPN_CLIENT_DIR="${OVPN_CLIENT_DIR:-$SCRIPT_DIR/ovpn}"
OVPN_CONF="$OVPN_DIR/ovpn.conf"
PAM_FILE="${PAM_FILE:-/etc/pam.d/vpn-script-ovpn}"
SYSCTL_DIR="${SYSCTL_DIR:-/etc/sysctl.d}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
NAT_UNIT="$UNIT_DIR/vpn-ovpn-nat.service"
STATUS_DIR="${OVPN_STATUS_DIR:-/run/openvpn-server}"

SVC_TCP="vpn-script-tcp"
SVC_UDP="vpn-script-udp"
TCP_NET="10.8.0.0"
UDP_NET="10.9.0.0"
NETMASK="255.255.255.0"
MGMT_TCP=7505
MGMT_UDP=7506
DEF_TCP_PORT=1194
DEF_UDP_PORT=2200
TORRENT_CHAIN="VPN_TORRENT"

# OpenVPN lewat WebSocket (nTLS port 80 & TLS port 443) via Nginx -> ws-openvpn -> OpenVPN TCP
WS_PORT=2096
WS_PATH="/ovpn-ws"
WS_BIN="${WS_BIN:-/usr/local/bin/ws-openvpn}"
WS_UNIT="$UNIT_DIR/ws-openvpn.service"
NGX_SNIPPET="${NGX_SNIPPET:-/etc/nginx/snippets/vpn-ovpn-ws.conf}"
NGX_CONF="${NGX_CONF:-/etc/nginx/conf.d/xray.conf}"
NGX_MARK="# vpn-ovpn-ws"
DL_DIR="${OVPN_DL_DIR:-/var/lib/vpn-ovpn-dl}"   # link download sementara (token acak)
DL_TTL_MIN=60

LINE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
CLI=0
ASSUME_YES=0

# ─── Helper ────────────────────────────────────────────────
pause() { [[ "$CLI" == "1" ]] && return; echo ""; echo -ne "  ${DIM}Tekan Enter untuk kembali...${NC}"; read -r; }

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  echo -ne "  ${WHITE}$1 [y/N]${NC}: "
  read -r a
  [[ "$a" =~ ^[Yy]$ ]]
}

ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
fail() { echo -e "  ${RED}[GAGAL]${NC} $*"; }
info() { echo -e "  ${CYAN}[*]${NC} $*"; }

is_installed() { [[ -f "$OVPN_SERVER_DIR/$SVC_TCP.conf" && -f "$OVPN_SERVER_DIR/$SVC_UDP.conf" ]]; }

load_ports() {
  TCP_PORT=$DEF_TCP_PORT; UDP_PORT=$DEF_UDP_PORT
  [[ -f "$OVPN_CONF" ]] && source "$OVPN_CONF"
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

port_listening() { # port_listening tcp|udp PORT
  local flag="t"; [[ "$1" == "udp" ]] && flag="u"
  ss -ln${flag} 2>/dev/null | grep -qE "[:.]$2[[:space:]]"
}

default_iface() {
  local i
  i=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(n=1;n<=NF;n++) if($n=="dev"){print $(n+1); exit}}')
  [[ -z "$i" ]] && i=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
  echo "$i"
}

openvpn_version() { openvpn --version 2>/dev/null | head -1 | awk '{print $2}'; }

# ver_ge A B -> benar kalau versi A >= B
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

find_pam_plugin() {
  local p
  [[ -n "$OVPN_PAM_PLUGIN" && -f "$OVPN_PAM_PLUGIN" ]] && { echo "$OVPN_PAM_PLUGIN"; return 0; }
  for p in /usr/lib/openvpn/openvpn-plugin-auth-pam.so \
           /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
           /usr/lib/aarch64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
           /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  p=$(dpkg -L openvpn 2>/dev/null | grep 'openvpn-plugin-auth-pam\.so$' | head -1)
  [[ -n "$p" && -f "$p" ]] && { echo "$p"; return 0; }
  return 1
}

# ─── PKI (openssl, tanpa easy-rsa) ─────────────────────────
gen_pki() {
  mkdir -p "$OVPN_DIR"; chmod 700 "$OVPN_DIR"
  if [[ -f "$OVPN_DIR/ca.crt" && -f "$OVPN_DIR/server.crt" && -f "$OVPN_DIR/server.key" ]]; then
    ok "Sertifikat lama dipakai ulang (file .ovpn lama tetap valid)."
    return 0
  fi
  info "Membuat CA & sertifikat server (RSA 2048, berlaku 10 tahun)..."
  (
    cd "$OVPN_DIR" || exit 1
    openssl genrsa -out ca.key 2048 2>/dev/null &&
    openssl req -new -x509 -days 3650 -key ca.key -sha256 -subj "/CN=VPN-Script-CA" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -out ca.crt 2>/dev/null &&
    openssl genrsa -out server.key 2048 2>/dev/null &&
    openssl req -new -key server.key -subj "/CN=vpn-script-server" -out server.csr 2>/dev/null &&
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt \
      -days 3650 -sha256 \
      -extfile <(printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n') 2>/dev/null
  ) || { fail "Gagal membuat sertifikat (cek: openssl version)."; return 1; }
  chmod 600 "$OVPN_DIR"/*.key
  rm -f "$OVPN_DIR/server.csr"
  [[ -s "$OVPN_DIR/ca.crt" && -s "$OVPN_DIR/server.crt" ]] || { fail "File sertifikat kosong."; return 1; }
  ok "Sertifikat dibuat di $OVPN_DIR"
}

# ─── Config server ─────────────────────────────────────────
write_server_conf() { # name proto port net mgmt_port
  local name="$1" proto="$2" port="$3" net="$4" mgmt="$5"
  local plugin cipher_line extra=""
  plugin=$(find_pam_plugin) || { fail "Plugin openvpn-plugin-auth-pam.so tidak ditemukan."; return 1; }

  if ver_ge "$(openvpn_version)" 2.5; then
    cipher_line="data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC:AES-128-CBC"
  else
    cipher_line="ncp-ciphers AES-256-GCM:AES-128-GCM"
  fi
  [[ "$proto" == "udp" ]] && extra="explicit-exit-notify 1"

  mkdir -p "$OVPN_SERVER_DIR"
  cat > "$OVPN_SERVER_DIR/$name.conf" <<EOF
# Dibuat oleh menu OpenVPN (CHANELOG VPN SCRIPT) -- jangan edit manual,
# ubah lewat menu (install ulang).
port $port
proto $proto
dev tun
ca $OVPN_DIR/ca.crt
cert $OVPN_DIR/server.crt
key $OVPN_DIR/server.key
dh none
topology subnet
server $net $NETMASK
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-CBC
$cipher_line
auth SHA256
tls-version-min 1.2
user nobody
group nogroup
persist-key
persist-tun
verb 3
management 127.0.0.1 $mgmt $OVPN_DIR/mgmt.pass
plugin $plugin vpn-script-ovpn
verify-client-cert none
username-as-common-name
$extra
EOF
}

write_pam() {
  cat > "$PAM_FILE" <<'EOF'
# Dipakai OpenVPN (plugin auth-pam) -- login pakai akun SSH yang sama.
auth    required pam_unix.so nodelay
account required pam_unix.so
EOF
}

# ─── NAT / firewall ────────────────────────────────────────
ovpn_nat_apply() {
  load_ports
  local iface net
  iface=$(default_iface)
  if [[ -z "$iface" ]]; then
    fail "Interface internet tidak terdeteksi, NAT dilewati."
    return 1
  fi
  for net in "$TCP_NET/24" "$UDP_NET/24"; do
    iptables -t nat -C POSTROUTING -s "$net" -o "$iface" -j MASQUERADE 2>/dev/null ||
      iptables -t nat -A POSTROUTING -s "$net" -o "$iface" -j MASQUERADE
    iptables -C FORWARD -s "$net" -j ACCEPT 2>/dev/null || iptables -I FORWARD -s "$net" -j ACCEPT
    iptables -C FORWARD -d "$net" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
      iptables -I FORWARD -d "$net" -m state --state RELATED,ESTABLISHED -j ACCEPT
  done
  iptables -C INPUT -p tcp --dport "$TCP_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$TCP_PORT" -j ACCEPT
  iptables -C INPUT -p udp --dport "$UDP_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$UDP_PORT" -j ACCEPT

  # Anti-torrent (menu Keamanan) harus tetap paling atas di FORWARD,
  # kalau tidak, aturan ACCEPT di atas melewati pemblokirannya.
  if iptables -nL "$TORRENT_CHAIN" >/dev/null 2>&1; then
    iptables -D FORWARD -j "$TORRENT_CHAIN" 2>/dev/null
    iptables -I FORWARD 1 -j "$TORRENT_CHAIN"
  fi
  return 0
}

ovpn_nat_remove() {
  load_ports
  local iface net n
  iface=$(default_iface)
  for net in "$TCP_NET/24" "$UDP_NET/24"; do
    [[ -n "$iface" ]] && while iptables -t nat -D POSTROUTING -s "$net" -o "$iface" -j MASQUERADE 2>/dev/null; do :; done
    while iptables -D FORWARD -s "$net" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -d "$net" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
  done
  while iptables -D INPUT -p tcp --dport "$TCP_PORT" -j ACCEPT 2>/dev/null; do :; done
  while iptables -D INPUT -p udp --dport "$UDP_PORT" -j ACCEPT 2>/dev/null; do :; done
  return 0
}

write_nat_unit() {
  cat > "$NAT_UNIT" <<EOF
[Unit]
Description=NAT & firewall OpenVPN (CHANELOG VPN SCRIPT)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $SCRIPT_DIR/menu/openvpn.sh nat-apply
ExecStop=/bin/bash $SCRIPT_DIR/menu/openvpn.sh nat-remove

[Install]
WantedBy=multi-user.target
EOF
}

# ─── File client (.ovpn) ───────────────────────────────────
build_client() { # proto port outfile [user pass]
  local proto="$1" port="$2" out="$3" user="$4" pass="$5" host
  host=$(get_domain); [[ -z "$host" ]] && host=$(get_server_ip)
  mkdir -p "$(dirname "$out")"
  {
    cat <<EOF
client
dev tun
proto $proto
remote $host $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-user-pass
auth SHA256
cipher AES-256-CBC
setenv CLIENT_CERT 0
verb 3
EOF
    [[ "$proto" == "udp" ]] && echo "explicit-exit-notify 2"
    echo "<ca>"; cat "$OVPN_DIR/ca.crt"; echo "</ca>"
    if [[ -n "$user" ]]; then
      echo "<auth-user-pass>"; echo "$user"; echo "$pass"; echo "</auth-user-pass>"
    fi
  } > "$out"
  chmod 600 "$out"
}

# build_ws_clients [user pass] -> vpn-ws.ovpn (80) & vpn-wss.ovpn (443), awalan nama file = user-
build_ws_clients() {
  local user="$1" pass="$2" pre="" host
  host=$(get_domain); [[ -z "$host" ]] && host=$(get_server_ip)
  [[ -n "$user" ]] && pre="${user}-"
  local mode port f
  for mode in ws wss; do
    [[ "$mode" == "ws" ]] && port=80 || port=443
    f="$OVPN_CLIENT_DIR/${pre}vpn-${mode}.ovpn"
    build_client tcp "$port" "$f" "$user" "$pass"
    local hdr; hdr=$(mktemp)
    {
      echo "# OpenVPN over WebSocket ($( [[ $mode == ws ]] && echo 'nTLS port 80' || echo 'TLS port 443' ))"
      echo "# Pakai aplikasi yang mendukung payload/WebSocket (mis. HTTP Custom, NetMod)."
      echo "# Payload : GET $WS_PATH HTTP/1.1[crlf]Host: $host[crlf]Upgrade: websocket[crlf][crlf]"
      [[ "$mode" == "wss" ]] && echo "# SSL/SNI : $host"
      echo "# Remote  : $host:$port (tcp)"
      cat "$f"
    } > "$hdr"
    cat "$hdr" > "$f"; rm -f "$hdr"; chmod 600 "$f"
  done
}

make_client_files() {
  load_ports
  [[ -f "$OVPN_DIR/ca.crt" ]] || { fail "CA belum ada, install OpenVPN dulu."; return 1; }
  build_ws_clients ""
  build_client tcp "$TCP_PORT" "$OVPN_CLIENT_DIR/vpn-tcp.ovpn"
  build_client udp "$UDP_PORT" "$OVPN_CLIENT_DIR/vpn-udp.ovpn"
  ok "File client: $OVPN_CLIENT_DIR/vpn-tcp.ovpn (TCP $TCP_PORT)"
  ok "File client: $OVPN_CLIENT_DIR/vpn-udp.ovpn (UDP $UDP_PORT)"
  ok "File client: $OVPN_CLIENT_DIR/vpn-ws.ovpn (WS tls / ntls)"
}

user_password() { list_ssh | awk -F'|' -v u="$1" '$1==u {print $2; exit}'; }

tg_send_file() { # file caption
  load_pro_config
  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 2
  curl -s --max-time 30 -F "chat_id=$TELEGRAM_CHAT_ID" -F "caption=$2" -F "document=@$1" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" | grep -q '"ok":true'
}

# ─── Management interface (online & kick) ──────────────────
mgmt_cmd() { # port "perintah"
  local port="$1" cmd="$2" pw
  pw=$(cat "$OVPN_DIR/mgmt.pass" 2>/dev/null)
  (
    exec 3<>"/dev/tcp/127.0.0.1/$port" || exit 1
    # Management OpenVPN mengabaikan input sebelum prompt: tunggu
    # "ENTER PASSWORD:" (15 karakter, tanpa newline), baru kirim password.
    IFS= read -r -t 3 -n 15 _prompt <&3
    printf '%s\n' "$pw" >&3
    IFS= read -r -t 3 _reply <&3
    printf '%s\nquit\n' "$cmd" >&3
    timeout 3 cat <&3
  ) 2>/dev/null
}

# keluaran: proto|user|real_ip|virtual_ip|rx_bytes|tx_bytes|connected_since
ovpn_online() {
  load_ports
  local pair proto port out
  for pair in "tcp:$MGMT_TCP:$SVC_TCP" "udp:$MGMT_UDP:$SVC_UDP"; do
    IFS=: read -r proto port svc <<< "$pair"
    out=$(mgmt_cmd "$port" "status 2" | tr -d '\r')
    if [[ -z "$out" && -r "$STATUS_DIR/status-$svc.log" ]]; then
      out=$(cat "$STATUS_DIR/status-$svc.log")
    fi
    echo "$out" | awk -F, -v p="$proto" '$1=="CLIENT_LIST"{print p"|"$2"|"$3"|"$4"|"$6"|"$7"|"$8}'
  done
}

ovpn_kick() { # username
  local user="$1" killed=1 port out
  [[ -n "$user" ]] || return 1
  for port in "$MGMT_TCP" "$MGMT_UDP"; do
    out=$(mgmt_cmd "$port" "kill $user")
    echo "$out" | grep -q "SUCCESS: common name" && killed=0
  done
  return $killed
}

# ─── Status ────────────────────────────────────────────────
render_status() {
  load_ports
  local inst st_t st_u pt pu online
  if is_installed; then inst="${GREEN}terpasang${NC}"; else inst="${RED}belum terpasang${NC}"; fi
  systemctl is-active --quiet "openvpn-server@$SVC_TCP" 2>/dev/null && st_t="${GREEN}RUNNING${NC}" || st_t="${RED}STOPPED${NC}"
  systemctl is-active --quiet "openvpn-server@$SVC_UDP" 2>/dev/null && st_u="${GREEN}RUNNING${NC}" || st_u="${RED}STOPPED${NC}"
  port_listening tcp "$TCP_PORT" && pt="${GREEN}listen${NC}" || pt="${RED}tidak listen${NC}"
  port_listening udp "$UDP_PORT" && pu="${GREEN}listen${NC}" || pu="${RED}tidak listen${NC}"
  online=$(ovpn_online 2>/dev/null | grep -c '|')

  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}OPENVPN${NC}"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_kv "Status"          "$inst"
  ui_kv "OpenVPN versi"   "$(openvpn_version 2>/dev/null || echo -)"
  ui_kv "TCP $TCP_PORT"   "$st_t / $pt"
  ui_kv "UDP $UDP_PORT"   "$st_u / $pu"
  local wsb; if ws_active; then wsb="${GREEN}aktif${NC} (80 nTLS / 443 TLS, $WS_PATH)"; else wsb="${DIM}nonaktif${NC}"; fi
  ui_kv "WebSocket"       "$wsb"
  ui_kv "User online"     "$online"
  ui_kv "Login"           "akun SSH yang sama"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
}

# ─── WebSocket (nTLS 80 / TLS 443) ─────────────────────────
write_ws_bridge() {
  cat > "$WS_BIN" <<'PYEOF'
#!/usr/bin/env python3
# ws-openvpn: terima "Upgrade: websocket" (dari Nginx), balas 101, lalu
# sambungkan aliran mentah ke OpenVPN TCP lokal.
import asyncio, sys
LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 2096
TARGET_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 1194
RESP = (b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
        b"Connection: Upgrade\r\nSec-WebSocket-Accept: foo\r\n\r\n")

async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d:
                break
            w.write(d)
            await w.drain()
    except Exception:
        pass
    finally:
        try: w.close()
        except Exception: pass

async def handle(cr, cw):
    try:
        await asyncio.wait_for(cr.readuntil(b"\r\n\r\n"), 15)
        tr, tw = await asyncio.open_connection("127.0.0.1", TARGET_PORT)
    except Exception:
        try: cw.close()
        except Exception: pass
        return
    cw.write(RESP)
    await cw.drain()
    await asyncio.gather(pipe(cr, tw), pipe(tr, cw))

async def main():
    srv = await asyncio.start_server(handle, "127.0.0.1", LISTEN_PORT)
    async with srv:
        await srv.serve_forever()

asyncio.run(main())
PYEOF
  chmod 755 "$WS_BIN"
}

write_ws_unit() {
  cat > "$WS_UNIT" <<EOF
[Unit]
Description=OpenVPN over WebSocket bridge (CHANELOG VPN SCRIPT)
After=network.target

[Service]
ExecStart=/usr/bin/python3 $WS_BIN $WS_PORT $TCP_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

write_ngx_snippet() {
  mkdir -p "$(dirname "$NGX_SNIPPET")"
  cat > "$NGX_SNIPPET" <<EOF
# Dibuat oleh menu OpenVPN (CHANELOG VPN SCRIPT)
location $WS_PATH {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:$WS_PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_connect_timeout 60s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}

# Link download .ovpn sementara: /ovpn-dl/<token-acak>/<file>
location ^~ /ovpn-dl/ {
    alias $DL_DIR/;
    autoindex off;
    default_type application/octet-stream;
    add_header Content-Disposition "attachment";
    add_header Cache-Control "no-store";
}
EOF
}

# Sisipkan/hapus 'include snippet' di server block port 80 dan 443.
ngx_patch() { # add|del
  [[ -f "$NGX_CONF" ]] || return 2
  python3 - "$NGX_CONF" "$1" "$NGX_SNIPPET" "$NGX_MARK" <<'PYEOF'
import re, sys
path, mode, snip, mark = sys.argv[1:5]
src = open(path).read().split("\n")
line_inc = "    include %s; %s" % (snip, mark)
out, i, n = [], 0, 0
# bagi per baris; deteksi blok server berdasarkan listen
if mode == "del":
    out = [l for l in src if mark not in l]
    n = len(src) - len(out)
else:
    # cari blok server: dari baris 'server {' sampai '}' tingkat 0
    idx = 0
    while idx < len(src):
        l = src[idx]
        if re.match(r"^\s*server\s*\{", l):
            depth, j = 0, idx
            while j < len(src):
                depth += src[j].count("{") - src[j].count("}")
                if depth == 0:
                    break
                j += 1
            block = src[idx:j+1]
            text = "\n".join(block)
            want = re.search(r"^\s*listen\s+(?:\S+:)?(?:80|443|8443)\b", text, re.M)
            if want and mark not in text:
                for k, bl in enumerate(block):
                    if re.match(r"^\s*server_name\b", bl):
                        block.insert(k+1, line_inc); n += 1
                        break
            out.extend(block)
            idx = j + 1
            continue
        out.append(l)
        idx += 1
open(path, "w").write("\n".join(out))
print(n)
PYEOF
}

ws_apply() {
  load_ports
  command -v python3 >/dev/null 2>&1 || { warn "python3 tidak ada, WebSocket dilewati."; return 1; }
  write_ws_bridge; write_ws_unit
  systemctl daemon-reload 2>/dev/null
  systemctl enable ws-openvpn >/dev/null 2>&1
  systemctl restart ws-openvpn 2>/dev/null
  if ! command -v nginx >/dev/null 2>&1 || [[ ! -f "$NGX_CONF" ]]; then
    warn "Nginx / $NGX_CONF tidak ditemukan, jalur WebSocket (80/443) dilewati. Bridge tetap jalan di 127.0.0.1:$WS_PORT."
    return 1
  fi
  local bak; bak=$(mktemp)
  cp -a "$NGX_CONF" "$bak"
  write_ngx_snippet
  ngx_patch add >/dev/null
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
    rm -f "$bak"
    ok "WebSocket aktif: $WS_PATH di port 80 (nTLS) dan 443 (TLS)."
    return 0
  fi
  cat "$bak" > "$NGX_CONF"; rm -f "$bak"
  fail "Config Nginx baru tidak valid, dikembalikan seperti semula. WebSocket tidak aktif."
  return 1
}

ws_remove() {
  systemctl disable --now ws-openvpn >/dev/null 2>&1
  rm -f "$WS_UNIT" "$WS_BIN"
  if [[ -f "$NGX_CONF" ]] && grep -q "$NGX_MARK" "$NGX_CONF" 2>/dev/null; then
    local bak; bak=$(mktemp); cp -a "$NGX_CONF" "$bak"
    ngx_patch del >/dev/null
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null
    else
      cat "$bak" > "$NGX_CONF"
      warn "Gagal membersihkan config Nginx (dikembalikan). Hapus baris '$NGX_MARK' manual di $NGX_CONF."
    fi
    rm -f "$bak"
  fi
  rm -f "$NGX_SNIPPET"
  rm -rf "$DL_DIR"
  systemctl daemon-reload 2>/dev/null
}

# ─── Link download sementara ───────────────────────────────
dl_cleanup() {
  [[ -d "$DL_DIR" ]] && find "$DL_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +"$DL_TTL_MIN" -exec rm -rf {} + 2>/dev/null
  return 0
}

dl_create() { # [user]  -> user kosong = file umum (tanpa password)
  local u="$1" pw="" tok dir host pre="" f
  dl_cleanup
  grep -q "$NGX_MARK" "$NGX_CONF" 2>/dev/null && [[ -f "$NGX_SNIPPET" ]] && grep -q "ovpn-dl" "$NGX_SNIPPET" \
    || { fail "Jalur web belum aktif. Pilih menu [10] Pasang ulang WebSocket dulu."; return 1; }
  if [[ -n "$u" ]]; then
    pw=$(user_password "$u")
    [[ -n "$pw" ]] || { fail "Akun SSH '$u' tidak ditemukan."; return 1; }
    pre="${u}-"
  fi
  load_ports
  tok=$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')
  dir="$DL_DIR/$tok"
  mkdir -p "$dir"; chmod 755 "$DL_DIR" "$dir"
  build_client tcp "$TCP_PORT" "$dir/${pre}vpn-tcp.ovpn" "$u" "$pw"
  build_client udp "$UDP_PORT" "$dir/${pre}vpn-udp.ovpn" "$u" "$pw"
  OVPN_CLIENT_DIR="$dir" build_ws_clients "$u" "$pw"
  chmod 644 "$dir"/*.ovpn
  # hapus otomatis setelah TTL (cadangan selain dl_cleanup)
  systemd-run --quiet --on-active="${DL_TTL_MIN}m" rm -rf "$dir" >/dev/null 2>&1 || true
  host=$(get_domain); [[ -z "$host" ]] && host=$(get_server_ip)
  # Uji sendiri dari VPS: https dulu, kalau gagal coba http
  local first scheme="https" code_s code_p
  first=$(basename "$(ls "$dir"/*.ovpn | head -1)")
  if command -v curl >/dev/null 2>&1; then
    code_s=$(curl -sk -m 8 --noproxy "*" --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/ovpn-dl/$tok/$first")
    if [[ "$code_s" != "200" ]]; then
      code_p=$(curl -s -m 8 --noproxy "*" -H "Host: $host" -o /dev/null -w '%{http_code}' "http://127.0.0.1/ovpn-dl/$tok/$first")
      if [[ "$code_p" == "200" ]]; then scheme="http"; fi
    fi
  fi
  echo -e "  ${CYAN}$LINE${NC}"
  echo -e "  ${WHITE}Link download (berlaku ${DL_TTL_MIN} menit)${NC}"
  echo -e "  ${CYAN}$LINE${NC}"
  for f in "$dir"/*.ovpn; do
    echo -e "  ${GREEN}$scheme://$host/ovpn-dl/$tok/$(basename "$f")${NC}"
  done
  echo ""
  if command -v curl >/dev/null 2>&1; then
    if [[ "$scheme" == "http" ]]; then
      warn "HTTPS belum bisa melayani link (kode ${code_s:-?}); link memakai HTTP biasa (tidak terenkripsi)."
    elif [[ "$code_s" != "200" ]]; then
      warn "Uji link dari VPS gagal (HTTPS ${code_s:-?}). Jalankan menu OpenVPN -> [10] Pasang ulang WebSocket, lalu coba lagi."
    fi
  fi
  if [[ -n "$u" ]]; then
    warn "File ini berisi username & password. Siapa pun yang punya link bisa memakainya, jangan disebar."
  else
    echo -e "  ${DIM}File umum (tanpa password): user mengisi username & password sendiri di aplikasi.${NC}"
  fi
  return 0
}

# Versi mesin-baca untuk panel web: bash openvpn.sh dl-json USER
dl_json() { # user (wajib)
  local u="$1" out rc urls warn_line
  [[ -n "$u" ]] || { jq -n '{ok:false,error:"username wajib diisi"}'; return 1; }
  out=$(dl_create "$u" 2>&1); rc=$?
  out=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
  if (( rc != 0 )); then
    jq -n --arg e "$(printf '%s' "$out" | grep -E 'GAGAL' | head -1 | sed 's/^ *\[GAGAL\] *//')" '{ok:false,error:(if $e=="" then "gagal membuat link" else $e end)}'
    return 1
  fi
  urls=$(printf '%s\n' "$out" | grep -oE 'https?://[^ ]+\.ovpn')
  warn_line=$(printf '%s\n' "$out" | grep -E '^\s*\[!\]' | grep -v 'username & password' | sed 's/^ *\[!\] *//' | paste -sd' ' -)
  printf '%s\n' "$urls" | jq -R -s --arg w "$warn_line" --argjson ttl "$DL_TTL_MIN" '
    split("\n") | map(select(length>0)) as $u
    | {ok:($u|length>0), ttl_min:$ttl, warning:$w,
       files: ($u | map({url:., name:(split("/")|last)}))}'
}

act_download_link() {
  need_installed || return 1
  echo -ne "  ${YELLOW}Username akun SSH${NC} (kosongkan = file umum tanpa password): "; read -r u
  dl_create "$u"
}

act_download_clear() {
  rm -rf "$DL_DIR"/*/ 2>/dev/null
  ok "Semua link download dihapus."
}

ws_active() { systemctl is-active --quiet ws-openvpn 2>/dev/null && grep -q "$NGX_MARK" "$NGX_CONF" 2>/dev/null; }

# ─── Install ───────────────────────────────────────────────
ovpn_install() {
  [[ "$(id -u)" == "0" ]] || { fail "Harus dijalankan sebagai root."; return 1; }
  load_ports

  if is_installed; then
    warn "OpenVPN sudah terpasang. Melanjutkan akan menulis ulang konfigurasi (sertifikat tetap dipakai)."
    confirm "Lanjutkan install ulang?" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }
  fi

  if [[ "$ASSUME_YES" != "1" ]]; then
    local p
    echo -ne "  ${YELLOW}Port TCP${NC} [default $TCP_PORT]: "; read -r p
    [[ -n "$p" ]] && { valid_port "$p" && TCP_PORT="$p" || warn "Port tidak valid, pakai $TCP_PORT."; }
    echo -ne "  ${YELLOW}Port UDP${NC} [default $UDP_PORT]: "; read -r p
    [[ -n "$p" ]] && { valid_port "$p" && UDP_PORT="$p" || warn "Port tidak valid, pakai $UDP_PORT."; }
  fi
  for p in 22 80 443 109 143 442 8880 8080 2080 2082 777 5300 7300; do
    if [[ "$p" == "$TCP_PORT" ]] || [[ "$p" == "$UDP_PORT" ]]; then
      warn "Port $p dipakai layanan lain di script ini, pilih port berbeda (install ulang)."
      return 1
    fi
  done

  if ! command -v openvpn >/dev/null 2>&1 || ! find_pam_plugin >/dev/null 2>&1; then
    info "Menginstall paket openvpn..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq openvpn openssl >/dev/null 2>&1
  fi
  command -v openvpn >/dev/null 2>&1 || { fail "Paket openvpn gagal terpasang (cek koneksi apt)."; return 1; }
  find_pam_plugin >/dev/null || { fail "Plugin auth-pam tidak ditemukan setelah install."; return 1; }
  ok "OpenVPN $(openvpn_version) siap."

  gen_pki || return 1

  mkdir -p "$OVPN_DIR"
  [[ -s "$OVPN_DIR/mgmt.pass" ]] || { head -c 18 /dev/urandom | base64 | tr -d '/+=\n' > "$OVPN_DIR/mgmt.pass"; }
  chmod 600 "$OVPN_DIR/mgmt.pass"
  printf 'TCP_PORT=%s\nUDP_PORT=%s\n' "$TCP_PORT" "$UDP_PORT" > "$OVPN_CONF"

  info "Menulis konfigurasi server..."
  write_server_conf "$SVC_TCP" tcp "$TCP_PORT" "$TCP_NET" "$MGMT_TCP" || return 1
  write_server_conf "$SVC_UDP" udp "$UDP_PORT" "$UDP_NET" "$MGMT_UDP" || return 1
  write_pam
  mkdir -p /var/log/openvpn

  info "Mengaktifkan IP forwarding & NAT..."
  mkdir -p "$SYSCTL_DIR"
  printf '# Dibuat oleh menu OpenVPN (CHANELOG VPN SCRIPT)\nnet.ipv4.ip_forward=1\n' > "$SYSCTL_DIR/99-vpn-openvpn.conf"
  sysctl -p "$SYSCTL_DIR/99-vpn-openvpn.conf" >/dev/null 2>&1
  write_nat_unit
  systemctl daemon-reload 2>/dev/null
  systemctl enable vpn-ovpn-nat.service >/dev/null 2>&1
  ovpn_nat_apply >/dev/null 2>&1 || warn "NAT gagal diterapkan sekarang (akan dicoba saat boot)."

  info "Menjalankan layanan..."
  systemctl enable "openvpn-server@$SVC_TCP" "openvpn-server@$SVC_UDP" >/dev/null 2>&1
  systemctl restart "openvpn-server@$SVC_TCP" "openvpn-server@$SVC_UDP" 2>/dev/null
  sleep 2

  local good=0
  if systemctl is-active --quiet "openvpn-server@$SVC_TCP" && systemctl is-active --quiet "openvpn-server@$SVC_UDP"; then
    good=1
    ok "OpenVPN aktif: TCP $TCP_PORT dan UDP $UDP_PORT."
  else
    fail "Layanan belum aktif. Cek: journalctl -u openvpn-server@$SVC_TCP -n 20 --no-pager"
  fi

  info "Menyiapkan jalur WebSocket (nTLS 80 / TLS 443)..."
  ws_apply || true

  make_client_files
  echo ""
  echo -e "  ${GREEN}$LINE${NC}"
  echo -e "  ${WHITE}OPENVPN SIAP DIPAKAI${NC}"
  echo -e "  ${GREEN}$LINE${NC}"
  echo -e "  Client : pakai file ${WHITE}vpn-tcp.ovpn${NC} / ${WHITE}vpn-udp.ovpn${NC} (menu OpenVPN -> kirim ke Telegram)"
  echo -e "  WS     : ${WHITE}vpn-ws.ovpn${NC} (nTLS 80) / ${WHITE}vpn-wss.ovpn${NC} (TLS 443), path ${WHITE}$WS_PATH${NC}"
  echo -e "  Login  : username & password ${WHITE}akun SSH${NC} yang sama"
  echo -e "  Batas  : 1 sesi per akun (login kedua memutus yang pertama)"
  echo -e "  ${GREEN}$LINE${NC}"
  [[ "$good" == "1" ]]
}

# ─── Uninstall ─────────────────────────────────────────────
ovpn_uninstall() {
  if ! is_installed && [[ ! -d "$OVPN_DIR" ]]; then
    warn "OpenVPN dari script ini tidak terpasang."
    return 0
  fi
  echo -e "  ${YELLOW}Ini menghapus konfigurasi, sertifikat, dan file .ovpn dari script ini.${NC}"
  echo -e "  ${YELLOW}File .ovpn yang sudah dibagikan ke user tidak akan valid lagi.${NC}"
  confirm "Hapus OpenVPN sekarang?" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }

  systemctl disable --now "openvpn-server@$SVC_TCP" "openvpn-server@$SVC_UDP" >/dev/null 2>&1
  systemctl disable --now vpn-ovpn-nat.service >/dev/null 2>&1
  ovpn_nat_remove
  ws_remove
  rm -f "$OVPN_SERVER_DIR/$SVC_TCP.conf" "$OVPN_SERVER_DIR/$SVC_UDP.conf" "$NAT_UNIT" "$PAM_FILE" \
        "$SYSCTL_DIR/99-vpn-openvpn.conf"
  rm -rf "$OVPN_DIR" "$OVPN_CLIENT_DIR"
  systemctl daemon-reload 2>/dev/null
  ok "OpenVPN dihapus. (Paket apt 'openvpn' dibiarkan terpasang; hapus manual dengan: apt remove openvpn)"
  return 0
}

# ─── Aksi menu ─────────────────────────────────────────────
need_installed() { is_installed || { fail "OpenVPN belum terpasang. Pilih menu Install dulu."; return 1; }; }

act_service() { # start|stop|restart
  need_installed || return 1
  systemctl "$1" "openvpn-server@$SVC_TCP" "openvpn-server@$SVC_UDP" 2>/dev/null
  sleep 1
  ok "Perintah $1 dijalankan."
}

act_show_client() {
  need_installed || return 1
  make_client_files >/dev/null
  local f
  for f in vpn-tcp.ovpn vpn-udp.ovpn vpn-ws.ovpn vpn-wss.ovpn; do
    echo -e "  ${CYAN}$LINE${NC}"
    echo -e "  ${WHITE}$OVPN_CLIENT_DIR/$f${NC}"
    echo -e "  ${CYAN}$LINE${NC}"
    cat "$OVPN_CLIENT_DIR/$f"
    echo ""
  done
}

act_user_file() {
  need_installed || return 1
  local u pw out
  echo -ne "  ${YELLOW}Username akun SSH${NC}: "; read -r u
  pw=$(user_password "$u")
  if [[ -z "$u" || -z "$pw" ]]; then fail "Akun SSH '$u' tidak ditemukan."; return 1; fi
  load_ports
  out="$OVPN_CLIENT_DIR/${u}-tcp.ovpn"; build_client tcp "$TCP_PORT" "$out" "$u" "$pw"; ok "TCP : $out"
  out="$OVPN_CLIENT_DIR/${u}-udp.ovpn"; build_client udp "$UDP_PORT" "$out" "$u" "$pw"; ok "UDP : $out"
  build_ws_clients "$u" "$pw"; ok "WS  : $OVPN_CLIENT_DIR/${u}-vpn-ws.ovpn (nTLS 80)"; ok "WSS : $OVPN_CLIENT_DIR/${u}-vpn-wss.ovpn (TLS 443)"
  warn "File ini berisi username & password. Jangan disebar ke orang lain."
  if confirm "Kirim kedua file ke Telegram?"; then
    tg_send_file "$OVPN_CLIENT_DIR/${u}-tcp.ovpn" "OpenVPN TCP - $u" && tg_send_file "$OVPN_CLIENT_DIR/${u}-udp.ovpn" "OpenVPN UDP - $u" \
      && tg_send_file "$OVPN_CLIENT_DIR/${u}-vpn-ws.ovpn" "OpenVPN WS nTLS - $u" && tg_send_file "$OVPN_CLIENT_DIR/${u}-vpn-wss.ovpn" "OpenVPN WS TLS - $u" \
      && ok "Terkirim ke Telegram." || fail "Gagal kirim (Bot Telegram belum di-setup di menu 13?)."
  fi
}

act_send_telegram() {
  need_installed || return 1
  make_client_files >/dev/null
  if tg_send_file "$OVPN_CLIENT_DIR/vpn-tcp.ovpn" "OpenVPN TCP" && tg_send_file "$OVPN_CLIENT_DIR/vpn-udp.ovpn" "OpenVPN UDP" \
     && tg_send_file "$OVPN_CLIENT_DIR/vpn-ws.ovpn" "OpenVPN WS nTLS (80)" && tg_send_file "$OVPN_CLIENT_DIR/vpn-wss.ovpn" "OpenVPN WS TLS (443)"; then
    ok "4 file .ovpn (tcp, udp, ws, wss) terkirim ke Telegram."
  else
    fail "Gagal kirim. Pastikan Bot Telegram sudah di-setup (menu 13)."
  fi
}

act_ws_reapply() { need_installed || return 1; ws_apply; make_client_files >/dev/null; }

act_online() {
  need_installed || return 1
  local rows; rows=$(ovpn_online)
  if [[ -z "$rows" ]]; then echo -e "  ${DIM}Tidak ada user OpenVPN yang online.${NC}"; return 0; fi
  printf "  ${WHITE}%-5s %-16s %-22s %-14s${NC}\n" "PROTO" "USER" "IP ASAL" "IP VPN"
  echo -e "  ${CYAN}$LINE${NC}"
  echo "$rows" | while IFS='|' read -r proto user real virt rx tx since; do
    printf "  %-5s %-16s %-22s %-14s\n" "$proto" "$user" "$real" "$virt"
  done
}

# ─── Menu ──────────────────────────────────────────────────
run_action() { echo ""; "$@"; pause; }

openvpn_menu() {
  clear
  render_status
  echo ""
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_2col "$(ui_menu_num 01 'Install OpenVPN' "$GREEN")"   "$(ui_menu_num 02 'Hapus OpenVPN' "$RED")"
  ui_2col "$(ui_menu_num 03 'Start')"                       "$(ui_menu_num 04 'Stop')"
  ui_2col "$(ui_menu_num 05 'Restart')"                     "$(ui_menu_num 06 'User Online')"
  ui_2col "$(ui_menu_num 07 'Lihat file .ovpn')"            "$(ui_menu_num 08 '.ovpn per user')"
  ui_2col "$(ui_menu_num 09 'Kirim .ovpn Telegram')"        "$(ui_menu_num 10 'Pasang ulang WebSocket')"
  ui_2col "$(ui_menu_num 11 'Link Download .ovpn' "$GREEN")" "$(ui_menu_num 12 'Hapus Semua Link')"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_line "$(ui_menu_num 00 'Kembali ke Menu Utama' "$DIM")"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  echo -ne "  ${WHITE}${BOLD}Pilih menu [0-12]${NC} ${DIM}›${NC} "
  read -r choice

  case "$choice" in
    1) run_action ovpn_install ;;
    2) run_action ovpn_uninstall ;;
    3) run_action act_service start ;;
    4) run_action act_service stop ;;
    5) run_action act_service restart ;;
    6) run_action act_online ;;
    7) run_action act_show_client ;;
    8) run_action act_user_file ;;
    9) run_action act_send_telegram ;;
    10) run_action act_ws_reapply ;;
    11) run_action act_download_link ;;
    12) run_action act_download_clear ;;
    0) bash "$SCRIPT_DIR/menu.sh"; return ;;
    *) echo -e "  ${RED}[!] Pilihan tidak valid${NC}"; sleep 1 ;;
  esac
  openvpn_menu
}

# ─── Entry point ───────────────────────────────────────────
if [[ -n "$1" ]]; then
  CLI=1
  [[ "$2" == "-y" || "$3" == "-y" ]] && ASSUME_YES=1
  [[ "$2" == "-y" ]] && set -- "$1"
  case "$1" in
    install)      ovpn_install ;;
    uninstall)    ovpn_uninstall ;;
    status)       render_status ;;
    online)       ovpn_online ;;
    kick)         ovpn_kick "$2" ;;
    client-files) make_client_files ;;
    nat-apply)    ovpn_nat_apply ;;
    nat-remove)   ovpn_nat_remove ;;
    ws-apply)     ws_apply ;;
    dl-link)      dl_create "$2" ;;
    dl-json)      dl_json "$2" ;;
    ws-remove)    ws_remove ;;
    *) echo "Pemakaian: bash $0 [install|uninstall|status|online|kick USER|client-files|nat-apply|nat-remove|ws-apply|ws-remove|dl-link [USER]|dl-json USER] [-y]"; exit 1 ;;
  esac
  exit $?
fi

openvpn_menu
