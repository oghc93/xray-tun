#!/bin/bash
# ============================================================
#   CHANELOG VPN SCRIPT - KEAMANAN (ADDON)
#   Fail2ban (anti brute-force SSH) + Blokir Torrent
#
#   Lewat menu  : vpn -> "Keamanan"
#   Langsung    : bash security.sh f2b-install | f2b-status | f2b-off
#                 bash security.sh f2b-unban <ip>
#                 bash security.sh f2b-wl-add <ip> | f2b-wl-del <ip> | f2b-wl-list
#                 bash security.sh torrent-on | torrent-off | torrent-status
#                 tambahkan -y di belakang untuk lewati konfirmasi
#
#   CATATAN FAIL2BAN: hanya melindungi login yang masuk LANGSUNG ke
#   port SSH (22) dan Dropbear (442/109/143). Login lewat WebSocket/
#   SSL/HAProxy datang dari 127.0.0.1 (IP asli client tidak terlihat
#   oleh sshd/dropbear), jadi tidak bisa diblokir per-IP oleh Fail2ban.
# ============================================================

SCRIPT_DIR="${VPN_SCRIPT_DIR:-/etc/vpn-script}"
source "$SCRIPT_DIR/lib.sh"

F2B_CONF="${F2B_CONF:-/etc/fail2ban/jail.d/vpn-script.local}"
F2B_WL="$SCRIPT_DIR/.f2b-whitelist"
NOTORRENT="$SCRIPT_DIR/addon/torrent-block.sh"
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

