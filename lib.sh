#!/bin/bash
# ============================================================
#   CHANELOG VPN SCRIPT - LIBRARY FUNCTIONS (ALL-IN-ONE)
#   Supports: VMess, VLess, Trojan, Shadowsocks, SSH-WS, HAProxy
# ============================================================

SCRIPT_DIR="/etc/vpn-script"
DB_DIR="$SCRIPT_DIR/db"
XRAY_CONFIG="/etc/xray/config.json"

# ─── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ════════════════════════════════════════════════════════════
#  UI HELPERS -- box-drawing terminal yang presisi (dipakai
#  menu.sh + SEMUA menu/*.sh biar tampilannya konsisten).
#  Sengaja cuma pakai box-drawing/ASCII polos (bukan emoji/
#  Nerd Font) karena lebar-karakternya konsisten di semua
#  client SSH (PuTTY/Termux/MobaXterm/dll).
# ════════════════════════════════════════════════════════════
UI_BOX_TOP="╭──────────────────────────────────────────────────────────╮"
UI_BOX_MID="├──────────────────────────────────────────────────────────┤"
UI_BOX_BOT="╰──────────────────────────────────────────────────────────╯"
UI_CONTENT_W=56
UI_COL_W=27

# Hitung lebar visible (tanpa kode ANSI) -- bash ${#str} ngitung byte,
# bukan karakter, jadi bisa salah di locale non-UTF-8.
ui_visible_len() {
  local plain
  plain=$(echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g')
  local n
  n=$(python3 -c "import sys; print(len(sys.argv[1]))" "$plain" 2>/dev/null)
  [[ -z "$n" ]] && n=${#plain}
  echo "$n"
}

# Tambah spasi di akhir teks berwarna sampai visible_len == width.
ui_pad_visible() {
  local text="$1" width="$2"
  local vlen=$(ui_visible_len "$text")
  local pad=$((width - vlen))
  ((pad < 0)) && pad=0
  printf "%b%*s" "$text" "$pad" ""
}

# Cetak satu baris dalam box, auto-pad ke UI_CONTENT_W.
ui_line() {
  local text="$1"
  local vlen=$(ui_visible_len "$text")
  if (( vlen > UI_CONTENT_W )); then
    local plain=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    text=$(echo "$plain" | cut -c1-$((UI_CONTENT_W-1)))"…"
  fi
  printf "│  %s│\n" "$(ui_pad_visible "$text" "$UI_CONTENT_W")"
}

# Baris rata-tengah (judul header/section). Area center = CONTENT_W+2
# supaya lebar totalnya sama persis dengan ui_line (yang punya margin
# 2 spasi built-in).
ui_line_center() {
  local text="$1"
  local inner_w=$((UI_CONTENT_W + 2))
  local vlen=$(ui_visible_len "$text")
  local pad_l=$(( (inner_w - vlen) / 2 )); ((pad_l < 0)) && pad_l=0
  local pad_r=$(( inner_w - vlen - pad_l )); ((pad_r < 0)) && pad_r=0
  printf "│%*s%b%*s│\n" "$pad_l" "" "$text" "$pad_r" ""
}

# Baris "label ..... value" model daftar isi -- presisi walau
# panjang label/value beda-beda.
ui_kv() {
  local label="$1" value="$2" leader_w=22
  local llen=${#label}
  local dots="" n=$((leader_w - llen))
  ((n < 3)) && n=3
  for ((i=0;i<n;i++)); do dots+="."; done
  ui_line "${YELLOW}${label}${NC} ${DIM}${dots}${NC} ${WHITE}${value}${NC}"
}

# Baris dua kolom presisi (grid menu/status). Tiap kolom persis
# UI_COL_W(27) karakter visible, dipisah 2 spasi -> 56 total.
ui_2col() {
  local c1="$1" c2="$2"
  local col1=$(ui_pad_visible "$c1" "$UI_COL_W")
  local col2=$(ui_pad_visible "$c2" "$UI_COL_W")
  ui_line "${col1}  ${col2}"
}

ui_dot() { [[ "$1" == "1" ]] && echo -e "${GREEN}●${NC}" || echo -e "${RED}○${NC}"; }

# Mini progress bar ASCII 14 kotak -- '#'/'.' polos, aman di semua terminal.
ui_bar() {
  local pct="${1:-0}"
  [[ "$pct" =~ ^[0-9]+$ ]] || { echo -e "${DIM}n/a${NC}"; return; }
  local width=14
  local filled=$(( pct * width / 100 )); ((filled > width)) && filled=$width
  local empty=$((width - filled))
  local color="${GREEN}"
  ((pct >= 60)) && color="${YELLOW}"
  ((pct >= 85)) && color="${RED}"
  local bar=""
  for ((i=0;i<filled;i++)); do bar+="#"; done
  for ((i=0;i<empty;i++)); do bar+="."; done
  echo -e "${color}${bar}${NC} ${WHITE}$(printf '%3s' "$pct")%${NC}"
}

ui_section() {
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_line "${CYAN}${BOLD}${1}${NC}"
}

ui_menu_num() {
  local num="$1" label="$2" color="${3:-$YELLOW}"
  echo -e "${color}[$(printf '%-2s' "$num")]${NC} $label"
}

# Header ringkas dipakai submenu (SSH/VMess/dll): judul + garis bawah.
ui_submenu_header() {
  local title="$1"
  clear
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}${title}${NC}"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
}


# ─── Get Domain ────────────────────────────────────────────
get_domain() {
  cat $SCRIPT_DIR/domain 2>/dev/null || echo "unknown"
}

# ─── Payload string WS (dipakai tampilan menu & notif Telegram) ─
ws_payload_string() {
  local domain="$1"
  local port="${2:-80}"
  local path="${3:-/ssh-ws}"
  printf 'GET %s HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]' "$path" "$domain"
}

# ─── Trial per jam (durasi presisi jam, bukan hari) ─────────
# useradd/chage cuma presisi hari, jadi utk SSH exp OS-level
# dibulatkan ke atas per hari (jaring pengaman), TAPI penghapusan
# akun yang presisi (per jam) tetap jalan lewat delete_expired
# (jadwalnya di-cron tiap 5 menit) berdasarkan datetime lengkap
# yang disimpan di kolom "exp" pada db.
get_exp_datetime_hours() {
  local hours="$1"
  date -d "+${hours} hours" +"%Y-%m-%d %H:%M:%S"
}

get_exp_date_from_hours() {
  local hours="$1"
  date -d "+${hours} hours" +"%Y-%m-%d"
}

# Format sisa waktu yang enak dibaca, presisi jam/menit kalau < 1 hari
fmt_remaining() {
  local exp="$1"
  local now=$(date +%s)
  local expd=$(date -d "$exp" +%s 2>/dev/null || echo 0)
  local diff=$(( expd - now ))
  if (( diff < 0 )); then echo "Expired"; return; fi
  if (( diff < 86400 )); then
    echo "$(( diff / 3600 )) jam $(( (diff % 3600) / 60 )) menit"
  else
    echo "$(( diff / 86400 )) hari"
  fi
}

# ─── PRO Config (limit device/IP, limit kuota, Telegram bot) ─
PRO_CONFIG="$SCRIPT_DIR/.pro-config"
load_pro_config() {
  SESSION_LIMIT_DEFAULT=2      # default limit device/IP akun SSH (concurrent session)
  IP_LIMIT_DEFAULT=2           # default limit device/IP akun Xray (vmess/vless/trojan/ss)
  QUOTA_DEFAULT_MB=0           # default kuota per akun dalam MB, 0 = unlimited
  TRIAL_HOURS_DEFAULT=1        # default durasi trial (jam), dipakai saat admin pilih mode trial
  TELEGRAM_BOT_TOKEN=""
  TELEGRAM_CHAT_ID=""
  TG_NOTIFY_CREATE=1           # notif saat akun baru dibuat
  TG_NOTIFY_DELETE=1           # notif saat akun dihapus (manual/expired)
  TG_NOTIFY_LIMIT=1            # notif saat limit device/IP/kuota kelampauan
  [[ -f "$PRO_CONFIG" ]] && source "$PRO_CONFIG"
}
load_pro_config

# ─── Simpan .pro-config (dipakai menu/telegram.sh & addon/sshws-pro.sh) ─
save_pro_config() {
  cat > "$PRO_CONFIG" << EOF
SESSION_LIMIT_DEFAULT=${SESSION_LIMIT_DEFAULT:-2}
IP_LIMIT_DEFAULT=${IP_LIMIT_DEFAULT:-2}
QUOTA_DEFAULT_MB=${QUOTA_DEFAULT_MB:-0}
TRIAL_HOURS_DEFAULT=${TRIAL_HOURS_DEFAULT:-1}
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
TG_NOTIFY_CREATE=${TG_NOTIFY_CREATE:-1}
TG_NOTIFY_DELETE=${TG_NOTIFY_DELETE:-1}
TG_NOTIFY_LIMIT=${TG_NOTIFY_LIMIT:-1}
EOF
  load_pro_config
}

# ─── Telegram Notify (silent no-op kalau belum diconfig) ────
# tipe (opsional): create|delete|limit -- dicek terhadap toggle TG_NOTIFY_*
# supaya bisa dimatikan per jenis event dari menu Bot Telegram.
# Escape karakter khusus HTML (& < >) -- wajib untuk link yang berisi "&" di pesan mode HTML Telegram
html_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

tg_notify() {
  local msg="$1"
  local tipe="${2:-}"
  [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0
  case "$tipe" in
    create) [[ "${TG_NOTIFY_CREATE:-1}" == "1" ]] || return 0 ;;
    delete) [[ "${TG_NOTIFY_DELETE:-1}" == "1" ]] || return 0 ;;
    limit)  [[ "${TG_NOTIFY_LIMIT:-1}"  == "1" ]] || return 0 ;;
  esac
  curl -s --fail --max-time 8 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    --data-urlencode "parse_mode=HTML" >/dev/null 2>&1 && return 0
  # Cadangan: kalau ditolak (mis. HTML tidak valid), kirim ulang sebagai teks biasa agar tidak hilang
  local plain
  plain=$(printf '%s' "$msg" | sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g')
  curl -s --fail --max-time 8 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${plain}" >/dev/null 2>&1
}

# ─── Format angka MB jadi label yang enak dibaca ────────────
fmt_quota() {
  local mb="$1"
  [[ -z "$mb" || "$mb" == "0" || ! "$mb" =~ ^[0-9]+$ ]] && { echo "Unlimited"; return; }
  if (( mb >= 1024 )); then
    python3 -c "print(f'{$mb/1024:.2f} GB')" 2>/dev/null || echo "$((mb/1024)) GB"
  else
    echo "${mb} MB"
  fi
}

# ─── Format angka limit device/IP (0 = unlimited) ───────────
fmt_limit() {
  local n="$1"
  [[ -z "$n" || "$n" == "0" || ! "$n" =~ ^[0-9]+$ ]] && { echo "Unlimited"; return; }
  echo "$n"
}

# ─── Get Server IP ─────────────────────────────────────────
get_server_ip() {
  curl -s4 --max-time 3 https://ifconfig.me 2>/dev/null || \
  curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || \
  hostname -I | awk '{print $1}'
}

# ─── Get VPS Info ──────────────────────────────────────────
get_cpu_info() {
  grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//'
}

get_cpu_cores() {
  nproc
}

get_cpu_usage() {
  top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1 2>/dev/null || echo "N/A"
}

get_mem_usage() {
  free -m | awk 'NR==2{printf "%sMB / %sMB (%.0f%%)", $3, $2, $3*100/$2}'
}

get_disk_usage() {
  df -h / | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}'
}

get_uptime() {
  uptime -p 2>/dev/null | sed 's/up //' || uptime | awk '{print $3,$4}' | sed 's/,//'
}

get_os_info() {
  . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || cat /etc/issue | head -1
}

get_kernel() {
  uname -r
}

get_load_avg() {
  uptime | awk -F'load average: ' '{print $2}'
}

get_network_usage() {
  local iface=$(ip route | grep default | awk '{print $5}' | head -1)
  if [[ -n "$iface" ]]; then
    local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
    local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    echo "↓$(numfmt --to=iec $rx 2>/dev/null || echo ${rx}B) ↑$(numfmt --to=iec $tx 2>/dev/null || echo ${tx}B)"
  else
    echo "N/A"
  fi
}

