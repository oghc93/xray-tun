#!/bin/bash
# ============================================================
#   CHANELOG VPN SCRIPT - MONITOR & TOOLS (ADDON)
#
#   Lewat menu  : vpn -> "Monitor & Tools"
#   Langsung    : bash tools.sh online | kick-ssh <user>
#                 bash tools.sh speedtest
#                 bash tools.sh vnstat-install | vnstat-show [s|d|m]
#                 bash tools.sh swap-status | swap-on [MB] | swap-off
#                 bash tools.sh tune-on | tune-off | tune-status
#                 bash tools.sh logrotate | logrotate-status
#                 tambahkan -y di belakang untuk lewati konfirmasi
# ============================================================

SCRIPT_DIR="${VPN_SCRIPT_DIR:-/etc/vpn-script}"
source "$SCRIPT_DIR/lib.sh"

SYSCTL_DIR="${SYSCTL_DIR:-/etc/sysctl.d}"
SWAPFILE="${SWAPFILE:-/swapfile-vpn}"
FSTAB="${FSTAB:-/etc/fstab}"
SWAP_SYSCTL="$SYSCTL_DIR/99-vpn-swap.conf"
TUNE_CONF="$SYSCTL_DIR/99-vpn-tune.conf"
TUNE_PREV="${TUNE_PREV:-$SCRIPT_DIR/.tune-prev}"
LOGROTATE_CONF="${LOGROTATE_CONF:-/etc/logrotate.d/vpn-script}"
JOURNALD_CONF="${JOURNALD_CONF:-/etc/systemd/journald.conf.d/vpn-script.conf}"
SPEED_DOWN_URL="${SPEED_DOWN_URL:-https://speed.cloudflare.com/__down?bytes=25000000}"
SPEED_PING_URL="${SPEED_PING_URL:-https://speed.cloudflare.com/__down?bytes=0}"
SPEED_UP_URL="${SPEED_UP_URL:-https://speed.cloudflare.com/__up}"

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

sysctl_get() { sysctl -n "$1" 2>/dev/null; }
default_iface() { ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1; }

# ═════════════════════════════════════════════════════════
#  1. USER ONLINE & KICK
# ═════════════════════════════════════════════════════════

# Akun SSH yang sedang punya sesi: "user|dropbear|openssh"
ssh_online() {
  local user d o
  while IFS='|' read -r user _; do
    [[ -z "$user" ]] && continue
    d=$(pgrep -u "$user" -x dropbear 2>/dev/null | wc -l)
    o=$(pgrep -u "$user" -x sshd 2>/dev/null | wc -l)
    (( d + o > 0 )) && echo "${user}|${d}|${o}"
  done < <(list_ssh)
}