# IPv4 / IPv6, boleh pakai /CIDR
valid_ip() {
  local ip="$1" addr="${1%%/*}" mask=""
  [[ "$ip" == */* ]] && mask="${ip#*/}"
  if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local o
    for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done
    [[ -z "$mask" || ( "$mask" =~ ^[0-9]{1,2}$ && mask -le 32 ) ]] && return 0
    return 1
  fi
  if [[ "$addr" =~ ^[0-9a-fA-F:]+$ && "$addr" == *:*:* ]]; then
    [[ -z "$mask" || ( "$mask" =~ ^[0-9]{1,3}$ && mask -le 128 ) ]] && return 0
  fi
  return 1
}

# ports_of <regex proses> <fallback> -> "22,2222"
ports_of() {
  local p
  p=$(ss -tlnp 2>/dev/null | tail -n +2 | awk -v n="$1" '$0 ~ n {c=split($4,a,":"); print a[c]}' | sort -un | paste -sd, -)
  echo "${p:-$2}"
}

f2b_installed() { command -v fail2ban-client >/dev/null 2>&1; }
f2b_active()    { systemctl is-active --quiet fail2ban 2>/dev/null; }

# ─── Fail2ban: whitelist ───────────────────────────────────
wl_list() { [[ -f "$F2B_WL" ]] && grep -v '^[[:space:]]*$' "$F2B_WL"; }

wl_add() {
  local ip="$1"
  valid_ip "$ip" || { echo -e "  ${RED}[GAGAL]${NC} Format IP tidak valid: $ip"; return 1; }
  touch "$F2B_WL"
  if grep -qxF "$ip" "$F2B_WL"; then
    echo -e "  ${YELLOW}[i]${NC} $ip sudah ada di whitelist."; return 0
  fi
  echo "$ip" >> "$F2B_WL"
  echo -e "  ${GREEN}[OK]${NC} $ip masuk whitelist."
  f2b_apply_if_active
}

wl_del() {
  local ip="$1"
  [[ -f "$F2B_WL" ]] && grep -qxF "$ip" "$F2B_WL" || { echo -e "  ${YELLOW}[i]${NC} $ip tidak ada di whitelist."; return 1; }
  grep -vxF "$ip" "$F2B_WL" > "$F2B_WL.tmp"; mv "$F2B_WL.tmp" "$F2B_WL"
  echo -e "  ${GREEN}[OK]${NC} $ip dihapus dari whitelist."
  f2b_apply_if_active
}

# ─── Fail2ban: konfigurasi ─────────────────────────────────
f2b_write_conf() {
  local ssh_ports drop_ports ignore ip backend
  ssh_ports=$(ports_of 'sshd' 22)
  drop_ports=$(ports_of 'dropbear' '442,109,143')
  ignore="127.0.0.1/8 ::1"
  while IFS= read -r ip; do [[ -n "$ip" ]] && ignore+=" $ip"; done < <(wl_list)
  # Backend ditentukan di sini (jangan bergantung default distro: Debian/Ubuntu
  # baru memaksa backend=systemd untuk semua jail lewat defaults-debian.conf).
  if [[ -f /var/log/auth.log ]]; then
    backend=$'backend = auto\nlogpath = /var/log/auth.log'
  else
    backend="backend = systemd"   # tanpa rsyslog, log SSH hanya ada di journal
  fi

  mkdir -p "$(dirname "$F2B_CONF")"
  cat > "$F2B_CONF" <<EOF
# Dibuat oleh menu Keamanan (CHANELOG VPN SCRIPT). Jangan edit manual:
# ubah lewat menu (whitelist IP dll), file ini ditulis ulang otomatis.
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w
ignoreip = $ignore

[sshd]
enabled = true
port    = $ssh_ports
$backend

[dropbear]
enabled = true
port    = $drop_ports
$backend
EOF
}

f2b_apply_if_active() {
  f2b_write_conf
  f2b_active && fail2ban-client reload >/dev/null 2>&1
}

# ─── Fail2ban: aksi ────────────────────────────────────────
f2b_install() {
  echo -e "${CYAN}[*]${NC} Memasang Fail2ban..."
  if ! f2b_installed; then
    apt-get update -qq >/dev/null 2>&1
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null 2>&1; then
      echo -e "  ${RED}[GAGAL]${NC} apt gagal memasang fail2ban. Cek koneksi/repo VPS."
      return 1
    fi
  fi

  # Pengaman: IP yang sedang dipakai login SSH otomatis di-whitelist.
  local client_ip="${SSH_CONNECTION%% *}"
  if [[ -n "$client_ip" ]] && valid_ip "$client_ip"; then
    touch "$F2B_WL"
    if ! grep -qxF "$client_ip" "$F2B_WL"; then
      echo "$client_ip" >> "$F2B_WL"
      echo -e "  ${GREEN}[OK]${NC} IP Anda ($client_ip) otomatis di-whitelist supaya tidak terblokir sendiri."
    fi
  fi

  # Tanpa /var/log/auth.log (tanpa rsyslog) Fail2ban membaca journal -> butuh python3-systemd.
  if [[ ! -f /var/log/auth.log ]] && ! python3 -c 'import systemd.journal' >/dev/null 2>&1; then
    echo -e "  ${CYAN}[*]${NC} Memasang python3-systemd (pembaca journal untuk Fail2ban)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-systemd >/dev/null 2>&1 \
      || echo -e "  ${YELLOW}[!]${NC} python3-systemd gagal terpasang, jail mungkin tidak bisa membaca log."
  fi

  f2b_write_conf
  if command -v fail2ban-client >/dev/null && ! fail2ban-client -t >/dev/null 2>&1; then
    echo -e "  ${RED}[GAGAL]${NC} Konfigurasi Fail2ban tidak valid (cek: fail2ban-client -t). File dihapus."
    rm -f "$F2B_CONF"
    return 1
  fi

  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban 2>/dev/null
  sleep 3

  if f2b_active && fail2ban-client status sshd >/dev/null 2>&1; then
    echo -e "  ${GREEN}[OK]${NC} Fail2ban aktif (jail: sshd$(fail2ban-client status dropbear >/dev/null 2>&1 && echo ', dropbear'))."
    echo -e "  ${DIM}Aturan: 5x gagal login dalam 10 menit -> diblokir 1 jam (naik 2x tiap berulang).${NC}"
    echo -e "  ${DIM}Hanya login langsung ke port SSH/Dropbear; jalur WS/SSL tidak terlihat IP aslinya.${NC}"
    return 0
  fi
  echo -e "  ${RED}[GAGAL]${NC} Fail2ban belum berjalan. Cek: journalctl -u fail2ban -n 20 --no-pager"
  return 1
}

f2b_jail_line() {  # f2b_jail_line "<output status>" "<label di output>"
  echo "$1" | grep -F "$2" | head -1 | sed 's/.*:[[:space:]]*//'
}

f2b_status() {
  if ! f2b_installed; then
    echo -e "  Fail2ban : ${DIM}belum terpasang${NC}"; return 0
  fi
  if f2b_active; then
    echo -e "  Fail2ban : ${GREEN}AKTIF${NC}"
  else
    echo -e "  Fail2ban : ${RED}TIDAK AKTIF${NC}"
    return 0
  fi
  local jail out
  for jail in sshd dropbear; do
    out=$(fail2ban-client status "$jail" 2>/dev/null) || { echo -e "  Jail ${jail} : ${DIM}tidak aktif${NC}"; continue; }
    echo -e "  Jail ${WHITE}${jail}${NC}"
    echo -e "    Gagal login sekarang : $(f2b_jail_line "$out" 'Currently failed')"
    echo -e "    Total gagal login    : $(f2b_jail_line "$out" 'Total failed')"
    echo -e "    Sedang diblokir      : ${WHITE}$(f2b_jail_line "$out" 'Currently banned')${NC}"
    echo -e "    Total pernah diblokir: $(f2b_jail_line "$out" 'Total banned')"
    local list; list=$(f2b_jail_line "$out" 'Banned IP list')
    [[ -n "${list// /}" ]] && echo -e "    IP terblokir         : ${YELLOW}${list}${NC}"
  done
  local wl; wl=$(wl_list | paste -sd' ' -)
  echo -e "  Whitelist : ${DIM}${wl:-kosong}${NC}"
}

f2b_unban() {
  local ip="$1"
  f2b_installed && f2b_active || { echo -e "  ${RED}[GAGAL]${NC} Fail2ban tidak aktif."; return 1; }
  valid_ip "$ip" || { echo -e "  ${RED}[GAGAL]${NC} Format IP tidak valid: $ip"; return 1; }
  if fail2ban-client unban "$ip" >/dev/null 2>&1; then
    echo -e "  ${GREEN}[OK]${NC} $ip dibuka blokirnya (kalau memang sedang diblokir)."
  else
    echo -e "  ${RED}[GAGAL]${NC} Gagal unban $ip."; return 1
  fi
}

f2b_off() {
  f2b_installed || { echo -e "  ${YELLOW}[i]${NC} Fail2ban belum terpasang."; return 0; }
  systemctl disable --now fail2ban >/dev/null 2>&1
  echo -e "  ${GREEN}[OK]${NC} Fail2ban dimatikan (paket tetap terpasang, aktifkan lagi lewat menu Pasang)."
}

# ─── Torrent ───────────────────────────────────────────────
torrent_call() {
  [[ -f "$NOTORRENT" ]] || { echo -e "  ${RED}[GAGAL]${NC} addon/torrent-block.sh tidak ditemukan di $SCRIPT_DIR/addon."; return 1; }
  bash "$NOTORRENT" "$1" -y
}

torrent_on() {
  echo -e "  ${YELLOW}Perhatian:${NC} Xray akan di-restart sebentar (koneksi Xray tersambung ulang otomatis)."
  confirm "Aktifkan blokir torrent?" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }
  torrent_call on
}