# ─── Service Status ────────────────────────────────────────
service_status() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo -e "${GREEN}● ON${NC}"
  else
    echo -e "${RED}● OFF${NC}"
  fi
}

service_status_text() {
  local svc="$1"
  systemctl is-active --quiet "$svc" 2>/dev/null && echo "ON" || echo "OFF"
}

# ─── UUID Generator ────────────────────────────────────────
gen_uuid() {
  cat /proc/sys/kernel/random/uuid 2>/dev/null || \
  uuid 2>/dev/null || \
  python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
  openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/'
}

# ─── Password Generator ────────────────────────────────────
gen_password() {
  openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16
}

# ─── Date Helpers ──────────────────────────────────────────
get_exp_date() {
  local days="$1"
  date -d "+${days} days" +"%Y-%m-%d"
}

days_until_exp() {
  local exp="$1"
  local today=$(date +%s)
  local expd=$(date -d "$exp" +%s 2>/dev/null || echo 0)
  echo $(( (expd - today) / 86400 ))
}

is_expired() {
  local exp="$1"
  local days=$(days_until_exp "$exp")
  [[ $days -lt 0 ]]
}

# ════════════════════════════════════════════════════════════
#  XRAY STATS API (dasar utk limit device/IP & limit kuota)
#  ─────────────────────────────────────────────────────────
#  Xray-WS di script ini selalu di-proxy lewat Nginx (127.0.0.1),
#  jadi Xray gak pernah lihat IP asli client (sama persis dengan
#  alasan kenapa SSH-WS pakai session-count, bukan IP -- lihat
#  addon/session-limiter.sh). Makanya "limit IP/device" utk Xray
#  di sini diimplementasikan sebagai LIMIT DEVICE AKTIF BERSAMAAN
#  (statsUserOnline via Xray Stats API), bukan hitung IP unik --
#  secara praktik hasilnya sama: membatasi berapa device yang
#  boleh connect bersamaan per akun. Kuota dihitung dari
#  statsUserUplink/Downlink (byte terpakai per email client).
#  Butuh Xray-core >= 1.8.0 (subcommand `xray api statsquery`).
# ════════════════════════════════════════════════════════════
XRAY_API_ADDR="127.0.0.1:10085"