# Akun Xray yang sedang online: "email|jumlah|sumber|ip1,ip2"
# sumber: stat (Stats API), ip (statsonlineiplist), log (access.log, perkiraan), traffic (hanya aktif/tidak)
xray_online() {
  local json out em n ips probe_user rows
  # 1) Stats API ">>>online" (jumlah IP aktif per user)
  json=$(xray_stat_query ">>>online") || json=""
  if [[ -n "$json" ]]; then
    out=$(echo "$json" | jq -r '.stat[]? | select(.name | startswith("user>>>") and endswith(">>>online"))
      | [(.name | split(">>>")[1]), ((.value // 0) | tonumber)] | join("|")' 2>/dev/null | awk -F'|' '$2 > 0')
    if [[ -n "$out" ]]; then
      while IFS='|' read -r em n; do
        ips=$(get_xray_user_ips "$em" 2>/dev/null | paste -sd, -)
        echo "${em}|${n}|stat|${ips}"
      done <<< "$out"
      return 0
    fi
  fi
  # 2) statsonlineiplist per user, lalu 3) access.log
  probe_user=$({ list_vmess; list_vless; list_trojan; list_ss; } | head -n1 | cut -d'|' -f1)
  if [[ -n "$probe_user" ]] && command -v xray >/dev/null 2>&1 \
     && { timeout 5 xray api statsonlineiplist --server="$XRAY_API_ADDR" -email="$probe_user" 2>/dev/null \
          || timeout 5 xray api statsonlineiplist --server="$XRAY_API_ADDR" "$probe_user" 2>/dev/null; } | jq -e '.name' >/dev/null 2>&1; then
    rows=$(while IFS='|' read -r em _; do
      [[ -z "$em" ]] && continue
      ips=$(get_xray_user_ips "$em" 2>/dev/null)
      n=$(echo "$ips" | grep -c .)
      (( n > 0 )) && echo "${em}|${n}|ip|$(echo "$ips" | paste -sd, -)"
    done < <({ list_vmess; list_vless; list_trojan; list_ss; } | cut -d'|' -f1 | sort -u))
    if [[ -n "$rows" ]]; then echo "$rows"; return 0; fi
  fi
  rows=$(xray_log_ips | cut -d'|' -f1 | sort -u | while read -r em; do
    [[ -z "$em" ]] && continue
    xray_user_active "$em" || continue
    ips=$(xray_log_ips "$em" | xray_group_ips)
    n=$(echo "$ips" | grep -c .)
    (( n > 0 )) && echo "${em}|${n}|log|$(echo "$ips" | paste -sd, -)"
  done)
  if [[ -n "$rows" ]]; then echo "$rows"; return 0; fi
  # Terakhir: akun aktif lewat gerakan trafik; kalau IP-nya diketahui dari log, tampilkan juga
  xray_active_by_traffic | while IFS='|' read -r em n _; do
    ips=$(get_xray_user_ips "$em" 2>/dev/null)
    if [[ -n "$ips" ]]; then echo "${em}|$(echo "$ips" | grep -c .)|log|$(echo "$ips" | paste -sd, -)"
    else echo "${em}|1|traffic|"; fi
  done
}

# Cadangan: statistik "online" bawaan Xray sering kosong (mis. di belakang nginx/CDN).
# Akun dianggap aktif kalau trafiknya bergerak dalam 60 detik terakhir.
# Output: "email|1|traffic". Tidak bisa menghitung jumlah device.
xray_active_by_traffic() {
  local dir="/run/vpn-script" snap cur new now json
  snap="$dir/xray-traffic.snap"
  mkdir -p "$dir" 2>/dev/null || return 0
  json=$(xray_stat_query "user>>>") || return 0
  [[ -z "$json" ]] && return 0
  now=$(date +%s)
  cur=$(mktemp) ; new=$(mktemp)
  echo "$json" | jq -r '.stat[]? | select(.name | test("^user>>>.+>>>traffic>>>(uplink|downlink)$"))
    | [(.name | split(">>>")[1]), ((.value // 0) | tonumber)] | join("|")' 2>/dev/null \
    | awk -F'|' '{t[$1]+=$2} END{for(u in t) print u"|"t[u]}' > "$cur"
  [[ -f "$snap" ]] || : > "$snap"
  awk -F'|' -v now="$now" -v snapf="$snap" 'FILENAME==snapf{pt[$1]=$2; pl[$1]=$3; next}
    {u=$1; t=$2; lc=0
     if (u in pt) { if (t!=pt[u]) lc=now; else lc=pl[u] }
     print u"|"t"|"lc}' "$snap" "$cur" > "$new"
  cat "$new" > "$snap"
  awk -F'|' -v now="$now" '$3>0 && (now-$3)<=60 {print $1"|1|traffic"}' "$new"
  rm -f "$cur" "$new"
}

# Versi mesin-baca untuk panel web: bash tools.sh online-json
online_json() {
  local ssh_j xr_j ov_j user d o n pr real virt
  local ssh_list lim; ssh_list=$(list_ssh)
  ssh_j=$(ssh_online | while IFS='|' read -r user d o; do
            lim=$(echo "$ssh_list" | awk -F'|' -v u="$user" '$1==u {print $5; exit}')
            [[ "$lim" =~ ^[0-9]+$ ]] || lim="${SESSION_LIMIT_DEFAULT:-2}"
            jq -cn --arg u "$user" --argjson d "${d:-0}" --argjson o "${o:-0}" --argjson l "$lim" \
              '{user:$u,dropbear:$d,openssh:$o,devices:($d+$o),limit:$l}'
          done | jq -s '.')
  declare -A PROTO
  while IFS='|' read -r user _; do [[ -n "$user" ]] && PROTO[$user]="${PROTO[$user]:+${PROTO[$user]}/}vmess";  done < <(list_vmess)
  while IFS='|' read -r user _; do [[ -n "$user" ]] && PROTO[$user]="${PROTO[$user]:+${PROTO[$user]}/}vless";  done < <(list_vless)
  while IFS='|' read -r user _; do [[ -n "$user" ]] && PROTO[$user]="${PROTO[$user]:+${PROTO[$user]}/}trojan"; done < <(list_trojan)
  while IFS='|' read -r user _; do [[ -n "$user" ]] && PROTO[$user]="${PROTO[$user]:+${PROTO[$user]}/}ss";     done < <(list_ss)
  xr_j=$(xray_online | while IFS='|' read -r user n src ips; do
           jq -cn --arg u "$user" --arg p "${PROTO[$user]:-?}" --argjson n "${n:-0}" --arg s "${src:-stat}" --arg ips "${ips:-}" \
             '{user:$u,proto:$p,devices:$n,source:$s,ips:($ips|split(",")|map(select(length>0)))}'
         done | jq -s '.')
  ov_j='[]'
  if [[ -f "$SCRIPT_DIR/menu/openvpn.sh" ]]; then
    ov_j=$(bash "$SCRIPT_DIR/menu/openvpn.sh" online 2>/dev/null | while IFS='|' read -r pr user real virt _; do
             [[ -z "$user" ]] && continue
             jq -cn --arg p "$pr" --arg u "$user" --arg r "${real%:*}" --arg v "$virt" '{proto:$p,user:$u,ip:$r,vpn_ip:$v}'
           done | jq -s '.')
  fi
  jq -n --argjson ssh "${ssh_j:-[]}" --argjson xray "${xr_j:-[]}" --argjson ovpn "${ov_j:-[]}" \
    '{ok:true, ssh:$ssh, xray:$xray, openvpn:$ovpn,
      total:(([$ssh[]|(.dropbear+.openssh)]|add//0) + ([$xray[]|.devices]|add//0) + ($ovpn|length))}'
}

show_online() {
  local line user d o n total=0 label
  echo -e "  ${WHITE}${BOLD}SSH (Dropbear / OpenSSH)${NC}"
  printf "  ${DIM}%-20s %-10s %-10s %s${NC}\n" "USER" "DROPBEAR" "OPENSSH" "LIMIT"
  local ssh_rows; ssh_rows=$(ssh_online)
  if [[ -z "$ssh_rows" ]]; then
    echo -e "  ${DIM}(tidak ada sesi SSH aktif)${NC}"
  else
    while IFS='|' read -r user d o; do
      local limit
      limit=$(list_ssh | awk -F'|' -v u="$user" '$1==u {print $5}')
      limit="${limit:-${SESSION_LIMIT_DEFAULT:-2}}"
      printf "  %-20s %-10s %-10s %s\n" "$user" "$d" "$o" "$limit"
      total=$(( total + d + o ))
    done <<< "$ssh_rows"
  fi

  echo ""
  echo -e "  ${WHITE}${BOLD}Xray (VMess / VLess / Trojan / SS)${NC}"
  printf "  ${DIM}%-20s %-12s %s${NC}\n" "USER" "PROTOKOL" "DEVICE ONLINE"
  declare -A PROTO
  while IFS='|' read -r user _; do [[ -n "$user" ]] && PROTO[$user]="${PROTO[$user]:+${PROTO[$user]}/}VMess";  done < <(list_vmess)
  while IFS='|' read -r user _; do [[ -n "$user" ]] && PROTO[$user]="${PROTO[$user]:+${PROTO[$user]}/}VLess";  done < <(list_vless)
  while IFS='|' read -r user _; do [[ -n "$user" ]] && PROTO[$user]="${PROTO[$user]:+${PROTO[$user]}/}Trojan"; done < <(list_trojan)
  while IFS='|' read -r user _; do [[ -n "$user" ]] && PROTO[$user]="${PROTO[$user]:+${PROTO[$user]}/}SS";     done < <(list_ss)
  local xr_rows; xr_rows=$(xray_online)
  if [[ -z "$xr_rows" ]]; then
    echo -e "  ${DIM}(tidak ada akun Xray online, atau Stats API belum aktif)${NC}"
  else
    while IFS='|' read -r user n src ips; do
      if [[ "$src" == "traffic" ]]; then label="aktif (trafik bergerak)"
      else label="$n device${ips:+  ($ips)}"; [[ "$src" == "log" ]] && label+="  ~perkiraan"; fi
      printf "  %-20s %-12s %s\n" "$user" "${PROTO[$user]:-?}" "$label"
      total=$(( total + n ))
    done <<< "$xr_rows"
  fi

  local OVPN="$SCRIPT_DIR/menu/openvpn.sh"
  if [[ -f "$OVPN" ]] && { systemctl is-active --quiet openvpn-server@vpn-script-tcp 2>/dev/null || systemctl is-active --quiet openvpn-server@vpn-script-udp 2>/dev/null; }; then
    echo ""
    echo -e "  ${WHITE}${BOLD}OpenVPN (TCP / UDP)${NC}"
    printf "  ${DIM}%-20s %-6s %s${NC}\n" "USER" "PROTO" "IP CLIENT"
    local ov_rows; ov_rows=$(bash "$OVPN" online 2>/dev/null)
    if [[ -z "$ov_rows" ]]; then
      echo -e "  ${DIM}(tidak ada user OpenVPN online)${NC}"
    else
      local pr real
      while IFS='|' read -r pr user real _; do
        [[ -z "$user" ]] && continue
        printf "  %-20s %-6s %s\n" "$user" "$pr" "${real%:*}"
        total=$(( total + 1 ))
      done <<< "$ov_rows"
    fi
  fi
  echo ""
  echo -e "  ${CYAN}$LINE${NC}"
  echo -e "  Total sesi/device online: ${WHITE}${BOLD}${total}${NC}"
}

kick_ssh() {
  local user="$1" d o
  [[ -n "$user" ]] || { echo -e "  ${RED}[GAGAL]${NC} Username kosong."; return 1; }
  # Pengaman: hanya akun yang terdaftar di database script (jangan pernah root/akun sistem).
  if ! list_ssh | cut -d'|' -f1 | grep -qxF "$user"; then
    echo -e "  ${RED}[GAGAL]${NC} '$user' bukan akun SSH terdaftar di script ini."
    return 1
  fi
  d=$(pgrep -u "$user" -x dropbear 2>/dev/null | wc -l)
  o=$(pgrep -u "$user" -x sshd 2>/dev/null | wc -l)
  if (( d + o == 0 )); then
    if [[ -f "$SCRIPT_DIR/menu/openvpn.sh" ]] && bash "$SCRIPT_DIR/menu/openvpn.sh" kick "$user" >/dev/null 2>&1; then
      echo -e "  ${GREEN}[OK]${NC} Sesi OpenVPN $user diputus (client bisa auto-reconnect)."
      return 0
    fi
    echo -e "  ${YELLOW}[i]${NC} $user tidak punya sesi aktif."
    return 0
  fi
  confirm "Putuskan $d sesi Dropbear + $o sesi OpenSSH milik $user?" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }
  pkill -9 -u "$user" -x dropbear 2>/dev/null
  pkill -9 -u "$user" -x sshd 2>/dev/null
  echo -e "  ${GREEN}[OK]${NC} Sesi $user diputus (user perlu reconnect)."
  echo -e "  ${DIM}Supaya tidak bisa konek lagi, hapus/ubah akunnya di menu SSH.${NC}"
}

kick_all_xray() {
  echo -e "  ${YELLOW}Perhatian:${NC} Xray tidak punya cara memutus SATU user tanpa restart."
  echo -e "  Ini memutus SEMUA koneksi Xray sebentar (client tersambung ulang otomatis)."
  confirm "Restart Xray sekarang?" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }
  systemctl restart xray 2>/dev/null; sleep 1
  systemctl is-active --quiet xray && echo -e "  ${GREEN}[OK]${NC} Xray di-restart." || echo -e "  ${RED}[GAGAL]${NC} Xray tidak jalan, cek: journalctl -u xray -n 20"
}

online_menu() {
  clear
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}USER ONLINE${NC}"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  show_online
  echo ""
  echo -e "  ${YELLOW}[1]${NC} Putuskan user       ${YELLOW}[2]${NC} Restart Xray (putus semua)"
  echo -e "  ${YELLOW}[r]${NC} Refresh             ${YELLOW}[0]${NC} Kembali"
  echo -ne "  ${WHITE}${BOLD}Pilih${NC} ${DIM}›${NC} "
  read -r c
  case "$c" in
    1) echo -ne "  ${WHITE}Username SSH${NC}: "; read -r u; echo ""; kick_ssh "$u"; pause ;;
    2) echo ""; kick_all_xray; pause ;;
    0) return ;;
  esac
  online_menu
}

# ═════════════════════════════════════════════════════════
#  2. SPEEDTEST (tanpa instal apa pun, lewat Cloudflare)
# ═════════════════════════════════════════════════════════
mbps() { awk -v b="$1" 'BEGIN { printf "%.1f", b * 8 / 1000000 }'; }

# ── Speedtest by Ookla (CLI resmi); kalau gagal dipasang, pakai uji Cloudflare di bawah ──
OOKLA_VER="${OOKLA_VER:-1.2.0}"
OOKLA_BIN="${OOKLA_BIN:-/usr/local/bin/speedtest}"

ookla_ok() { [[ -x "$OOKLA_BIN" ]] && "$OOKLA_BIN" --version 2>/dev/null | grep -qi ookla; }

ookla_install() {
  ookla_ok && return 0
  local arch tmp
  case "$(uname -m)" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l|armhf)  arch="armhf" ;;
    i386|i686)     arch="i386" ;;
    *) return 1 ;;
  esac
  echo -e "  ${CYAN}[*]${NC} Memasang Speedtest by Ookla (sekali saja)..."
  tmp=$(mktemp -d)
  if curl -fsSL --max-time 90 "https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_VER}-linux-${arch}.tgz" -o "$tmp/st.tgz" 2>/dev/null \
     && tar -xzf "$tmp/st.tgz" -C "$tmp" speedtest 2>/dev/null && [[ -s "$tmp/speedtest" ]]; then
    install -m 755 "$tmp/speedtest" "$OOKLA_BIN"
  fi
  rm -rf "$tmp"
  ookla_ok && return 0
  # Cadangan: repo apt resmi Ookla (packagecloud)
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL --max-time 60 https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh 2>/dev/null | bash >/dev/null 2>&1
    apt_install speedtest
    local b; b=$(command -v speedtest 2>/dev/null)
    [[ -n "$b" && "$b" != "$OOKLA_BIN" ]] && OOKLA_BIN="$b"
  fi
  ookla_ok
}