torrent_off() {
  confirm "Nonaktifkan blokir torrent? (Xray di-restart sebentar)" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }
  torrent_call off
}

# ─── Menu ──────────────────────────────────────────────────
run_action() { echo ""; "$@"; pause; }

security_menu() {
  local f2b_badge tor_badge
  if f2b_installed && f2b_active; then f2b_badge="${GREEN}aktif${NC}"; else f2b_badge="${DIM}nonaktif${NC}"; fi
  if [[ -f "$SCRIPT_DIR/.torrent-block-on" ]]; then tor_badge="${GREEN}aktif${NC}"; else tor_badge="${DIM}nonaktif${NC}"; fi

  clear
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}KEAMANAN${NC}"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_kv "Fail2ban (SSH)"   "$f2b_badge"
  ui_kv "Blokir torrent"   "$tor_badge"
  ui_section "  FAIL2BAN (anti brute-force SSH)"
  ui_2col "$(ui_menu_num 01 'Pasang & Aktifkan' "$GREEN")"  "$(ui_menu_num 02 'Status & IP Terblokir')"
  ui_2col "$(ui_menu_num 03 'Unban IP')"                    "$(ui_menu_num 04 'Whitelist IP')"
  ui_2col "$(ui_menu_num 05 'Matikan Fail2ban' "$RED")"     ""
  ui_section "  BLOKIR TORRENT"
  ui_2col "$(ui_menu_num 06 'Blokir Torrent ON' "$GREEN")"  "$(ui_menu_num 07 'Blokir Torrent OFF' "$RED")"
  ui_2col "$(ui_menu_num 08 'Status Blokir Torrent')"       ""
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_line "$(ui_menu_num 00 'Kembali ke Menu Utama' "$DIM")"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  echo -ne "  ${WHITE}${BOLD}Pilih menu [0-8]${NC} ${DIM}›${NC} "
  read -r choice

  case "$choice" in
    1) run_action f2b_install ;;
    2) run_action f2b_status ;;
    3) echo -ne "  ${WHITE}IP yang di-unban${NC}: "; read -r ip; run_action f2b_unban "$ip" ;;
    4) whitelist_menu ;;
    5) run_action f2b_off ;;
    6) run_action torrent_on ;;
    7) run_action torrent_off ;;
    8) run_action torrent_call status ;;
    0) bash "$SCRIPT_DIR/menu.sh"; return ;;
    *) echo -e "  ${RED}[!] Pilihan tidak valid${NC}"; sleep 1 ;;
  esac
  security_menu
}