# Tambal config.json biar Stats API aktif (idempotent, aman dipanggil berkali-kali)
ensure_xray_stats_api() {
  [[ -f "$XRAY_CONFIG" ]] || return 1
  # Lengkap = stats+api+policy, statsUserOnline aktif, dan access log menyala
  jq -e '.stats and .api and .policy
         and (.policy.levels["0"].statsUserOnline == true)
         and ((.log.access // "") != "")' "$XRAY_CONFIG" >/dev/null 2>&1 && return 0
  mkdir -p /var/log/xray

  local tmp=$(mktemp)
  jq '
    .log = ((.log // {}) * {"access":"/var/log/xray/access.log"}) |
    .stats = (.stats // {}) |
    .api = (.api // {"tag":"api","services":["StatsService"]}) |
    .policy = (.policy // {}) |
    .policy.levels = ((.policy.levels // {}) * {"0":{"statsUserUplink":true,"statsUserDownlink":true,"statsUserOnline":true}}) |
    .policy.system = ((.policy.system // {}) * {"statsInboundUplink":true,"statsInboundDownlink":true}) |
    .inbounds = (
      if any(.inbounds[]?; .tag == "api")
      then .inbounds
      else .inbounds + [{"tag":"api","port":10085,"listen":"127.0.0.1","protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}}]
      end
    ) |
    .routing = (.routing // {"rules":[]}) |
    .routing.rules = (
      if any(.routing.rules[]?; .inboundTag[0]? == "api")
      then .routing.rules
      else [{"type":"field","inboundTag":["api"],"outboundTag":"api"}] + .routing.rules
      end
    ) |
    .outbounds = (
      if any(.outbounds[]?; .tag == "api")
      then .outbounds
      else .outbounds + [{"protocol":"freedom","tag":"api","settings":{}}]
      end
    )
  ' "$XRAY_CONFIG" > "$tmp" 2>/dev/null && mv "$tmp" "$XRAY_CONFIG" || { rm -f "$tmp"; return 1; }

  systemctl restart xray 2>/dev/null
  sleep 1
  return 0
}

# Query mentah ke Xray Stats API. Return kosong kalau xray-core belum support.
xray_stat_query() {
  local pattern="$1"
  command -v xray >/dev/null 2>&1 || return 1
  xray api statsquery --server="$XRAY_API_ADDR" -pattern "$pattern" 2>/dev/null
}

# Total byte (uplink+downlink) yang sudah dipakai satu email/username Xray
get_xray_user_traffic_mb() {
  local email="$1"
  local json total_bytes=0
  json=$(xray_stat_query "user>>>${email}>>>traffic")
  [[ -z "$json" ]] && { echo 0; return; }
  total_bytes=$(echo "$json" | jq '[.stat[]?.value | tonumber] | add // 0' 2>/dev/null)
  [[ -z "$total_bytes" || "$total_bytes" == "null" ]] && total_bytes=0
  echo $(( total_bytes / 1024 / 1024 ))
}

# Gabungkan IP yang satu kisaran jadi satu device (operator seluler memakai CGNAT: satu HP bisa
# keluar lewat beberapa IP publik bersamaan). Atur di /etc/vpn-script/penalty.conf:
#   XRAY_IP_GROUP_BITS=16   # IPv4: 16 = per /16 (default), 24 = per /24, 32 = tiap IP dihitung sendiri
# IPv6 selalu digabung per /64. Masuk: satu IP per baris. Keluar: satu IP wakil per kisaran.
xray_group_ips() {
  local XRAY_IP_GROUP_BITS="" XRAY_IP_POOLS="112.215,140.213"
  [[ -f "$SCRIPT_DIR/penalty.conf" ]] && source "$SCRIPT_DIR/penalty.conf" 2>/dev/null
  # XRAY_IP_POOLS: kisaran IP operator yang dianggap SATU kolam (CGNAT: satu HP keluar lewat beberapa
  # kisaran sekaligus, mis. XL/Axis 112.215 + 140.213). Pisahkan kisaran dengan koma, kolam dengan spasi:
  #   XRAY_IP_POOLS="112.215,140.213 36.80,36.81"   |   XRAY_IP_POOLS="" untuk mematikan.
  # Dual-stack (WiFi rumah): jumlah device = yang terbesar antara kelompok IPv4 dan IPv6.
  awk -v bits="${XRAY_IP_GROUP_BITS:-16}" -v pools="$XRAY_IP_POOLS" '
    BEGIN { np=split(pools, pl, " ")
      for (i=1;i<=np;i++) { m=split(pl[i], pp, ","); for (j=1;j<=m;j++) pre[pp[j]]=i } }
    NF==0 { next }
    { ip=$1
      if (index(ip,":")>0) { split(ip,h,":"); k=h[1]":"h[2]":"h[3]":"h[4]
        if (!(k in s6)) { s6[k]=1; r6[++n6]=ip } }
      else { split(ip,o,".")
        p16=o[1]"."o[2]
        if (p16 in pre) k="pool"pre[p16]
        else k = (bits<=16) ? p16 : (bits<=24 ? p16"."o[3] : ip)
        if (!(k in s4)) { s4[k]=1; r4[++n4]=ip } } }
    END { if (n4>=n6) for (i=1;i<=n4;i++) print r4[i]; else for (i=1;i<=n6;i++) print r6[i] }'
}

# Daftar IP aktif satu user Xray (satu IP per baris).
#  1) xray api statsonlineiplist (akurat, jendela ~20 dtk) -- butuh Xray-core baru
#  2) cadangan: IP unik di access.log dalam $XRAY_ONLINE_WINDOW detik terakhir
#     (perkiraan; koneksi WS yang sudah lama dan tidak membuka koneksi baru bisa terlewat)
XRAY_ACCESS_LOG="/var/log/xray/access.log"
XRAY_ONLINE_WINDOW=45
XRAY_ACTIVE_WINDOW=40   # akun dianggap online hanya jika trafiknya bergerak dalam N detik terakhir

# 0 jika trafik akun ini bergerak dalam $XRAY_ACTIVE_WINDOW detik terakhir.
# Access.log hanya mencatat koneksi BARU, jadi tanpa ini akun terlihat online
# berlama-lama setelah klien putus. Pembacaan pertama = baseline (belum aktif).
xray_user_active() {
  local email="$1" dir="/run/vpn-script/xact" f json bytes now pb=0 lc=0
  mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/${email//\//_}"
  json=$(xray_stat_query "user>>>${email}>>>traffic") || return 1
  bytes=$(echo "$json" | jq '[.stat[]?.value | tonumber] | add // 0' 2>/dev/null)
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  if [[ -f "$f" ]]; then
    read -r pb lc < "$f"
    [[ "$pb" =~ ^[0-9]+$ ]] || pb=0; [[ "$lc" =~ ^[0-9]+$ ]] || lc=0
    [[ "$bytes" != "$pb" ]] && lc=$now
  fi
  echo "$bytes $lc" > "$f"
  (( lc > 0 && now - lc <= XRAY_ACTIVE_WINDOW ))
}
get_xray_user_ips() {
  local email="$1" out ips
  command -v xray >/dev/null 2>&1 || return 1
  for form in "-email=$email" "$email"; do
    out=$(timeout 5 xray api statsonlineiplist --server="$XRAY_API_ADDR" $form 2>/dev/null)
    if jq -e '.name' >/dev/null 2>&1 <<< "$out"; then
      ips=$(jq -r '.ips // {} | keys[]' <<< "$out" 2>/dev/null)
      [[ -n "$ips" ]] && { echo "$ips" | xray_group_ips; return 0; }
      break   # API ada tapi kosong -> lanjut ke access.log
    fi
  done
  xray_user_active "$email" || return 0
  xray_log_ips "$email" | xray_group_ips
}
# IP unik per user dari access.log. Tanpa argumen: semua user, format "email|ip".
xray_log_ips() {
  local only="${1:-}" cutoff
  [[ -r "$XRAY_ACCESS_LOG" ]] || return 0
  cutoff=$(date -d "-${XRAY_ONLINE_WINDOW} sec" '+%Y/%m/%d %H:%M:%S' 2>/dev/null) || return 0
  tail -n 30000 "$XRAY_ACCESS_LOG" 2>/dev/null | awk -v cut="$cutoff" -v only="$only" '
    / accepted / && /email: / {
      if (($1" "$2) < cut) next
      em=$NF; ip=""
      for (i=1;i<=NF;i++) if ($i=="from") { ip=$(i+1); break }
      sub(/^(tcp|udp):/,"",ip); sub(/:[0-9]+$/,"",ip); gsub(/[\[\]]/,"",ip)
      if (ip=="" || ip=="127.0.0.1" || ip=="::1") next
      if (only!="" && em!=only) next
      k=em"|"ip; if (!(k in seen)) { seen[k]=1; if (only!="") print ip; else print em"|"ip }
    }'
}

# Jumlah device/koneksi yang lagi online bersamaan utk satu email Xray
get_xray_user_online() {
  local email="$1"
  local json count=0 ips
  json=$(xray_stat_query "user>>>${email}>>>online")
  if [[ -n "$json" ]]; then
    count=$(echo "$json" | jq '[.stat[]?.value | tonumber] | add // 0' 2>/dev/null)
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) && { echo "$count"; return; }
  fi
  ips=$(get_xray_user_ips "$email" 2>/dev/null)
  [[ -z "$ips" ]] && { echo 0; return; }
  echo "$ips" | grep -c .
}

# Reset counter kuota (uplink+downlink) satu email -- dipakai saat renew/edit
# Nol-kan catatan pemakaian permanen (usage.db, ditulis addon/quota-limiter.sh) satu akun.
# jenis: x = Xray, s = SSH
ledger_reset() {
  local f="$DB_DIR/usage.db"
  [[ -f "$f" ]] || return 0
  awk -F'|' -v OFS='|' -v k="$1|$2" '($1"|"$2)==k {print $1,$2,0,0; next} {print}' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
}

reset_xray_user_traffic() {
  local email="$1"
  ledger_reset x "$email"
  command -v xray >/dev/null 2>&1 || return 1
  xray api statsquery --server="$XRAY_API_ADDR" -reset -pattern "user>>>${email}>>>traffic" >/dev/null 2>&1
}

# ════════════════════════════════════════════════════════════
#  SSH QUOTA ACCOUNTING (iptables OUTPUT, per-UID, best-effort)
#  ─────────────────────────────────────────────────────────
#  Dropbear/OpenSSH menjalankan proses akun sebagai UID user itu
#  sendiri setelah autentikasi, jadi -m owner --uid-owner di chain
#  OUTPUT bisa dipakai buat menghitung trafik yang dikirim balik
#  ke client per akun. Ini pendekatan umum dipakai script sejenis
#  utk "limit kuota SSH", TAPI sifatnya best-effort/approksimasi
#  (menghitung arah download client, bukan байт persis dua arah).
#  Uji dulu di VPS asli sebelum dipakai produksi besar-besaran.
# ════════════════════════════════════════════════════════════
ssh_quota_chain() {
  echo "VPNQ_$(echo "$1" | tr -cd 'A-Za-z0-9_' | cut -c1-20)"
}

setup_ssh_quota_accounting() {
  local username="$1"
  command -v iptables >/dev/null 2>&1 || return 1
  local uid; uid=$(id -u "$username" 2>/dev/null) || return 1
  local chain=$(ssh_quota_chain "$username")

  iptables -N "$chain" 2>/dev/null
  iptables -C OUTPUT -m owner --uid-owner "$uid" -j "$chain" 2>/dev/null || \
    iptables -I OUTPUT -m owner --uid-owner "$uid" -j "$chain" 2>/dev/null
  iptables -C "$chain" -j RETURN 2>/dev/null || iptables -A "$chain" -j RETURN 2>/dev/null
}

get_ssh_usage_mb() {
  local username="$1"
  command -v iptables >/dev/null 2>&1 || { echo 0; return; }
  local chain=$(ssh_quota_chain "$username")
  local bytes
  bytes=$(iptables -L "$chain" -v -x -n 2>/dev/null | awk '/RETURN/{sum+=$2} END{print sum+0}')
  echo $(( ${bytes:-0} / 1024 / 1024 ))
}

reset_ssh_usage() {
  local username="$1"
  ledger_reset s "$username"
  local chain=$(ssh_quota_chain "$username")
  iptables -Z "$chain" 2>/dev/null
}

teardown_ssh_quota_accounting() {
  local username="$1"
  command -v iptables >/dev/null 2>&1 || return 0
  local uid; uid=$(id -u "$username" 2>/dev/null)
  local chain=$(ssh_quota_chain "$username")
  [[ -n "$uid" ]] && iptables -D OUTPUT -m owner --uid-owner "$uid" -j "$chain" 2>/dev/null
  iptables -F "$chain" 2>/dev/null
  iptables -X "$chain" 2>/dev/null
}

# Jadwal addon/quota-limiter.sh (catat pemakaian + suspend akun yang kuotanya habis), tiap menit
setup_quota_limiter() {
  [[ -f "$SCRIPT_DIR/addon/quota-limiter.sh" ]] || return 1
  chmod +x "$SCRIPT_DIR/addon/quota-limiter.sh" 2>/dev/null
  printf '* * * * * root /bin/bash %s/addon/quota-limiter.sh >/dev/null 2>&1\n' "$SCRIPT_DIR" > /etc/cron.d/vpn-quota-limiter
  chmod 644 /etc/cron.d/vpn-quota-limiter
  bash "$SCRIPT_DIR/addon/quota-limiter.sh" >/dev/null 2>&1 &
  return 0
}

# ════════════════════════════════════════════════════════════
#  QUOTA ENFORCEMENT HELPERS (dipakai addon/quota-limiter.sh)
#  Akun yang kena suspend krn kuota habis DITANDAI (bukan
#  dihapus dari db) supaya gampang di-reaktivasi begitu admin
#  naikin kuota lewat menu "Edit Limit".
# ════════════════════════════════════════════════════════════
QUOTA_DISABLED_DIR="$SCRIPT_DIR/.quota-disabled"
mkdir -p "$QUOTA_DISABLED_DIR" 2>/dev/null

mark_quota_disabled()  { touch "$QUOTA_DISABLED_DIR/${1}_${2}" 2>/dev/null; }
clear_quota_disabled() { rm -f "$QUOTA_DISABLED_DIR/${1}_${2}" 2>/dev/null; }
is_quota_disabled()    { [[ -f "$QUOTA_DISABLED_DIR/${1}_${2}" ]]; }

# ── Penalti limit device (bertingkat) ───────────────────────
# Pelanggaran ke-1 putus 2 menit, ke-2 30 menit, ke-3 2 jam, ke-4+ 24 jam.
# Ubah di /etc/vpn-script/penalty.conf:
#   PENALTY_STEPS="120 1800 7200 86400"   (detik)
#   PENALTY_DECAY_HOURS=24                (bersih sekian jam -> hitungan pelanggaran mulai dari 1 lagi)
# kind: ssh | xray-vmess | xray-vless | xray-trojan | xray-ss
# File status: .penalty/<kind>_<user> berisi "strikes last until" (until=0 = tidak sedang dibekukan)
PENALTY_DIR="$SCRIPT_DIR/.penalty"
# Akun publik/dibagikan: di penalty.conf isi
#   PENALTY_EXEMPT_USERS="free promo"   -> tidak pernah kena penalti limit device
#   PENALTY_FLAT_USERS="demo"           -> selalu putus langkah pertama saja (tanpa naik tingkat)
penalty_exempt() {   # user -> 0 jika dikecualikan
  local PENALTY_EXEMPT_USERS="" u
  [[ -f "$SCRIPT_DIR/penalty.conf" ]] && source "$SCRIPT_DIR/penalty.conf" 2>/dev/null
  for u in $PENALTY_EXEMPT_USERS; do [[ "$u" == "$1" ]] && return 0; done
  return 1
}
penalty_apply() {   # kind user -> cetak "strikes durasi_detik"
  local kind="$1" user="$2" f="$PENALTY_DIR/${1}_${2}" strikes=0 last=0 until=0 now steps n idx dur decay PENALTY_FLAT_USERS=""
  [[ -f "$SCRIPT_DIR/penalty.conf" ]] && source "$SCRIPT_DIR/penalty.conf" 2>/dev/null
  mkdir -p "$PENALTY_DIR"
  [[ -f "$f" ]] && read -r strikes last until < "$f"
  [[ "$strikes" =~ ^[0-9]+$ ]] || strikes=0; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  now=$(date +%s); decay=$(( ${PENALTY_DECAY_HOURS:-24} * 3600 ))
  (( now - last > decay )) && strikes=0
  local fu; for fu in $PENALTY_FLAT_USERS; do [[ "$fu" == "$user" ]] && strikes=0; done
  strikes=$((strikes+1))
  read -ra steps <<< "${PENALTY_STEPS:-120 1800 7200 86400}"
  n=${#steps[@]}; idx=$(( strikes > n ? n-1 : strikes-1 ))
  dur=${steps[$idx]}; [[ "$dur" =~ ^[0-9]+$ ]] || dur=120
  echo "$strikes $now $((now+dur))" > "$f"
  echo "$strikes $dur"
}
penalty_until() {   # kind user -> cetak epoch akhir bekuan (0 jika tidak aktif)
  local u=0 _a _b
  [[ -f "$PENALTY_DIR/${1}_${2}" ]] && read -r _a _b u < "$PENALTY_DIR/${1}_${2}"
  [[ "$u" =~ ^[0-9]+$ ]] || u=0
  echo "$u"
}
# Toleransi pindah jaringan (WiFi <-> data): melebihi limit baru dihukum kalau terus-menerus
# selama $PENALTY_GRACE_SECONDS (default 60 detik, atur di penalty.conf).
# over=1 -> kembalikan 0 hanya kalau sudah melewati masa toleransi; over=0 -> hapus penanda.
penalty_grace_ok() {   # kind user over(0|1)
  local d="$SCRIPT_DIR/.penalty-over" f PENALTY_GRACE_SECONDS="" first now
  f="$d/${1}_${2}"
  if [[ "$3" != "1" ]]; then rm -f "$f" 2>/dev/null; return 1; fi
  [[ -f "$SCRIPT_DIR/penalty.conf" ]] && source "$SCRIPT_DIR/penalty.conf" 2>/dev/null
  mkdir -p "$d"; now=$(date +%s)
  if [[ ! -f "$f" ]]; then echo "$now" > "$f"; first=$now; else read -r first < "$f"; [[ "$first" =~ ^[0-9]+$ ]] || { echo "$now" > "$f"; first=$now; }; fi
  (( now - first >= ${PENALTY_GRACE_SECONDS:-60} )) && { rm -f "$f"; return 0; }
  return 1
}
penalty_active() { local u; u=$(penalty_until "$1" "$2"); (( u > $(date +%s) )); }
penalty_release_mark() {  # tandai selesai (until=0) tapi simpan strikes
  local f="$PENALTY_DIR/${1}_${2}" a b c
  [[ -f "$f" ]] && { read -r a b c < "$f"; echo "$a $b 0" > "$f"; }
}
penalty_fmt() {   # detik -> teks
  local d="$1"
  if   (( d >= 3600 )); then echo "$((d/3600)) jam"
  elif (( d >= 60 ));   then echo "$((d/60)) menit"
  else echo "${d} detik"; fi
}
penalty_expired_files() {  # cetak nama file (kind_user) yang masa bekuannya sudah lewat
  local f b a l u now; now=$(date +%s)
  for f in "$PENALTY_DIR"/*; do
    [[ -f "$f" ]] || continue
    read -r a l u < "$f"; [[ "$u" =~ ^[0-9]+$ ]] || continue
    (( u > 0 && u <= now )) && basename "$f"
  done
}

# Hapus client dari inbound Xray (dipakai saat kuota habis) tanpa
# menyentuh database akun -- akun tetap "ada", cuma gak bisa connect.
xray_disable_client() {
  local tag_prefix="$1" email="$2"
  local tmp=$(mktemp)
  jq --arg email "$email" --arg tp "$tag_prefix" \
    '(.inbounds[] | select(.tag | startswith($tp)) | .settings.clients) |= map(select(.email != $email))' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
}

# Aktifkan lagi client yang sempat disable karena kuota (pakai
# UUID/password yang SUDAH ada di db, bukan bikin baru).
reactivate_xray_client() {
  local proto="$1" username="$2"
  local tmp=$(mktemp)
  case "$proto" in
    vmess)
      local uuid=$(get_vmess_info "$username" | cut -d'|' -f2)
      [[ -z "$uuid" ]] && return 1
      jq --arg uuid "$uuid" --arg email "$username" \
        '(.inbounds[] | select(.tag == "vmess-ws-tls" or .tag == "vmess-ws-ntls") | .settings.clients) += [{"id": $uuid, "alterId": 0, "email": $email}]' \
        "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG" ;;
    vless)
      local uuid=$(get_vless_info "$username" | cut -d'|' -f2)
      [[ -z "$uuid" ]] && return 1
      jq --arg uuid "$uuid" --arg email "$username" \
        '(.inbounds[] | select(.tag == "vless-ws-tls" or .tag == "vless-ws-ntls" or .tag == "vless-grpc-tls") | .settings.clients) += [{"id": $uuid, "email": $email, "flow": ""}]' \
        "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG" ;;
    trojan)
      local pass=$(get_trojan_info "$username" | cut -d'|' -f2)
      [[ -z "$pass" ]] && return 1
      jq --arg pass "$pass" --arg email "$username" \
        '(.inbounds[] | select(.tag | startswith("trojan")) | .settings.clients) += [{"password": $pass, "email": $email}]' \
        "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG" ;;
    ss)
      local pass=$(get_ss_info "$username" | cut -d'|' -f2)
      local method=$(get_ss_info "$username" | cut -d'|' -f3)
      [[ -z "$pass" ]] && return 1
      jq --arg pass "$pass" --arg method "$method" \
        '(.inbounds[] | select(.tag | startswith("ss-")) | .settings.clients) += [{"method": $method, "password": $pass}]' \
        "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG" ;;
    *) return 1 ;;
  esac
  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
  ml_sync
  reset_xray_user_traffic "$username"
  clear_quota_disabled "$proto" "$username"
}

# ════════════════════════════════════════════════════════════
#  VMESS ACCOUNT MANAGEMENT
# ════════════════════════════════════════════════════════════
DB_VMESS="$DB_DIR/vmess.db"

create_vmess() {
  local username="$1"
  grep -q "^$username|" "$DB_VMESS" 2>/dev/null && return 1
  local days="$2"
  local ip_limit="${3:-$IP_LIMIT_DEFAULT}"
  local quota_mb="${4:-$QUOTA_DEFAULT_MB}"
  local trial_hours="${5:-0}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || ip_limit="${IP_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  [[ "$trial_hours" =~ ^[0-9]+$ ]] || trial_hours=0
  local uuid=$(gen_uuid)
  local exp masa_label
  if [[ "$trial_hours" -gt 0 ]]; then
    exp=$(get_exp_datetime_hours "$trial_hours")
    masa_label="Trial ${trial_hours} jam"
  else
    exp=$(get_exp_date "$days")
    masa_label="${days} hari"
  fi
  local created=$(date +"%Y-%m-%d")

  echo "$username|$uuid|$exp|$created|$ip_limit|$quota_mb" >> "$DB_VMESS"

  local tmp=$(mktemp)
  jq --arg uuid "$uuid" --arg email "$username" \
    '(.inbounds[] | select(.tag == "vmess-ws-tls" or .tag == "vmess-ws-ntls") | .settings.clients) += [{"id": $uuid, "alterId": 0, "email": $email}]' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
  ml_sync

  local domain=$(get_domain)
  local link_tls=$(gen_vmess_link "$username" "$uuid" "$domain" "tls")
  local link_ntls=$(gen_vmess_link "$username" "$uuid" "$domain" "ntls")

  tg_notify "✅ <b>AKUN VMESS BERHASIL DIBUAT</b>

<b>Username</b>        : <code>$username</code>
<b>UUID</b>            : <code>$uuid</code>
<b>Domain</b>          : <code>$domain</code>
<b>Expired</b>         : <code>$exp</code> ($masa_label)
<b>Limit Device/IP</b> : <code>$(fmt_limit "$ip_limit")</code>
<b>Limit Kuota</b>     : <code>$(fmt_quota "$quota_mb")</code>

<b>── WS TLS (443, path /vmess-ws) ──</b>
<code>$(html_esc "$link_tls")</code>

<b>── WS nTLS (80, path /vmess-ntls) ──</b>
<code>$(html_esc "$link_ntls")</code>" "create"

  echo "$uuid"
}

delete_vmess() {
  local username="$1"
  sed -i "/^$username|/d" "$DB_VMESS"

  local tmp=$(mktemp)
  jq --arg email "$username" \
    '(.inbounds[] | select(.tag | startswith("vmess")) | .settings.clients) |= map(select(.email != $email))' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
  ml_sync
}

renew_vmess() {
  local username="$1"
  local days="$2"
  local exp=$(get_exp_date "$days")
  sed -i "s/^$username|\([^|]*\)|\([^|]*\)|\(.*\)$/$username|\1|$exp|\3/" "$DB_VMESS"
}

get_vmess_info() {
  local username="$1"
  grep "^$username|" "$DB_VMESS"
}

list_vmess() {
  cat "$DB_VMESS" 2>/dev/null
}

count_vmess() {
  wc -l < "$DB_VMESS" 2>/dev/null || echo 0
}

# ip_limit = field 5, quota_mb = field 6 (kosong di akun lama = pakai default)
get_vmess_ip_limit()  { get_vmess_info "$1" | cut -d'|' -f5; }
get_vmess_quota_mb()  { get_vmess_info "$1" | cut -d'|' -f6; }

# Rewrite pakai awk (bukan sed capture-group) supaya tetap aman dipakai
# di akun lama yang dibuat sebelum kolom ip_limit/quota_mb ada (cuma 4 field).
edit_vmess_limits() {
  local username="$1" ip_limit="$2" quota_mb="$3"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || ip_limit="${IP_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  grep -q "^$username|" "$DB_VMESS" 2>/dev/null || return 1
  local tmp=$(mktemp)
  awk -F'|' -v u="$username" -v ip="$ip_limit" -v q="$quota_mb" \
    'BEGIN{OFS="|"} $1==u {print $1,$2,$3,$4,ip,q; next} {print}' \
    "$DB_VMESS" > "$tmp" && mv "$tmp" "$DB_VMESS"
  reset_xray_user_traffic "$username"
  is_quota_disabled "vmess" "$username" && reactivate_xray_client "vmess" "$username"
  ml_sync
}

# ════════════════════════════════════════════════════════════
#  VLESS ACCOUNT MANAGEMENT
# ════════════════════════════════════════════════════════════
DB_VLESS="$DB_DIR/vless.db"

create_vless() {
  local username="$1"
  grep -q "^$username|" "$DB_VLESS" 2>/dev/null && return 1
  local days="$2"
  local ip_limit="${3:-$IP_LIMIT_DEFAULT}"
  local quota_mb="${4:-$QUOTA_DEFAULT_MB}"
  local trial_hours="${5:-0}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || ip_limit="${IP_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  [[ "$trial_hours" =~ ^[0-9]+$ ]] || trial_hours=0
  local uuid=$(gen_uuid)
  local exp masa_label
  if [[ "$trial_hours" -gt 0 ]]; then
    exp=$(get_exp_datetime_hours "$trial_hours")
    masa_label="Trial ${trial_hours} jam"
  else
    exp=$(get_exp_date "$days")
    masa_label="${days} hari"
  fi
  local created=$(date +"%Y-%m-%d")

  echo "$username|$uuid|$exp|$created|$ip_limit|$quota_mb" >> "$DB_VLESS"

  local tmp=$(mktemp)
  jq --arg uuid "$uuid" --arg email "$username" \
    '(.inbounds[] | select(.tag == "vless-ws-tls" or .tag == "vless-ws-ntls" or .tag == "vless-grpc-tls") | .settings.clients) += [{"id": $uuid, "email": $email, "flow": ""}]' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
  ml_sync

  local domain=$(get_domain)
  local link_tls=$(gen_vless_link "$username" "$uuid" "$domain" "tls")
  local link_ntls=$(gen_vless_link "$username" "$uuid" "$domain" "ntls")
  local link_grpc=$(gen_vless_grpc_link "$username" "$uuid" "$domain")

  tg_notify "✅ <b>AKUN VLESS BERHASIL DIBUAT</b>

<b>Username</b>        : <code>$username</code>
<b>UUID</b>            : <code>$uuid</code>
<b>Domain</b>          : <code>$domain</code>
<b>Expired</b>         : <code>$exp</code> ($masa_label)
<b>Limit Device/IP</b> : <code>$(fmt_limit "$ip_limit")</code>
<b>Limit Kuota</b>     : <code>$(fmt_quota "$quota_mb")</code>

<b>── WS TLS (443, path /vless-ws) ──</b>
<code>$(html_esc "$link_tls")</code>

<b>── WS nTLS (80, path /vless-ntls) ──</b>
<code>$(html_esc "$link_ntls")</code>

<b>── gRPC TLS (443, service vless-grpc) ──</b>
<code>$(html_esc "$link_grpc")</code>" "create"

  echo "$uuid"
}

delete_vless() {
  local username="$1"
  sed -i "/^$username|/d" "$DB_VLESS"

  local tmp=$(mktemp)
  jq --arg email "$username" \
    '(.inbounds[] | select(.tag | startswith("vless")) | .settings.clients) |= map(select(.email != $email))' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
  ml_sync
}

renew_vless() {
  local username="$1"
  local days="$2"
  local exp=$(get_exp_date "$days")
  sed -i "s/^$username|\([^|]*\)|\([^|]*\)|\(.*\)$/$username|\1|$exp|\3/" "$DB_VLESS"
}

get_vless_info() {
  local username="$1"
  grep "^$username|" "$DB_VLESS"
}

list_vless() {
  cat "$DB_VLESS" 2>/dev/null
}

count_vless() {
  wc -l < "$DB_VLESS" 2>/dev/null || echo 0
}

get_vless_ip_limit()  { get_vless_info "$1" | cut -d'|' -f5; }
get_vless_quota_mb()  { get_vless_info "$1" | cut -d'|' -f6; }

edit_vless_limits() {
  local username="$1" ip_limit="$2" quota_mb="$3"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || ip_limit="${IP_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  grep -q "^$username|" "$DB_VLESS" 2>/dev/null || return 1
  local tmp=$(mktemp)
  awk -F'|' -v u="$username" -v ip="$ip_limit" -v q="$quota_mb" \
    'BEGIN{OFS="|"} $1==u {print $1,$2,$3,$4,ip,q; next} {print}' \
    "$DB_VLESS" > "$tmp" && mv "$tmp" "$DB_VLESS"
  reset_xray_user_traffic "$username"
  is_quota_disabled "vless" "$username" && reactivate_xray_client "vless" "$username"
  ml_sync
}

# ════════════════════════════════════════════════════════════
#  TROJAN ACCOUNT MANAGEMENT
# ════════════════════════════════════════════════════════════
DB_TROJAN="$DB_DIR/trojan.db"

create_trojan() {
  local username="$1"
  grep -q "^$username|" "$DB_TROJAN" 2>/dev/null && return 1
  local days="$2"
  local ip_limit="${3:-$IP_LIMIT_DEFAULT}"
  local quota_mb="${4:-$QUOTA_DEFAULT_MB}"
  local trial_hours="${5:-0}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || ip_limit="${IP_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  [[ "$trial_hours" =~ ^[0-9]+$ ]] || trial_hours=0
  local password=$(gen_password)
  local exp masa_label
  if [[ "$trial_hours" -gt 0 ]]; then
    exp=$(get_exp_datetime_hours "$trial_hours")
    masa_label="Trial ${trial_hours} jam"
  else
    exp=$(get_exp_date "$days")
    masa_label="${days} hari"
  fi
  local created=$(date +"%Y-%m-%d")

  echo "$username|$password|$exp|$created|$ip_limit|$quota_mb" >> "$DB_TROJAN"

  local tmp=$(mktemp)
  jq --arg pass "$password" --arg email "$username" \
    '(.inbounds[] | select(.tag | startswith("trojan")) | .settings.clients) += [{"password": $pass, "email": $email}]' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
  ml_sync

  local domain=$(get_domain)
  local link_ws=$(gen_trojan_link "$username" "$password" "$domain" "ws")
  local link_grpc=$(gen_trojan_link "$username" "$password" "$domain" "grpc")

  tg_notify "✅ <b>AKUN TROJAN BERHASIL DIBUAT</b>

<b>Username</b>        : <code>$username</code>
<b>Password</b>        : <code>$password</code>
<b>Domain</b>          : <code>$domain</code>
<b>Expired</b>         : <code>$exp</code> ($masa_label)
<b>Limit Device/IP</b> : <code>$(fmt_limit "$ip_limit")</code>
<b>Limit Kuota</b>     : <code>$(fmt_quota "$quota_mb")</code>

<b>── WS TLS (443, path /trojan-ws) ──</b>
<code>$(html_esc "$link_ws")</code>

<b>── gRPC TLS (443, service trojan-grpc) ──</b>
<code>$(html_esc "$link_grpc")</code>" "create"

  echo "$password"
}

delete_trojan() {
  local username="$1"
  sed -i "/^$username|/d" "$DB_TROJAN"

  # hapus lewat email (bukan password) supaya entri ganda ikut bersih
  local tmp=$(mktemp)
  jq --arg email "$username" \
    '(.inbounds[] | select(.tag | startswith("trojan")) | .settings.clients) |= map(select(.email != $email))' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
  ml_sync
}

renew_trojan() {
  local username="$1"
  local days="$2"
  local exp=$(get_exp_date "$days")
  sed -i "s/^$username|\([^|]*\)|\([^|]*\)|\(.*\)$/$username|\1|$exp|\3/" "$DB_TROJAN"
}

get_trojan_info() {
  local username="$1"
  grep "^$username|" "$DB_TROJAN"
}

list_trojan() {
  cat "$DB_TROJAN" 2>/dev/null
}

count_trojan() {
  wc -l < "$DB_TROJAN" 2>/dev/null || echo 0
}

get_trojan_ip_limit()  { get_trojan_info "$1" | cut -d'|' -f5; }
get_trojan_quota_mb()  { get_trojan_info "$1" | cut -d'|' -f6; }

edit_trojan_limits() {
  local username="$1" ip_limit="$2" quota_mb="$3"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || ip_limit="${IP_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  grep -q "^$username|" "$DB_TROJAN" 2>/dev/null || return 1
  local tmp=$(mktemp)
  awk -F'|' -v u="$username" -v ip="$ip_limit" -v q="$quota_mb" \
    'BEGIN{OFS="|"} $1==u {print $1,$2,$3,$4,ip,q; next} {print}' \
    "$DB_TROJAN" > "$tmp" && mv "$tmp" "$DB_TROJAN"
  reset_xray_user_traffic "$username"
  is_quota_disabled "trojan" "$username" && reactivate_xray_client "trojan" "$username"
  ml_sync
}

# ════════════════════════════════════════════════════════════
#  SHADOWSOCKS ACCOUNT MANAGEMENT
# ════════════════════════════════════════════════════════════
DB_SS="$DB_DIR/ss.db"

create_ss() {
  local username="$1"
  grep -q "^$username|" "$DB_SS" 2>/dev/null && return 1
  local days="$2"
  local ip_limit="${3:-$IP_LIMIT_DEFAULT}"
  local quota_mb="${4:-$QUOTA_DEFAULT_MB}"
  local trial_hours="${5:-0}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || ip_limit="${IP_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  [[ "$trial_hours" =~ ^[0-9]+$ ]] || trial_hours=0
  local password=$(gen_password)
  local method="aes-128-gcm"
  local exp masa_label
  if [[ "$trial_hours" -gt 0 ]]; then
    exp=$(get_exp_datetime_hours "$trial_hours")
    masa_label="Trial ${trial_hours} jam"
  else
    exp=$(get_exp_date "$days")
    masa_label="${days} hari"
  fi
  local created=$(date +"%Y-%m-%d")

  echo "$username|$password|$method|$exp|$created|$ip_limit|$quota_mb" >> "$DB_SS"

  local tmp=$(mktemp)
  jq --arg pass "$password" --arg method "$method" \
    '(.inbounds[] | select(.tag | startswith("ss-")) | .settings.clients) += [{"method": $method, "password": $pass}]' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null

  local domain=$(get_domain)
  local link_ws=$(gen_ss_link "$username" "$password" "$domain" "ws")
  local link_grpc=$(gen_ss_link "$username" "$password" "$domain" "grpc")

  tg_notify "✅ <b>AKUN SHADOWSOCKS BERHASIL DIBUAT</b>

<b>Username</b>        : <code>$username</code>
<b>Password</b>        : <code>$password</code>
<b>Method</b>          : <code>$method</code>
<b>Domain</b>          : <code>$domain</code>
<b>Expired</b>         : <code>$exp</code> ($masa_label)
<b>Limit Device/IP</b> : <code>$(fmt_limit "$ip_limit")</code>
<b>Limit Kuota</b>     : <code>$(fmt_quota "$quota_mb")</code>

<b>── WS TLS (443, path /ss-ws) ──</b>
<code>$(html_esc "$link_ws")</code>

<b>── gRPC TLS (443, service ss-grpc) ──</b>
<code>$(html_esc "$link_grpc")</code>" "create"

  echo "$password"
}

delete_ss() {
  local username="$1"
  local passwords
  passwords=$(grep "^$username|" "$DB_SS" | cut -d'|' -f2 | jq -R . | jq -s .)
  [[ -z "$passwords" ]] && passwords='[]'
  sed -i "/^$username|/d" "$DB_SS"

  local tmp=$(mktemp)
  jq --argjson pass "$passwords" \
    '(.inbounds[] | select(.tag | startswith("ss-")) | .settings.clients) |= map(select((.password as $p | $pass | index($p)) == null))' \
    "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
}

renew_ss() {
  local username="$1"
  local days="$2"
  local exp=$(get_exp_date "$days")
  sed -i "s/^$username|\([^|]*\)|\([^|]*\)|\([^|]*\)|\(.*\)$/$username|\1|\2|$exp|\4/" "$DB_SS"
}

get_ss_info() {
  local username="$1"
  grep "^$username|" "$DB_SS"
}

list_ss() {
  cat "$DB_SS" 2>/dev/null
}

count_ss() {
  wc -l < "$DB_SS" 2>/dev/null || echo 0
}

get_ss_ip_limit()  { get_ss_info "$1" | cut -d'|' -f6; }
get_ss_quota_mb()  { get_ss_info "$1" | cut -d'|' -f7; }

edit_ss_limits() {
  local username="$1" ip_limit="$2" quota_mb="$3"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || ip_limit="${IP_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  grep -q "^$username|" "$DB_SS" 2>/dev/null || return 1
  local tmp=$(mktemp)
  awk -F'|' -v u="$username" -v ip="$ip_limit" -v q="$quota_mb" \
    'BEGIN{OFS="|"} $1==u {print $1,$2,$3,$4,$5,ip,q; next} {print}' \
    "$DB_SS" > "$tmp" && mv "$tmp" "$DB_SS"
  reset_xray_user_traffic "$username"
  is_quota_disabled "ss" "$username" && reactivate_xray_client "ss" "$username"
}

# ════════════════════════════════════════════════════════════
#  DELETE EXPIRED ACCOUNTS
# ════════════════════════════════════════════════════════════
delete_expired() {
  local today=$(date +%s)
  local domain=$(get_domain)

  # VMess
  while IFS='|' read -r user uuid exp created; do
    [[ -z "$user" ]] && continue
    local expd=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    if [[ $expd -lt $today ]]; then
      delete_vmess "$user"
      echo "[$(date)] Deleted expired VMess: $user (exp: $exp)"
      tg_notify "⛔ <b>Akun VMess Expired &amp; Dihapus</b>

Username: <code>$user</code>
Domain: <code>$domain</code>
Expired: <code>$exp</code>" "delete"
    fi
  done < <(cat "$DB_VMESS" 2>/dev/null)

  # VLess
  while IFS='|' read -r user uuid exp created; do
    [[ -z "$user" ]] && continue
    local expd=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    if [[ $expd -lt $today ]]; then
      delete_vless "$user"
      echo "[$(date)] Deleted expired VLess: $user (exp: $exp)"
      tg_notify "⛔ <b>Akun VLess Expired &amp; Dihapus</b>

Username: <code>$user</code>
Domain: <code>$domain</code>
Expired: <code>$exp</code>" "delete"
    fi
  done < <(cat "$DB_VLESS" 2>/dev/null)

  # Trojan
  while IFS='|' read -r user pass exp created; do
    [[ -z "$user" ]] && continue
    local expd=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    if [[ $expd -lt $today ]]; then
      delete_trojan "$user"
      echo "[$(date)] Deleted expired Trojan: $user (exp: $exp)"
      tg_notify "⛔ <b>Akun Trojan Expired &amp; Dihapus</b>

Username: <code>$user</code>
Domain: <code>$domain</code>
Expired: <code>$exp</code>" "delete"
    fi
  done < <(cat "$DB_TROJAN" 2>/dev/null)

  # Shadowsocks
  while IFS='|' read -r user pass method exp created; do
    [[ -z "$user" ]] && continue
    local expd=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    if [[ $expd -lt $today ]]; then
      delete_ss "$user"
      echo "[$(date)] Deleted expired SS: $user (exp: $exp)"
      tg_notify "⛔ <b>Akun Shadowsocks Expired &amp; Dihapus</b>

Username: <code>$user</code>
Domain: <code>$domain</code>
Expired: <code>$exp</code>" "delete"
    fi
  done < <(cat "$DB_SS" 2>/dev/null)

  # SSH
  delete_expired_ssh
}

# ════════════════════════════════════════════════════════════
#  GENERATE LINKS
# ════════════════════════════════════════════════════════════

# ─── VMess Link ────────────────────────────────────────────
# ════════════════════════════════════════════════════════════
#  MAXLOGIN (opsional): batas perangkat Xray per akun lewat token di path link
#  Aktif hanya bila service vpn-maxlogin terpasang & jalan. Kalau tidak: perilaku lama.
# ════════════════════════════════════════════════════════════
ML_BIN="${ML_BIN:-/etc/vpn-script/maxlogin/maxlogin_service.py}"
ML_CFG="${ML_CFG:-/etc/vpn-script/maxlogin.json}"

ml_enabled() {
  [[ -f "$ML_BIN" ]] || return 1
  [[ -n "${ML_NO_SYSTEMD:-}" ]] && return 0
  systemctl is-active --quiet vpn-maxlogin 2>/dev/null
}

# Token slot aktif milik akun, satu per baris (kosong = akun tidak diatur MaxLogin)
ml_limit_of() {
  awk -F'|' -v u="$1" '$1==u && ($5+0)>m {m=$5+0} END{print m+0}' "$DB_VMESS" "$DB_VLESS" "$DB_TROJAN" 2>/dev/null
}
ml_tokens() {
  ml_enabled || return 0
  local out i lim
  for i in 1 2 3; do
    out=$(MAXLOGIN_CONFIG="$ML_CFG" timeout 5 python3 "$ML_BIN" tokens "$1" 2>/dev/null)
    [[ -n "$out" ]] && { echo "$out"; return 0; }
    # kosong: akun tanpa limit memang tanpa token; akun berlimit seharusnya punya token -> coba lagi
    lim=$(ml_limit_of "$1")
    [[ "$lim" =~ ^[0-9]+$ ]] && (( lim > 0 )) || return 0
    sleep 0.4
  done
  return 0
}

# Sinkronkan akun script -> MaxLogin dan pindahkan akun berlimit ke inbound -ml (tanpa restart Xray)
ml_sync() {
  ml_enabled || return 0
  # Xray baru di-reload: tunggu API siap (maks ~6 dtk) supaya pemindahan akun lewat API tidak gagal
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    timeout 2 xray api statsquery --server="${XRAY_API_ADDR:-127.0.0.1:10085}" -pattern "user>>>" >/dev/null 2>&1 && break
    sleep 0.5
  done
  MAXLOGIN_CONFIG="$ML_CFG" timeout 20 python3 "$ML_BIN" sync >/dev/null 2>&1
  if grep -Eq '"xray_manage"[[:space:]]*:[[:space:]]*true' "$ML_CFG" 2>/dev/null; then
    MAXLOGIN_CONFIG="$ML_CFG" timeout 30 python3 "$ML_BIN" xray-sync --runtime >/dev/null 2>&1
  fi
  return 0
}

# Pisahkan penanda mode tunggal ("shared:TOKEN") dari token biasa; isi _t (token) dan _lab (label) milik pemanggil
ml_split_labels() {
  local _k
  _lab=()
  for _k in "${!_t[@]}"; do
    if [[ "${_t[$_k]}" == shared:* ]]; then _t[$_k]="${_t[$_k]#shared:}"; _lab[$_k]="shared"
    else _lab[$_k]="dev$((_k+1))"; fi
  done
}

ML_NA="(tidak tersedia: akun berlimit perangkat hanya lewat WS bertoken: TLS 443 atau nTLS 80)"

gen_vmess_link() {
  local user="$1"
  local uuid="$2"
  local domain="$3"
  local type="${4:-tls}"
  local remark="$5"

  local port path
  if [[ "$type" == "tls" ]]; then
    port=443; path="/vmess-ws"
  else
    port=80; path="/vmess-ntls"
  fi

  local _t _lab; mapfile -t _t < <(ml_tokens "$user"); ml_split_labels
  if (( ${#_t[@]} > 0 )); then
    local _pt=443 _pp=vmess-ws _tl=tls _i _o=""
    [[ "$type" == "tls" ]] || { _pt=80; _pp=vmess-ntls; _tl="$type"; }
    for _i in "${!_t[@]}"; do
      local _j="{\"v\":\"2\",\"ps\":\"${remark:-$user-vmess}-${type}-${_lab[$_i]}\",\"add\":\"$domain\",\"port\":\"$_pt\",\"id\":\"$uuid\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$domain\",\"path\":\"/${_pp}/${_t[$_i]}\",\"tls\":\"$_tl\"}"
      _o+="vmess://$(echo -n "$_j" | base64 -w 0)"$'\n'
    done
    printf '%s\n' "${_o%$'\n'}"; return 0
  fi

  local json="{\"v\":\"2\",\"ps\":\"${remark:-$user-vmess-$type}\",\"add\":\"$domain\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$domain\",\"path\":\"$path\",\"tls\":\"$type\"}"
  echo "vmess://$(echo -n "$json" | base64 -w 0)"
}

# ─── VLess Link ────────────────────────────────────────────
gen_vless_link() {
  local user="$1"
  local uuid="$2"
  local domain="$3"
  local type="${4:-tls}"
  local remark="$5"

  local _t _lab; mapfile -t _t < <(ml_tokens "$user"); ml_split_labels
  if (( ${#_t[@]} > 0 )); then
    local _pt=443 _pp=vless-ws _sc=tls _i _o=""
    [[ "$type" == "tls" ]] || { _pt=80; _pp=vless-ntls; _sc=none; }
    for _i in "${!_t[@]}"; do
      _o+="vless://${uuid}@${domain}:${_pt}?encryption=none&security=${_sc}&type=ws&host=${domain}&path=/${_pp}/${_t[$_i]}&sni=${domain}#${remark:-$user-vless}-${type}-${_lab[$_i]}"$'\n'
    done
    printf '%s\n' "${_o%$'\n'}"; return 0
  fi

  local port path security
  if [[ "$type" == "tls" ]]; then
    port=443; path="/vless-ws"; security="tls"
  else
    port=80; path="/vless-ntls"; security="none"
  fi

  echo "vless://${uuid}@${domain}:${port}?encryption=none&security=${security}&type=ws&host=${domain}&path=${path}&sni=${domain}#${remark:-$user-vless-$type}"
}

# ─── VLess gRPC Link ───────────────────────────────────────
gen_vless_grpc_link() {
  local user="$1"
  local uuid="$2"
  local domain="$3"
  local remark="$4"

  [[ -n "$(ml_tokens "$user")" ]] && { echo "$ML_NA"; return 0; }
  echo "vless://${uuid}@${domain}:443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&sni=${domain}#${remark:-$user-vless-grpc}"
}

# ─── Trojan Link ───────────────────────────────────────────
gen_trojan_link() {
  local user="$1"
  local pass="$2"
  local domain="$3"
  local type="${4:-ws}"
  local remark="$5"

  local _t _lab; mapfile -t _t < <(ml_tokens "$user"); ml_split_labels
  if (( ${#_t[@]} > 0 )); then
    [[ "$type" == "ws" ]] || { echo "$ML_NA"; return 0; }
    local _i _o=""
    for _i in "${!_t[@]}"; do
      _o+="trojan://${pass}@${domain}:443?security=tls&type=ws&host=${domain}&path=/trojan-ws/${_t[$_i]}&sni=${domain}#${remark:-$user-trojan}-${_lab[$_i]}"$'\n'
    done
    printf '%s\n' "${_o%$'\n'}"; return 0
  fi

  local path
  if [[ "$type" == "grpc" ]]; then
    path="trojan-grpc"
    echo "trojan://${pass}@${domain}:443?security=tls&type=grpc&serviceName=${path}&sni=${domain}#${remark:-$user-trojan-grpc}"
  else
    path="/trojan-ws"
    echo "trojan://${pass}@${domain}:443?security=tls&type=ws&host=${domain}&path=${path}&sni=${domain}#${remark:-$user-trojan-ws}"
  fi
}

# ─── Shadowsocks Link ──────────────────────────────────────
gen_ss_link() {
  local user="$1"
  local pass="$2"
  local domain="$3"
  local type="${4:-ws}"
  local remark="$5"

  local method="aes-128-gcm"
  local path
  if [[ "$type" == "grpc" ]]; then
    path="ss-grpc"
    local base="${method}:${pass}"
    echo "ss://$(echo -n "$base" | base64 -w 0)@${domain}:443?security=tls&type=grpc&serviceName=${path}&sni=${domain}#${remark:-$user-ss-grpc}"
  else
    path="/ss-ws"
    local base="${method}:${pass}"
    echo "ss://$(echo -n "$base" | base64 -w 0)@${domain}:443?security=tls&type=ws&host=${domain}&path=${path}&sni=${domain}#${remark:-$user-ss-ws}"
  fi
}

# ════════════════════════════════════════════════════════════
#  CHANGE DOMAIN
# ════════════════════════════════════════════════════════════
change_domain() {
  local new_domain="$1"
  local old_domain=$(get_domain)

  sed -i "s/$old_domain/$new_domain/g" /etc/nginx/conf.d/xray.conf 2>/dev/null

  systemctl stop nginx 2>/dev/null
  /root/.acme.sh/acme.sh --issue --standalone -d "$new_domain" \
    --keylength ec-256 --httpport 80 --server letsencrypt 2>/dev/null

  /root/.acme.sh/acme.sh --installcert -d "$new_domain" \
    --ecc \
    --key-file /etc/ssl/xray/xray.key \
    --fullchain-file /etc/ssl/xray/xray.crt \
    --reloadcmd "cat /etc/ssl/xray/xray.crt /etc/ssl/xray/xray.key > /etc/ssl/xray/xray.pem 2>/dev/null; chmod 600 /etc/ssl/xray/xray.pem; systemctl restart xray nginx 2>/dev/null; systemctl reload haproxy 2>/dev/null" 2>/dev/null

  # Selalu pastikan file gabungan (dibutuhkan HAProxy: SSH-SSL port 444 & multiplex 443)
  # ada dan sinkron, terlepas dari apakah reloadcmd di atas sempat kepanggil atau tidak.
  cat /etc/ssl/xray/xray.crt /etc/ssl/xray/xray.key > /etc/ssl/xray/xray.pem 2>/dev/null
  chmod 600 /etc/ssl/xray/xray.pem 2>/dev/null

  echo "$new_domain" > $SCRIPT_DIR/domain

  nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null
  systemctl restart xray 2>/dev/null
  systemctl reload haproxy 2>/dev/null
}

# ════════════════════════════════════════════════════════════
#  REGENERATE NGINX CONFIG (single source of truth)
#  Dipakai untuk retrofit VPS yang xray.conf-nya belum punya
#  location /ssh-ws (port benar) & /ssh-ws-ssh. Aman dijalankan
#  berkali-kali: backup otomatis + nginx -t + rollback bila error.
# ════════════════════════════════════════════════════════════
# Server Message Dropbear: Dropbear baru mengabaikan DROPBEAR_BANNER, banner hanya tampil
# lewat opsi "-b" di DROPBEAR_EXTRA_ARGS. Fungsi ini menambahkannya (idempoten) dan
# membuat banner.txt bila belum ada (banner buatan pengguna tidak ditimpa). Batas Dropbear: 2000 byte.
ensure_dropbear_banner() {
  local cf="/etc/default/dropbear" bn="/etc/vpn-script/banner.txt" changed=0
  [[ -f "$cf" ]] || return 0
  if [[ ! -s "$bn" ]]; then
    printf '%s\n' '<br><br>' '<font color="#2979FF">━━━━━━━━━━</font><font color="#A020F0">ஜ۩۞۩ஜ</font><font color="#2979FF">━━━━━━━━━━</font><br><br>' \
      '<b><font color="#006D8F">--- ✦ by CHANEL-OG ✦ ---</font></b><br><br>' '<font color="#FF1744">! TERM OF SERVICE !</font><br>' \
      '<font color="#2979FF">NO SPAM</font><br>' '<font color="#2979FF">NO DDOS</font><br>' '<font color="#00B0FF">NO HACKING AND CARDING</font><br>' \
      '<font color="#FF1744">NO TORRENT!!</font><br>' '<font color="#FF1493">NO MULTI LOGIN!!</font><br>' '<br>' \
      '<font color="#00B0FF">==ENJOOOOY==</font><br><br>' > "$bn"
  fi
  if grep -q '^DROPBEAR_EXTRA_ARGS=' "$cf"; then
    grep '^DROPBEAR_EXTRA_ARGS=' "$cf" | grep -q -- ' -b ' || { sed -i 's|^\(DROPBEAR_EXTRA_ARGS=".*\)"|\1 -b /etc/vpn-script/banner.txt"|' "$cf"; changed=1; }
  else
    echo 'DROPBEAR_EXTRA_ARGS="-b /etc/vpn-script/banner.txt"' >> "$cf"; changed=1
  fi
  (( changed )) && systemctl restart dropbear 2>/dev/null
  return 0
}

# Banner OpenSSH (jalur WS-TLS 443 & SSL) memakai file yang sama dengan Dropbear.
# Aman: cek `sshd -t`, rollback bila gagal, reload (bukan restart) agar sesi aktif tidak putus.
ensure_ssh_banner() {
  local bn="/etc/vpn-script/banner.txt" cf="/etc/ssh/sshd_config" dr="/etc/ssh/sshd_config.d/00-vpn-banner.conf" bak
  [[ -f "$cf" && -s "$bn" ]] || return 0
  command -v sshd >/dev/null 2>&1 || return 0
  sshd -T 2>/dev/null | grep -qix "banner $bn" && return 0
  bak="$cf.bak.banner"
  cp "$cf" "$bak" 2>/dev/null
  if grep -qiE '^[[:space:]]*Include[[:space:]]' "$cf" && [[ -d /etc/ssh/sshd_config.d ]]; then
    printf 'Banner %s\n' "$bn" > "$dr"
  else
    sed -i -E '/^[[:space:]]*Banner[[:space:]]/d' "$cf"
    sed -i "1i Banner $bn" "$cf"
  fi
  if sshd -t 2>/dev/null && sshd -T 2>/dev/null | grep -qix "banner $bn"; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    rm -f "$bak"
  else
    rm -f "$dr"; [[ -f "$bak" ]] && mv -f "$bak" "$cf"
    return 1
  fi
  return 0
}

# Blok /api/ & /panel/ milik panel web disimpan di snippet terpisah supaya TIDAK hilang
# saat config Nginx dibuat ulang (regenerate_nginx_conf meng-include snippet ini).
ensure_panel_snippet() {
  local snip="/etc/nginx/snippets/vpn-panel-ui.conf" sock
  [[ -f /var/www/vpn-api/index.php ]] || return 0
  sock=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)
  [[ -n "$sock" ]] || return 0
  mkdir -p /etc/nginx/snippets
  cat > "$snip" <<EOS
# --- VPN PANEL API & UI (dikelola script, aman dari regenerate config) ---
location /api/ {
    fastcgi_pass unix:$sock;
    fastcgi_param SCRIPT_FILENAME /var/www/vpn-api/index.php;
    fastcgi_param QUERY_STRING \$query_string;
    fastcgi_param REQUEST_METHOD \$request_method;
    fastcgi_param CONTENT_TYPE \$content_type;
    fastcgi_param CONTENT_LENGTH \$content_length;
    fastcgi_param REQUEST_URI \$request_uri;
    fastcgi_param HTTP_X_API_KEY \$http_x_api_key;
    fastcgi_param SERVER_SOFTWARE nginx;
    fastcgi_param SERVER_PROTOCOL \$server_protocol;
    fastcgi_index index.php;
}
EOS
  # halaman panel web hanya kalau terpasang (mode API saja: tanpa /panel/)
  if [[ -f /var/www/vpn-panel/index.html ]]; then
    cat >> "$snip" <<'EOP'
location /panel/ {
    alias /var/www/vpn-panel/;
    index index.html;
    try_files $uri $uri/ /panel/index.html;
}
EOP
  fi
}

regenerate_nginx_conf() {
  ensure_panel_snippet
  local domain="$1"
  [[ -z "$domain" ]] && domain=$(get_domain)
  local conf="/etc/nginx/conf.d/xray.conf"
  local backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"

  [[ -f "$conf" ]] && cp "$conf" "$backup"
  mkdir -p /etc/nginx/conf.d /var/www/html

  # Kalau addon multiplex (port 443 SSH-SSL + Xray bareng) aktif, https block
  # harus bind ke internal 127.0.0.1:8443 (public 443 dipegang stream{} block)
  local https_listen_lines
  if [[ -f /etc/vpn-script/.multiplex-443-active ]]; then
    https_listen_lines="listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;"
  else
    https_listen_lines="listen 443 ssl http2;
    listen [::]:443 ssl http2;"
  fi

  cat > "$conf" <<EOF2
# ============================================================
#   CHANELOG VPN - NGINX ALL-IN-ONE CONFIG (regenerated)
#   Port 80  : VMess nTLS | VLess nTLS | SSH-WS nTLS | SSH-WS-SSH nTLS
#   Port 443 : VMess TLS | VLess TLS | Trojan TLS | SS TLS
#              VMess gRPC | VLess gRPC | Trojan gRPC | SS gRPC
#              SSH-WS TLS | SSH-WS-SSH TLS
#   Port 8880/8080/2080/2082 : SSH-WS / SSH-WS-SSH nTLS (alternatif)
# ============================================================

# ─── Port 80 — non-TLS ───
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    include /etc/nginx/snippets/vpn-ovpn-*.conf; # vpn-ovpn-ws

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

    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${WS_DROPBEAR_PORT};
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
        proxy_pass http://127.0.0.1:${WS_OPENSSH_PORT};
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
        proxy_pass http://127.0.0.1:${WS_OPENSSH_PORT};
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
EOF2

  local alt_port
  for alt_port in 8880 8080 2080 2082; do
    cat >> "$conf" <<EOF2

# ─── Port ${alt_port} — SSH-WS / SSH-WS-SSH nTLS (alt) ───
server {
    listen ${alt_port};
    listen [::]:${alt_port};
    server_name ${domain};

    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${WS_DROPBEAR_PORT};
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
        proxy_pass http://127.0.0.1:${WS_OPENSSH_PORT};
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
EOF2
  done

  cat >> "$conf" <<EOF2

# ─── Port 443 — HTTPS/TLS (ALL PROTOCOLS) ───
server {
    ${https_listen_lines}
    server_name ${domain};
    include /etc/nginx/snippets/vpn-ovpn-*.conf; # vpn-ovpn-ws
    include /etc/nginx/snippets/vpn-panel-*.conf; # vpn-panel

    ssl_certificate /etc/ssl/xray/xray.crt;
    ssl_certificate_key /etc/ssl/xray/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

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

    location /ssh-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${WS_DROPBEAR_PORT};
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
        proxy_pass http://127.0.0.1:${WS_OPENSSH_PORT};
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
        root /var/www/html;
        index index.html;
    }
}
EOF2

  if [[ ! -f /var/www/html/index.html ]]; then
    cat > /var/www/html/index.html <<EOF3
<!DOCTYPE html>
<html>
<head><title>${domain}</title></head>
<body style="background:#1a1a2e;color:#e0e0e0;font-family:monospace;text-align:center;padding:50px">
<h1 style="color:#00d4ff">Server Running</h1>
<p>Secure VPN Tunnel Server</p>
</body>
</html>
EOF3
  fi

  # MaxLogin Xray aktif: sisipkan lagi include-nya ke config yang baru dibuat
  if [[ -f "$SCRIPT_DIR/.maxlogin-xray" && -f "$SCRIPT_DIR/addon/maxlogin/maxlogin-xray.sh" ]]; then
    bash "$SCRIPT_DIR/addon/maxlogin/maxlogin-xray.sh" inject "$conf" >/dev/null 2>&1
  fi

  if nginx -t 2>/tmp/nginx_test_err.txt; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
    rm -f /tmp/nginx_test_err.txt
    return 0
  else
    echo -e "${RED}[GAGAL]${NC} Konfigurasi nginx baru error, rollback..." >&2
    cat /tmp/nginx_test_err.txt >&2
    [[ -f "$backup" ]] && cp "$backup" "$conf"
    systemctl reload nginx 2>/dev/null
    return 1
  fi
}

# ════════════════════════════════════════════════════════════
#  SSH / SSH-WS / SSH-SSL (ADDON)
# ════════════════════════════════════════════════════════════
DB_SSH="$DB_DIR/ssh.db"

# Port backend proxy SSH-WS (dipakai systemd ws-dropbear/ws-openssh
# DAN oleh konfigurasi Nginx di bawah — HARUS selalu sinkron)
WS_DROPBEAR_PORT=2095   # nginx /ssh-ws      -> ws-dropbear -> dropbear:109
WS_OPENSSH_PORT=2093    # nginx /ssh-ws-ssh  -> ws-openssh  -> sshd:22
SSH_BACKEND_PORT=143    # stunnel4/HAProxy (SSL, SNI-only, tanpa payload) -> dropbear:143 LANGSUNG
STUNNEL_SSL_PORT=777    # Dropbear SSL (stunnel4, SNI-only) - konvensi umum komunitas SSH-WS
HAPROXY_SSL_PORT=444     # OpenSSH SSL (haproxy, SNI-only) - konvensi umum komunitas SSH-WS

gen_ssh_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 10 || \
  openssl rand -base64 8 | tr -dc 'A-Za-z0-9' | head -c 10
}

# Blok teks OpenVPN untuk notifikasi Telegram akun SSH (kosong kalau OpenVPN belum terpasang)
ssh_ovpn_tg_block() {
  local u="$1" dir="${SCRIPT_DIR:-/etc/vpn-script}" tcp udp js name url lbl
  [[ -f "$dir/menu/openvpn.sh" && -f /etc/openvpn/server/vpn-script-tcp.conf ]] || return 0
  tcp=$(awk '/^port /{print $2; exit}' /etc/openvpn/server/vpn-script-tcp.conf 2>/dev/null)
  udp=$(awk '/^port /{print $2; exit}' /etc/openvpn/server/vpn-script-udp.conf 2>/dev/null)
  echo ""
  echo "<b>── OpenVPN (login sama dengan akun ini) ──</b>"
  echo "TCP          : ${tcp:-1194}"
  echo "UDP          : ${udp:-2200}"
  echo "WS nTLS      : 80 (path /ovpn-ws, butuh aplikasi dengan payload)"
  echo "WS TLS       : 443 (path /ovpn-ws)"
  js=$(timeout 40 bash "$dir/menu/openvpn.sh" dl-json "$u" 2>/dev/null)
  if [[ "$(echo "$js" | jq -r '.ok' 2>/dev/null)" == "true" ]]; then
    echo ""
    echo "<b>Download config .ovpn</b> (berlaku $(echo "$js" | jq -r '.ttl_min // 60') menit):"
    while IFS='|' read -r name url; do
      case "$name" in
        *-vpn-tcp.ovpn)  lbl="TCP" ;;
        *-vpn-udp.ovpn)  lbl="UDP" ;;
        *-vpn-wss.ovpn)  lbl="WS TLS (443)" ;;
        *-vpn-ws.ovpn)   lbl="WS nTLS (80)" ;;
        *)               lbl="$name" ;;
      esac
      echo "$lbl: $url"
    done < <(echo "$js" | jq -r '.files[]? | "\(.name)|\(.url)"')
  fi
}

create_ssh() {
  local username="$1"
  local days="$2"
  local password="${3:-$(gen_ssh_password)}"
  local session_limit="${4:-$SESSION_LIMIT_DEFAULT}"
  local quota_mb="${5:-$QUOTA_DEFAULT_MB}"
  local trial_hours="${6:-0}"
  [[ "$session_limit" =~ ^[0-9]+$ ]] || session_limit="${SESSION_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  [[ "$trial_hours" =~ ^[0-9]+$ ]] || trial_hours=0

  local exp exp_useradd masa_label
  if [[ "$trial_hours" -gt 0 ]]; then
    exp=$(get_exp_datetime_hours "$trial_hours")
    exp_useradd=$(get_exp_date_from_hours "$trial_hours")
    masa_label="Trial ${trial_hours} jam"
  else
    exp=$(get_exp_date "$days")
    exp_useradd="$exp"
    masa_label="${days} hari"
  fi
  local created=$(date +"%Y-%m-%d")

  # Jaring pengaman: Dropbear menolak login (tampak sebagai 'password salah')
  # untuk akun dengan shell yang gak terdaftar di /etc/shells.
  grep -qxF "/bin/false" /etc/shells 2>/dev/null || echo "/bin/false" >> /etc/shells

  useradd -e "$exp_useradd" -s /bin/false -M "$username" 2>/dev/null
  echo "$username:$password" | chpasswd 2>/dev/null

  echo "$username|$password|$exp|$created|$session_limit|$quota_mb" >> "$DB_SSH"
  [[ "$quota_mb" -gt 0 ]] && setup_ssh_quota_accounting "$username"

  local domain=$(get_domain)
  local payload_ws=$(ws_payload_string "$domain" "80" "/ssh-ws")
  local payload_ws_ssh=$(ws_payload_string "$domain" "80" "/ssh-ws-ssh")

  tg_notify "✅ <b>AKUN SSH BERHASIL DIBUAT</b>

<b>Username</b>        : <code>$username</code>
<b>Password</b>        : <code>$password</code>
<b>Domain/IP</b>       : <code>$domain</code>
<b>Expired</b>         : <code>$exp</code> ($masa_label)
<b>Max Login</b>       : <code>$(fmt_limit "$session_limit")</code>
<b>Limit Kuota</b>     : <code>$(fmt_quota "$quota_mb")</code>

<b>── Port Koneksi ──</b>
SSH Direct   : 442 / 109 / 143
SSH-SSL      : $STUNNEL_SSL_PORT (Dropbear) / $HAPROXY_SSL_PORT (OpenSSH) — SNI bebas, tanpa payload
SSH-WS nTLS  : 80 / 8880 / 8080 / 2080 / 2082
SSH-WS TLS   : 443
Path         : /ssh-ws (Dropbear) atau /ssh-ws-ssh (OpenSSH)

<b>── Payload WS ──</b>
Dropbear:
<code>$payload_ws</code>

OpenSSH:
<code>$payload_ws_ssh</code>
$(ssh_ovpn_tg_block "$username")" "create"

  bash /etc/vpn-script/addon/ssh-maxlogin.sh set "$username" "$session_limit" &>/dev/null
  echo "$password"
}

get_ssh_quota_mb() { get_ssh_info "$1" | cut -d'|' -f6; }

edit_ssh_limits() {
  local username="$1" session_limit="$2" quota_mb="$3"
  [[ "$session_limit" =~ ^[0-9]+$ ]] || session_limit="${SESSION_LIMIT_DEFAULT:-2}"
  [[ "$quota_mb" =~ ^[0-9]+$ ]] || quota_mb="${QUOTA_DEFAULT_MB:-0}"
  grep -q "^$username|" "$DB_SSH" 2>/dev/null || return 1
  local tmp=$(mktemp)
  awk -F'|' -v u="$username" -v s="$session_limit" -v q="$quota_mb" \
    'BEGIN{OFS="|"} $1==u {print $1,$2,$3,$4,s,q; next} {print}' \
    "$DB_SSH" > "$tmp" && mv "$tmp" "$DB_SSH"
  [[ "$quota_mb" -gt 0 ]] && setup_ssh_quota_accounting "$username"
  reset_ssh_usage "$username"
  bash /etc/vpn-script/addon/ssh-maxlogin.sh set "$username" "$session_limit" &>/dev/null
  if is_quota_disabled "ssh" "$username"; then
    usermod -U "$username" 2>/dev/null
    clear_quota_disabled "ssh" "$username"
  fi
}

delete_ssh() {
  local username="$1"
  userdel -f "$username" 2>/dev/null
  bash /etc/vpn-script/addon/ssh-maxlogin.sh remove "$username" &>/dev/null
  teardown_ssh_quota_accounting "$username"
  sed -i "/^$username|/d" "$DB_SSH"
}

renew_ssh() {
  local username="$1"
  local days="$2"
  local exp=$(get_exp_date "$days")
  chage -E "$exp" "$username" 2>/dev/null
  sed -i "s/^$username|\([^|]*\)|\([^|]*\)|\(.*\)$/$username|\1|$exp|\3/" "$DB_SSH"
}

get_ssh_info() {
  local username="$1"
  grep "^$username|" "$DB_SSH" 2>/dev/null
}

list_ssh() {
  cat "$DB_SSH" 2>/dev/null
}

count_ssh() {
  wc -l < "$DB_SSH" 2>/dev/null || echo 0
}

delete_expired_ssh() {
  local today=$(date +%s)
  local domain=$(get_domain)
  while IFS='|' read -r user pass exp created limit; do
    [[ -z "$user" ]] && continue
    local expd=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    if [[ $expd -lt $today ]]; then
      delete_ssh "$user"
      echo "[$(date)] Deleted expired SSH: $user (exp: $exp)"
      tg_notify "⛔ <b>Akun SSH Expired &amp; Dihapus</b>

Username: <code>$user</code>
Domain: <code>$domain</code>
Expired: <code>$exp</code>" "delete"
    fi
  done < <(list_ssh)
}

# ════════════════════════════════════════════════════════════
#  SERVICE MANAGEMENT
# ════════════════════════════════════════════════════════════
MANAGED_SERVICES=(xray nginx dropbear stunnel4 ws-dropbear ws-openssh haproxy)

service_display_name() {
  case "$1" in
    xray)        echo "Xray (All Protocols)" ;;
    nginx)       echo "Nginx" ;;
    dropbear)    echo "Dropbear SSH" ;;
    stunnel4)    echo "Stunnel4 (SSH-SSL, langsung ke Dropbear)" ;;
    ws-dropbear) echo "SSH-WS -> Dropbear" ;;
    ws-openssh)  echo "SSH-WS-SSH -> OpenSSH" ;;
    haproxy)     echo "HAProxy (SSH-SSL -> OpenSSH, port $HAPROXY_SSL_PORT)" ;;
    *)           echo "$1" ;;
  esac
}

is_service_installed() {
  local svc="$1"
  systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" && return 0
  command -v "$svc" &>/dev/null && return 0
  return 1
}

service_toggle_start()   { systemctl start   "$1" 2>/dev/null || service "$1" start   2>/dev/null; }
service_toggle_stop()    { systemctl stop    "$1" 2>/dev/null || service "$1" stop    2>/dev/null; }
service_toggle_restart() { systemctl restart "$1" 2>/dev/null || service "$1" restart 2>/dev/null; }

# ════════════════════════════════════════════════════════════
#  AUTO-UPDATE
# ════════════════════════════════════════════════════════════
UPDATE_RAW="https://raw.githubusercontent.com/oghc93/xray-tun/main"
VERSION_FILE="$SCRIPT_DIR/VERSION"

get_local_version() {
  cat "$VERSION_FILE" 2>/dev/null || echo "0.0.0"
}

get_remote_version() {
  curl -s --max-time 10 "$UPDATE_RAW/VERSION" 2>/dev/null
}

check_update_available() {
  local local_v remote_v
  local_v=$(get_local_version)
  remote_v=$(get_remote_version)
  [[ -z "$remote_v" ]] && return 1
  [[ "$local_v" != "$remote_v" ]] && { echo "$remote_v"; return 0; }
  return 1
}

UPDATE_FILES=(
  "lib.sh"
  "menu.sh"
  "menu/vmess.sh"
  "menu/vless.sh"
  "menu/trojan.sh"
  "menu/ss.sh"
  "menu/nginx.sh"
  "menu/dropbear.sh"
  "menu/haproxy.sh"
  "menu/sysinfo.sh"
  "menu/changedomain.sh"
  "menu/uninstall.sh"
  "menu/sshws.sh"
  "menu/services.sh"
  "menu/update.sh"
  "menu/telegram.sh"
  "menu/rebuild.sh"
  "menu/panel.sh"
  "menu/bbr.sh"
  "menu/openvpn.sh"
  "menu/security.sh"
  "menu/tools.sh"
  "menu/backup.sh"
  "addon/torrent-block.sh"
  "addon/tg-backup.py"
  "addon/quota-limiter.sh"
  "addon/real-ip-fix.sh"
)

update_fetch_file() {
  local relpath="$1"
  local tmp
  tmp=$(mktemp)
  if wget -q --timeout=30 "$UPDATE_RAW/$relpath" -O "$tmp" && [[ -s "$tmp" ]]; then
    mkdir -p "$(dirname "$SCRIPT_DIR/$relpath")"
    cp "$tmp" "$SCRIPT_DIR/$relpath"
    chmod +x "$SCRIPT_DIR/$relpath" 2>/dev/null
    rm -f "$tmp"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

update_fetch_addon_bin() {
  local tmp
  tmp=$(mktemp)
  if wget -q --timeout=30 "$UPDATE_RAW/addon/install-sshws.sh" -O "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mkdir -p "$SCRIPT_DIR/addon"
    cp "$tmp" "$SCRIPT_DIR/addon/install-sshws.sh"
    chmod +x "$SCRIPT_DIR/addon/install-sshws.sh"
    rm -f "$tmp"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

update_fetch_haproxy_addon() {
  local tmp
  tmp=$(mktemp)
  if wget -q --timeout=30 "$UPDATE_RAW/addon/haproxy-sshws-ssl.sh" -O "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mkdir -p "$SCRIPT_DIR/addon"
    cp "$tmp" "$SCRIPT_DIR/addon/haproxy-sshws-ssl.sh"
    chmod +x "$SCRIPT_DIR/addon/haproxy-sshws-ssl.sh"
    rm -f "$tmp"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

update_fetch_multiplex_addon() {
  local tmp
  tmp=$(mktemp)
  if wget -q --timeout=30 "$UPDATE_RAW/addon/enable-ssl-multiplex.sh" -O "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mkdir -p "$SCRIPT_DIR/addon"
    cp "$tmp" "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh"
    chmod +x "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh"
    rm -f "$tmp"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

ML_PKG_FILES=(maxlogin_core.py maxlogin_service.py xray_adapter.py maxlogin-xray.sh install-maxlogin.sh
  nginx-maxlogin.inc nginx-maxlogin-http.inc vpn-maxlogin.service maxlogin.json.example)

# Unduh seluruh paket MaxLogin Xray ke $SCRIPT_DIR/addon/maxlogin (semua-atau-tidak-sama-sekali)
update_fetch_maxlogin_pkg() {
  local f dir="$SCRIPT_DIR/addon/maxlogin" stage; stage=$(mktemp -d)
  for f in "${ML_PKG_FILES[@]}"; do
    if ! wget -q --timeout=30 "$UPDATE_RAW/addon/maxlogin/$f" -O "$stage/$f" 2>/dev/null || [[ ! -s "$stage/$f" ]]; then
      rm -rf "$stage"; return 1
    fi
  done
  mkdir -p "$dir"; cp "$stage"/* "$dir"/; chmod +x "$dir"/*.sh
  rm -rf "$stage"; return 0
}

update_fetch_maxlogin_addons() {
  local f ok=true
  for f in ssh-maxlogin.sh dropbear-fastkick.sh xray-maxlogin-daemon.sh; do
    local tmp; tmp=$(mktemp)
    if wget -q --timeout=30 "$UPDATE_RAW/addon/$f" -O "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      mkdir -p "$SCRIPT_DIR/addon"
      cp "$tmp" "$SCRIPT_DIR/addon/$f"
      chmod +x "$SCRIPT_DIR/addon/$f"
    else
      ok=false
    fi
    rm -f "$tmp"
  done
  for f in dropbear-fastkick.service xray-maxlogin.service; do
    local tmp; tmp=$(mktemp)
    if wget -q --timeout=30 "$UPDATE_RAW/systemd/$f" -O "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      mkdir -p "$SCRIPT_DIR/systemd"
      cp "$tmp" "$SCRIPT_DIR/systemd/$f"
      cp "$tmp" "/etc/systemd/system/$f"
    else
      ok=false
    fi
    rm -f "$tmp"
  done
  systemctl daemon-reload 2>/dev/null
  systemctl restart dropbear-fastkick.service 2>/dev/null
  systemctl restart xray-maxlogin.service 2>/dev/null
  [[ "$ok" == "true" ]]
}

run_update() {
  local remote_v="$1"
  local ok=true
  local f
  for f in "${UPDATE_FILES[@]}"; do
    echo -ne "  Updating $f..."
    if update_fetch_file "$f"; then
      echo -e " ${GREEN}OK${NC}"
    else
      echo -e " ${YELLOW}SKIP${NC}"
      ok=false
    fi
  done

  echo -ne "  Updating addon/install-sshws.sh..."
  if update_fetch_addon_bin; then
    echo -e " ${GREEN}OK${NC}"
  else
    echo -e " ${YELLOW}SKIP${NC}"
  fi

  echo -ne "  Updating addon/haproxy-sshws-ssl.sh..."
  if update_fetch_haproxy_addon; then
    echo -e " ${GREEN}OK${NC}"
  else
    echo -e " ${YELLOW}SKIP${NC}"
  fi

  echo -ne "  Updating addon/enable-ssl-multiplex.sh..."
  if update_fetch_multiplex_addon; then
    echo -e " ${GREEN}OK${NC}"
  else
    echo -e " ${YELLOW}SKIP${NC}"
  fi

  echo -ne "  Updating addon maxlogin (ssh-maxlogin, dropbear-fastkick, xray-maxlogin-daemon)..."
  if update_fetch_maxlogin_addons; then
    echo -e " ${GREEN}OK${NC}"
  else
    echo -e " ${YELLOW}SKIP${NC}"
  fi

  echo -ne "  Memperbarui MaxLogin Xray (batas perangkat via token)..."
  if update_fetch_maxlogin_pkg; then
    if bash "$SCRIPT_DIR/addon/maxlogin/maxlogin-xray.sh" update >/tmp/maxlogin-update.log 2>&1; then
      echo -e " ${GREEN}OK${NC}"
    else
      echo -e " ${YELLOW}SKIP (lihat /tmp/maxlogin-update.log)${NC}"
    fi
    grep -E "belum diaktifkan" /tmp/maxlogin-update.log 2>/dev/null | sed 's/^/    /'
  else
    echo -e " ${YELLOW}SKIP${NC}"
  fi

  bash "$SCRIPT_DIR/addon/ssh-maxlogin.sh" install 2>/dev/null
  # Terapkan ulang batas PAM (limit+1) agar pelanggaran limit device terdeteksi & kena penalti
  while IFS='|' read -r _u _p _e _c _l _q; do
    [[ -z "$_u" ]] && continue
    bash "$SCRIPT_DIR/addon/ssh-maxlogin.sh" set "$_u" "${_l:-$SESSION_LIMIT_DEFAULT}" &>/dev/null
  done < <(list_ssh)

  # Multiplex 443 aktif -> teruskan IP asli ke Nginx/Xray (limit device Xray butuh ini)
  if [[ -f "$SCRIPT_DIR/.multiplex-443-active" && -f "$SCRIPT_DIR/addon/real-ip-fix.sh" ]]; then
    echo -ne "  Meneruskan IP asli pemakai (HAProxy -> Nginx)..."
    if bash "$SCRIPT_DIR/addon/real-ip-fix.sh" >/dev/null 2>&1; then echo -e " ${GREEN}OK${NC}"; else echo -e " ${YELLOW}SKIP${NC}"; fi
  fi

  echo -ne "  Mengaktifkan pencatat pemakaian & kuota (quota-limiter)..."
  if setup_quota_limiter; then echo -e " ${GREEN}OK${NC}"; else echo -e " ${YELLOW}SKIP${NC}"; fi

  ensure_xray_stats_api
  ensure_dropbear_banner
  ensure_ssh_banner

  # Multiplex 443 aktif tapi belum punya jalur OpenVPN-over-SSL (mode SNI tanpa payload):
  # terapkan ulang config multiplex (ada verifikasi + rollback otomatis di dalamnya).
  if [[ -f /etc/vpn-script/.multiplex-443-active && -f /etc/haproxy/haproxy.cfg ]] \
     && ! grep -q "multiplex_ovpn" /etc/haproxy/haproxy.cfg \
     && [[ -x "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh" ]]; then
    echo -ne "  Menambah jalur OpenVPN-SSL ke multiplex 443..."
    if bash "$SCRIPT_DIR/addon/enable-ssl-multiplex.sh" enable >/tmp/mux-update.log 2>&1; then
      echo -e " ${GREEN}OK${NC}"
    else
      echo -e " ${YELLOW}SKIP (lihat /tmp/mux-update.log)${NC}"
    fi
  fi

  # Migrasi repo panel: arahkan /opt/xray-panel & vpn-update ke repo panel yang aktif
  if [[ -d /opt/xray-panel/.git ]]; then
    git -C /opt/xray-panel remote set-url origin "https://github.com/oghc93/cocote-3x-ui.git" 2>/dev/null
  fi
  if command -v vpn-update >/dev/null 2>&1; then
    local _vu; _vu=$(mktemp)
    if wget -q --timeout=30 "https://raw.githubusercontent.com/oghc93/cocote-3x-ui/main/deploy/update.sh" -O "$_vu" && [[ -s "$_vu" ]] && bash -n "$_vu"; then
      install -m 755 "$_vu" /usr/local/bin/vpn-update
    fi
    rm -f "$_vu"
  fi

  # Bot backup/restore: pakai file terbaru kalau sudah aktif
  if systemctl is-active --quiet tg-backup-bot 2>/dev/null; then
    systemctl restart tg-backup-bot >/dev/null 2>&1
  fi

  echo "$remote_v" > "$VERSION_FILE"
  [[ "$ok" == "true" ]]
}

# Make functions available when sourced
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && "$@"