ookla_run() {
  echo -e "  ${CYAN}[*]${NC} Speedtest by Ookla (server terdekat, hasil tampil langsung)..."
  echo ""
  timeout --foreground 180 "$OOKLA_BIN" --accept-license --accept-gdpr
}

speedtest_run() {
  command -v curl >/dev/null 2>&1 || { echo -e "  ${RED}[GAGAL]${NC} curl belum terpasang."; return 1; }
  if ookla_install && ookla_run; then return 0; fi
  echo -e "  ${YELLOW}[i]${NC} Speedtest Ookla tidak bisa dipakai, beralih ke uji Cloudflare."
  echo ""
  echo -e "  ${CYAN}[*]${NC} Uji kecepatan VPS ke Cloudflare (server terdekat)..."
  echo ""

  local i t sum=0 n=0 ping_ms="gagal"
  for i in 1 2 3; do
    t=$(curl -s -o /dev/null --max-time 8 -w '%{time_connect}' "$SPEED_PING_URL" 2>/dev/null)
    if [[ -n "$t" ]] && awk -v t="$t" 'BEGIN{exit !(t>0)}'; then sum=$(awk -v s="$sum" -v t="$t" 'BEGIN{print s+t}'); n=$((n+1)); fi
  done
  (( n > 0 )) && ping_ms=$(awk -v s="$sum" -v n="$n" 'BEGIN { printf "%.0f ms", s / n * 1000 }')
  echo -e "  Latensi   : ${WHITE}${ping_ms}${NC}"

  local dl
  dl=$(curl -s -o /dev/null --max-time 40 -w '%{speed_download}' "$SPEED_DOWN_URL" 2>/dev/null)
  if [[ -n "$dl" ]] && awk -v d="$dl" 'BEGIN{exit !(d>0)}'; then
    echo -e "  Download  : ${GREEN}${BOLD}$(mbps "$dl") Mbps${NC}"
  else
    echo -e "  Download  : ${RED}gagal${NC}"
  fi

  local ul
  ul=$(head -c 10000000 /dev/zero | curl -s -o /dev/null --max-time 40 -X POST -H 'Content-Type: application/octet-stream' \
        --data-binary @- -w '%{speed_upload}' "$SPEED_UP_URL" 2>/dev/null)
  if [[ -n "$ul" ]] && awk -v d="$ul" 'BEGIN{exit !(d>0)}'; then
    echo -e "  Upload    : ${GREEN}${BOLD}$(mbps "$ul") Mbps${NC}"
  else
    echo -e "  Upload    : ${RED}gagal${NC}"
  fi
  echo ""
  echo -e "  ${DIM}Ini kecepatan VPS ke internet (bukan ke HP Anda). Hasil bisa bervariasi${NC}"
  echo -e "  ${DIM}tiap uji; ulangi beberapa kali untuk gambaran yang akurat.${NC}"
}