whitelist_menu() {
  echo ""
  echo -e "  ${WHITE}Whitelist saat ini${NC}: ${DIM}$(wl_list | paste -sd' ' - | sed 's/^$/kosong/')${NC}"
  echo -e "  ${YELLOW}[1]${NC} Tambah IP   ${YELLOW}[2]${NC} Hapus IP   ${YELLOW}[0]${NC} Kembali"
  echo -ne "  ${WHITE}Pilih${NC}: "
  read -r w
  case "$w" in
    1) echo -ne "  ${WHITE}IP/CIDR yang ditambah${NC}: "; read -r ip; run_action wl_add "$ip" ;;
    2) echo -ne "  ${WHITE}IP/CIDR yang dihapus${NC}: ";  read -r ip; run_action wl_del "$ip" ;;
  esac
}

# ─── Entry point ───────────────────────────────────────────
if [[ -n "$1" ]]; then
  CLI=1
  for a in "$@"; do [[ "$a" == "-y" ]] && ASSUME_YES=1; done
  case "$1" in
    f2b-install)    f2b_install ;;
    f2b-status)     f2b_status ;;
    f2b-off)        f2b_off ;;
    f2b-unban)      f2b_unban "$2" ;;
    f2b-wl-add)     wl_add "$2" ;;
    f2b-wl-del)     wl_del "$2" ;;
    f2b-wl-list)    wl_list ;;
    torrent-on)     torrent_on ;;
    torrent-off)    torrent_off ;;
    torrent-status) torrent_call status ;;
    *) echo "Pemakaian: bash $0 [f2b-install|f2b-status|f2b-off|f2b-unban IP|f2b-wl-add IP|f2b-wl-del IP|f2b-wl-list|torrent-on|torrent-off|torrent-status] [-y]"; exit 1 ;;
  esac
  exit $?
fi

security_menu