# ═════════════════════════════════════════════════════════
#  3. TRAFFIC BULANAN (vnstat)
# ═════════════════════════════════════════════════════════
vnstat_install() {
  echo -e "  ${CYAN}[*]${NC} Memasang vnstat..."
  if ! command -v vnstat >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt_install vnstat || { echo -e "  ${RED}[GAGAL]${NC} apt gagal memasang vnstat."; return 1; }
  fi
  local iface; iface=$(default_iface)
  [[ -z "$iface" ]] && { echo -e "  ${RED}[GAGAL]${NC} Interface jaringan utama tidak terdeteksi."; return 1; }
  systemctl enable vnstat >/dev/null 2>&1
  systemctl restart vnstat 2>/dev/null
  # vnstat 2.x: --add, vnstat 1.x: -u -i
  vnstat -i "$iface" >/dev/null 2>&1 || vnstat --add -i "$iface" >/dev/null 2>&1 || vnstat -u -i "$iface" >/dev/null 2>&1
  systemctl restart vnstat 2>/dev/null
  echo -e "  ${GREEN}[OK]${NC} vnstat aktif untuk interface ${WHITE}$iface${NC}."
  echo -e "  ${DIM}Data mulai dihitung dari sekarang; angka bulanan terisi seiring waktu.${NC}"
}

vnstat_month_line() {
  local iface="$1" o
  vnstat --version 2>/dev/null | grep -q 'vnStat 2' || return 0
  o=$(vnstat -i "$iface" --oneline 2>/dev/null)
  [[ "$o" == 1\;* ]] || return 0
  IFS=';' read -ra f <<< "$o"
  echo -e "  Bulan ini (${f[7]:-?}) : download ${WHITE}${f[8]:-?}${NC} · upload ${WHITE}${f[9]:-?}${NC} · total ${GREEN}${BOLD}${f[10]:-?}${NC}"
}

vnstat_show() {
  command -v vnstat >/dev/null 2>&1 || { echo -e "  ${YELLOW}[i]${NC} vnstat belum terpasang. Pasang dulu (menu Traffic Bulanan -> Pasang)."; return 1; }
  local iface; iface=$(default_iface)
  case "${1:-s}" in
    d) vnstat -d -i "$iface" ;;
    m) vnstat -m -i "$iface" ;;
    l) echo -e "  ${DIM}Tekan Ctrl+C untuk berhenti.${NC}"; vnstat -l -i "$iface" ;;
    *) vnstat_month_line "$iface"; echo ""; vnstat -i "$iface" ;;
  esac
}

vnstat_menu() {
  clear
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}TRAFFIC BULANAN (vnstat)${NC}"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  if command -v vnstat >/dev/null 2>&1; then ui_kv "vnstat" "${GREEN}terpasang${NC}"; else ui_kv "vnstat" "${DIM}belum terpasang${NC}"; fi
  ui_kv "Interface" "$(default_iface)"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_2col "$(ui_menu_num 01 'Pasang / Aktifkan' "$GREEN")" "$(ui_menu_num 02 'Ringkasan')"
  ui_2col "$(ui_menu_num 03 'Harian')"                      "$(ui_menu_num 04 'Bulanan')"
  ui_2col "$(ui_menu_num 05 'Live (Ctrl+C stop)')"          ""
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_line "$(ui_menu_num 00 'Kembali' "$DIM")"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  echo -ne "  ${WHITE}${BOLD}Pilih [0-5]${NC} ${DIM}›${NC} "
  read -r c
  case "$c" in
    1) echo ""; vnstat_install; pause ;;
    2) echo ""; vnstat_show s; pause ;;
    3) echo ""; vnstat_show d; pause ;;
    4) echo ""; vnstat_show m; pause ;;
    5) echo ""; vnstat_show l; pause ;;
    0) return ;;
  esac
  vnstat_menu
}

# ═════════════════════════════════════════════════════════
#  4. SWAP
# ═════════════════════════════════════════════════════════
swap_status() {
  echo -e "  ${WHITE}${BOLD}Memori${NC}"
  free -h | sed 's/^/  /'
  echo ""
  if [[ -n "$(swapon --noheadings --show 2>/dev/null)" ]]; then
    swapon --show 2>/dev/null | sed 's/^/  /'
  else
    echo -e "  ${DIM}Tidak ada swap aktif.${NC}"
  fi
  [[ -f "$SWAPFILE" ]] && echo -e "  ${DIM}Swap buatan menu ini: $SWAPFILE${NC}"
}

swap_make_file() {  # swap_make_file <MB> <metode: fallocate|dd>
  rm -f "$SWAPFILE"
  if [[ "$2" == "fallocate" ]] && command -v fallocate >/dev/null 2>&1 && fallocate -l "${1}M" "$SWAPFILE" 2>/dev/null; then :
  else dd if=/dev/zero of="$SWAPFILE" bs=1M count="$1" status=none 2>/dev/null || return 1; fi
  chmod 600 "$SWAPFILE"
  mkswap -q "$SWAPFILE" >/dev/null 2>&1
}

swap_create() {
  local mb="${1:-1024}"
  [[ "$mb" =~ ^[0-9]+$ ]] && (( mb >= 128 && mb <= 32768 )) || { echo -e "  ${RED}[GAGAL]${NC} Ukuran harus angka 128-32768 (MB)."; return 1; }

  if [[ -f "$SWAPFILE" ]]; then
    echo -e "  ${YELLOW}[i]${NC} Swap buatan menu ini sudah ada ($SWAPFILE). Hapus dulu kalau mau ganti ukuran."
    return 1
  fi
  case "$(systemd-detect-virt -c 2>/dev/null)" in
    openvz|lxc|lxc-libvirt) echo -e "  ${RED}[GAGAL]${NC} VPS container (OpenVZ/LXC) umumnya tidak mengizinkan swap buatan sendiri."; return 1 ;;
  esac
  if [[ -n "$(swapon --noheadings --show 2>/dev/null)" ]]; then
    echo -e "  ${YELLOW}[!]${NC} Sudah ada swap aktif:"; swapon --show 2>/dev/null | sed 's/^/      /'
    confirm "Tetap tambah swap ${mb}MB?" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }
  fi

  local free_mb; free_mb=$(df -Pm "$(dirname "$SWAPFILE")" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ "$free_mb" =~ ^[0-9]+$ ]] && (( free_mb < mb + 512 )); then
    echo -e "  ${RED}[GAGAL]${NC} Disk kosong ${free_mb}MB, kurang untuk swap ${mb}MB (butuh sisa minimal 512MB)."
    return 1
  fi

  echo -e "  ${CYAN}[*]${NC} Membuat swap ${mb}MB..."
  swap_make_file "$mb" fallocate || { rm -f "$SWAPFILE"; echo -e "  ${RED}[GAGAL]${NC} Gagal membuat file swap."; return 1; }
  if ! swapon "$SWAPFILE" 2>/dev/null; then
    # beberapa filesystem menolak file hasil fallocate -> ulangi dengan dd
    swap_make_file "$mb" dd
    swapon "$SWAPFILE" 2>/dev/null || { rm -f "$SWAPFILE"; echo -e "  ${RED}[GAGAL]${NC} Kernel menolak swapon."; return 1; }
  fi

  grep -qE "^$SWAPFILE[[:space:]]" "$FSTAB" 2>/dev/null || echo "$SWAPFILE none swap sw 0 0" >> "$FSTAB"
  mkdir -p "$SYSCTL_DIR"
  printf '# Dibuat oleh menu Monitor & Tools (CHANELOG VPN SCRIPT)\nvm.swappiness=10\n' > "$SWAP_SYSCTL"
  sysctl -w vm.swappiness=10 >/dev/null 2>&1
  echo -e "  ${GREEN}[OK]${NC} Swap ${mb}MB aktif & permanen (swappiness 10: swap dipakai hanya saat RAM mepet)."
}

swap_remove() {
  if [[ ! -f "$SWAPFILE" ]]; then
    echo -e "  ${YELLOW}[i]${NC} Tidak ada swap buatan menu ini ($SWAPFILE). Swap lain tidak disentuh."
    return 0
  fi
  confirm "Hapus swap $SWAPFILE?" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }
  swapoff "$SWAPFILE" 2>/dev/null
  sed -i "\|^$SWAPFILE[[:space:]]|d" "$FSTAB" 2>/dev/null
  rm -f "$SWAPFILE" "$SWAP_SYSCTL"
  echo -e "  ${GREEN}[OK]${NC} Swap dihapus."
}

swap_menu() {
  clear
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}SWAP${NC}"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  swap_status
  echo ""
  echo -e "  ${YELLOW}[1]${NC} Buat 512MB  ${YELLOW}[2]${NC} Buat 1GB  ${YELLOW}[3]${NC} Buat 2GB  ${YELLOW}[4]${NC} Ukuran lain"
  echo -e "  ${YELLOW}[5]${NC} Hapus swap  ${YELLOW}[0]${NC} Kembali"
  echo -ne "  ${WHITE}${BOLD}Pilih${NC} ${DIM}›${NC} "
  read -r c
  case "$c" in
    1) echo ""; swap_create 512;  pause ;;
    2) echo ""; swap_create 1024; pause ;;
    3) echo ""; swap_create 2048; pause ;;
    4) echo -ne "  ${WHITE}Ukuran (MB)${NC}: "; read -r mb; echo ""; swap_create "$mb"; pause ;;
    5) echo ""; swap_remove; pause ;;
    0) return ;;
  esac
  swap_menu
}

# ═════════════════════════════════════════════════════════
#  5. TUNING KERNEL (aman, bisa ON/OFF)
# ═════════════════════════════════════════════════════════
# "kunci|nilai|mode"  mode: raise = hanya dinaikkan (jangan turunkan nilai yang sudah lebih besar), set = paksa
TUNE_LIST=(
  "fs.file-max|1000000|raise"
  "net.core.somaxconn|4096|raise"
  "net.core.netdev_max_backlog|16384|raise"
  "net.ipv4.tcp_max_syn_backlog|8192|raise"
  "net.ipv4.tcp_fastopen|3|set"
  "net.ipv4.tcp_slow_start_after_idle|0|set"
  "net.ipv4.tcp_tw_reuse|1|set"
  "net.ipv4.ip_local_port_range|10240 65535|set"
  "net.ipv4.tcp_keepalive_time|300|set"
  "net.ipv4.tcp_keepalive_intvl|30|set"
  "net.ipv4.tcp_keepalive_probes|5|set"
)

norm() { tr -s '[:space:]' ' ' <<< "$1" | sed 's/^ //; s/ $//'; }
tune_is_on() { [[ -f "$TUNE_CONF" ]]; }

tune_on() {
  if tune_is_on; then echo -e "  ${YELLOW}[i]${NC} Tuning sudah aktif. Matikan dulu (OFF) kalau mau menerapkan ulang."; return 0; fi
  local item key val mode cur applied=0 total=0
  mkdir -p "$SYSCTL_DIR"
  : > "$TUNE_PREV"
  { echo "# Dibuat oleh menu Monitor & Tools (CHANELOG VPN SCRIPT). Matikan lewat menu Tuning OFF."; } > "$TUNE_CONF"

  for item in "${TUNE_LIST[@]}"; do
    IFS='|' read -r key val mode <<< "$item"
    [[ -e "/proc/sys/${key//.//}" ]] || continue            # kernel/container tidak punya kunci ini
    cur=$(norm "$(sysctl_get "$key")")
    if [[ "$mode" == "raise" && "$cur" =~ ^[0-9]+$ ]] && (( cur >= val )); then continue; fi
    echo "${key}=${cur}" >> "$TUNE_PREV"
    echo "${key} = ${val}" >> "$TUNE_CONF"
    total=$((total+1))
    sysctl -w "${key}=${val}" >/dev/null 2>&1
    [[ "$(norm "$(sysctl_get "$key")")" == "$(norm "$val")" ]] && applied=$((applied+1))
  done

  if (( total == 0 )); then
    rm -f "$TUNE_CONF" "$TUNE_PREV"
    echo -e "  ${YELLOW}[i]${NC} Tidak ada yang perlu diubah (nilai sudah memadai / kernel tidak mengizinkan)."
    return 0
  fi
  echo -e "  ${GREEN}[OK]${NC} Tuning aktif: ${applied}/${total} parameter berhasil diterapkan (permanen setelah reboot)."
  (( applied < total )) && echo -e "  ${DIM}Sisanya ditolak kernel/container, tidak berbahaya.${NC}"
  echo -e "  ${DIM}Termasuk keepalive TCP lebih cepat: sesi 'hantu' (client sudah putus) lebih cepat${NC}"
  echo -e "  ${DIM}terbuang, jadi tidak ikut menghabiskan jatah maxlogin.${NC}"
}

tune_off() {
  if ! tune_is_on; then echo -e "  ${YELLOW}[i]${NC} Tuning memang sedang nonaktif."; return 0; fi
  local line key val n=0
  if [[ -f "$TUNE_PREV" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      key="${line%%=*}"; val="${line#*=}"
      sysctl -w "${key}=${val}" >/dev/null 2>&1 && n=$((n+1))
    done < "$TUNE_PREV"
  fi
  rm -f "$TUNE_CONF" "$TUNE_PREV"
  echo -e "  ${GREEN}[OK]${NC} Tuning dimatikan, ${n} parameter dikembalikan ke nilai sebelumnya."
}

tune_status() {
  if tune_is_on; then echo -e "  Tuning kernel : ${GREEN}AKTIF${NC}"; else echo -e "  Tuning kernel : ${RED}NONAKTIF${NC}"; fi
  local item key val mode
  for item in "${TUNE_LIST[@]}"; do
    IFS='|' read -r key val mode <<< "$item"
    [[ -e "/proc/sys/${key//.//}" ]] || continue
    printf "    %-38s %s\n" "$key" "$(norm "$(sysctl_get "$key")")"
  done
}

# ═════════════════════════════════════════════════════════
#  6. ROTASI LOG
# ═════════════════════════════════════════════════════════
logrotate_apply() {
  echo -e "  ${CYAN}[*]${NC} Memasang rotasi log..."
  if ! command -v logrotate >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt_install logrotate || { echo -e "  ${RED}[GAGAL]${NC} apt gagal memasang logrotate."; return 1; }
  fi
  mkdir -p "$(dirname "$LOGROTATE_CONF")"
  cat > "$LOGROTATE_CONF" <<'EOF'
# Dibuat oleh CHANELOG VPN SCRIPT: log daemon limiter & Xray dirotasi supaya disk tidak penuh.
/var/log/vpn-*.log /var/log/xray/*.log {
    su root root
    weekly
    rotate 4
    maxsize 20M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
  if ! logrotate -d "$LOGROTATE_CONF" >/dev/null 2>&1; then
    rm -f "$LOGROTATE_CONF"
    echo -e "  ${RED}[GAGAL]${NC} Konfigurasi logrotate tidak valid, dibatalkan."
    return 1
  fi
  echo -e "  ${GREEN}[OK]${NC} Log /var/log/vpn-*.log & /var/log/xray/*.log dirotasi mingguan / saat > 20MB (simpan 4)."

  mkdir -p "$(dirname "$JOURNALD_CONF")" 2>/dev/null
  if printf '# Dibuat oleh CHANELOG VPN SCRIPT\n[Journal]\nSystemMaxUse=200M\n' > "$JOURNALD_CONF" 2>/dev/null; then
    systemctl restart systemd-journald 2>/dev/null
    echo -e "  ${GREEN}[OK]${NC} Journal systemd dibatasi maksimal 200MB."
  fi
}

logrotate_status() {
  if [[ -f "$LOGROTATE_CONF" ]]; then echo -e "  Rotasi log : ${GREEN}terpasang${NC} ($LOGROTATE_CONF)"; else echo -e "  Rotasi log : ${RED}belum terpasang${NC}"; fi
  [[ -f "$JOURNALD_CONF" ]] && echo -e "  Batas journal : ${GREEN}200MB${NC}" || echo -e "  Batas journal : ${DIM}bawaan sistem${NC}"
  echo ""
  echo -e "  ${WHITE}Ukuran log saat ini${NC}"
  local f found=0
  for f in /var/log/vpn-*.log /var/log/xray/*.log; do
    [[ -f "$f" ]] || continue
    found=1; printf "    %-40s %s\n" "$f" "$(du -h "$f" | cut -f1)"
  done
  (( found )) || echo -e "    ${DIM}(belum ada file log)${NC}"
  command -v journalctl >/dev/null 2>&1 && echo -e "\n  Journal: $(journalctl --disk-usage 2>/dev/null | sed 's/Archived and active journals take up //; s/ in the file system.//')"
}

# ═════════════════════════════════════════════════════════
#  MENU UTAMA TOOLS
# ═════════════════════════════════════════════════════════
run_action() { echo ""; "$@"; pause; }

tools_menu() {
  local tune_b="${DIM}nonaktif${NC}" swap_b="${DIM}tidak ada${NC}" lr_b="${DIM}belum${NC}" vn_b="${DIM}belum${NC}"
  tune_is_on && tune_b="${GREEN}aktif${NC}"
  [[ -n "$(swapon --noheadings --show 2>/dev/null)" ]] && swap_b="${GREEN}aktif${NC}"
  [[ -f "$LOGROTATE_CONF" ]] && lr_b="${GREEN}terpasang${NC}"
  command -v vnstat >/dev/null 2>&1 && vn_b="${GREEN}terpasang${NC}"

  clear
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}MONITOR & TOOLS${NC}"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_2col "$(ui_kv_short 'Swap' "$swap_b")"  "$(ui_kv_short 'Tuning' "$tune_b")"
  ui_2col "$(ui_kv_short 'vnstat' "$vn_b")"  "$(ui_kv_short 'Rotasi log' "$lr_b")"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_2col "$(ui_menu_num 01 'User Online & Kick')"  "$(ui_menu_num 02 'Speedtest (Ookla)')"
  ui_2col "$(ui_menu_num 03 'Traffic Bulanan')"     "$(ui_menu_num 04 'Swap')"
  ui_2col "$(ui_menu_num 05 'Tuning Kernel ON')"    "$(ui_menu_num 06 'Tuning Kernel OFF')"
  ui_2col "$(ui_menu_num 07 'Pasang Rotasi Log')"   "$(ui_menu_num 08 'Status Log & Tuning')"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_line "$(ui_menu_num 00 'Kembali ke Menu Utama' "$DIM")"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  echo -ne "  ${WHITE}${BOLD}Pilih menu [0-8]${NC} ${DIM}›${NC} "
  read -r choice

  case "$choice" in
    1) online_menu ;;
    2) run_action speedtest_run ;;
    3) vnstat_menu ;;
    4) swap_menu ;;
    5) run_action tune_on ;;
    6) run_action tune_off ;;
    7) run_action logrotate_apply ;;
    8) echo ""; tune_status; echo ""; logrotate_status; pause ;;
    0) bash "$SCRIPT_DIR/menu.sh"; return ;;
    *) echo -e "  ${RED}[!] Pilihan tidak valid${NC}"; sleep 1 ;;
  esac
  tools_menu
}

ui_kv_short() { echo -e "${YELLOW}$1${NC}: $2"; }

# ─── Entry point ───────────────────────────────────────────
if [[ -n "$1" ]]; then
  CLI=1
  for a in "$@"; do [[ "$a" == "-y" ]] && ASSUME_YES=1; done
  case "$1" in
    online)           show_online ;;
    online-json)      online_json ;;
    kick-ssh)         kick_ssh "$2" ;;
    speedtest)        speedtest_run ;;
    vnstat-install)   vnstat_install ;;
    vnstat-show)      vnstat_show "$2" ;;
    swap-status)      swap_status ;;
    swap-on)          swap_create "${2:-1024}" ;;
    swap-off)         swap_remove ;;
    tune-on)          tune_on ;;
    tune-off)         tune_off ;;
    tune-status)      tune_status ;;
    logrotate)        logrotate_apply ;;
    logrotate-status) logrotate_status ;;
    *) echo "Pemakaian: bash $0 [online|online-json|kick-ssh USER|speedtest|vnstat-install|vnstat-show [s|d|m]|swap-status|swap-on [MB]|swap-off|tune-on|tune-off|tune-status|logrotate|logrotate-status] [-y]"; exit 1 ;;
  esac
  exit $?
fi

tools_menu
