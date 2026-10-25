#!/bin/bash
# ============================================================
#   CHANELOG VPN SCRIPT - BBR & IPv6 ON/OFF MENU (ADDON)
#
#   Lewat menu  : vpn  -> pilih "BBR & IPv6"
#   Langsung    : bash bbr.sh status
#                 bash bbr.sh bbr-on | bbr-off
#                 bash bbr.sh ipv6-on | ipv6-off
#                 bash bbr.sh all-on            (BBR ON + IPv6 OFF)
#                 tambahkan -y di belakang untuk lewati konfirmasi
#
#   BBR  : algoritma congestion control TCP buatan Google
#          (butuh kernel >= 4.9). Disimpan permanen di
#          /etc/sysctl.d/99-vpn-bbr.conf, jadi tetap aktif
#          setelah reboot.
#   IPv6 : dinonaktifkan lewat sysctl (bukan parameter kernel),
#          jadi layanan yang bind ke [::] tidak error.
# ============================================================

SCRIPT_DIR="${VPN_SCRIPT_DIR:-/etc/vpn-script}"
source "$SCRIPT_DIR/lib.sh"

SYSCTL_DIR="${SYSCTL_DIR:-/etc/sysctl.d}"
MODULES_LOAD_DIR="${MODULES_LOAD_DIR:-/etc/modules-load.d}"
BBR_CONF="$SYSCTL_DIR/99-vpn-bbr.conf"
IPV6_CONF="$SYSCTL_DIR/99-vpn-ipv6.conf"
MODULES_CONF="$MODULES_LOAD_DIR/vpn-bbr.conf"
BBR_PREV="${BBR_PREV:-$SCRIPT_DIR/.bbr-prev}"

LINE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
CLI=0
ASSUME_YES=0

# ─── Helper ────────────────────────────────────────────────
sysctl_get() { sysctl -n "$1" 2>/dev/null; }

pause() { [[ "$CLI" == "1" ]] && return; echo ""; echo -ne "  ${DIM}Tekan Enter untuk kembali...${NC}"; read -r; }

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  echo -ne "  ${WHITE}$1 [y/N]${NC}: "
  read -r a
  [[ "$a" =~ ^[Yy]$ ]]
}

# kernel_ge 4.9 -> benar kalau kernel sekarang >= 4.9
kernel_ge() {
  local cur
  cur=$(uname -r | grep -oE '^[0-9]+\.[0-9]+')
  [[ -n "$cur" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$cur" | sort -V | head -n1)" == "$1" ]]
}

bbr_is_on()    { [[ "$(sysctl_get net.ipv4.tcp_congestion_control)" == "bbr" ]]; }
IPV6_PROC="${IPV6_PROC:-/proc/sys/net/ipv6/conf/all/disable_ipv6}"
ipv6_present() { [[ -e "$IPV6_PROC" ]]; }
ipv6_is_off()  { ! ipv6_present || [[ "$(sysctl_get net.ipv6.conf.all.disable_ipv6)" == "1" ]]; }

# ─── Status ────────────────────────────────────────────────
render_status() {
  local cc qd bbr_badge v6_badge persist
  cc=$(sysctl_get net.ipv4.tcp_congestion_control); cc="${cc:-?}"
  qd=$(sysctl_get net.core.default_qdisc);          qd="${qd:-?}"

  if bbr_is_on; then
    bbr_badge="${GREEN}ON${NC}"
  else
    bbr_badge="${RED}OFF${NC}"
  fi
  persist="${DIM}tidak${NC}"; [[ -f "$BBR_CONF" ]] && persist="${GREEN}ya (setelah reboot tetap)${NC}"

  if ! ipv6_present; then
    v6_badge="${DIM}tidak tersedia di kernel${NC}"
  elif ipv6_is_off; then
    v6_badge="${RED}NONAKTIF${NC}"
  else
    v6_badge="${GREEN}AKTIF${NC}"
  fi

  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}BBR & IPv6${NC}"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_kv "Kernel"            "$(uname -r)"
  ui_kv "Congestion control" "$cc"
  ui_kv "Default qdisc"     "$qd"
  ui_kv "BBR"               "$bbr_badge"
  ui_kv "BBR permanen"      "$persist"
  ui_kv "IPv6"              "$v6_badge"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
}

# ─── BBR ON ────────────────────────────────────────────────
bbr_enable() {
  echo -e "  ${CYAN}[*]${NC} Memeriksa dukungan BBR..."

  if ! kernel_ge 4.9; then
    echo -e "  ${RED}[GAGAL]${NC} Kernel $(uname -r) terlalu lama, BBR butuh kernel >= 4.9."
    return 1
  fi

  case "$(systemd-detect-virt -c 2>/dev/null)" in
    openvz|lxc|lxc-libvirt)
      echo -e "  ${YELLOW}[!]${NC} VPS ini berjenis container (OpenVZ/LXC): kernel dipakai bersama host,"
      echo -e "      BBR biasanya tidak bisa diubah dari dalam. Tetap dicoba, dibatalkan kalau gagal."
      ;;
  esac

  modprobe tcp_bbr 2>/dev/null
  if ! sysctl_get net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
    echo -e "  ${RED}[GAGAL]${NC} Modul BBR tidak tersedia di kernel ini."
    return 1
  fi

  # Simpan nilai lama (sekali saja) supaya "BBR OFF" bisa mengembalikannya.
  if [[ ! -f "$BBR_PREV" ]] && ! bbr_is_on; then
    {
      echo "PREV_CC=$(sysctl_get net.ipv4.tcp_congestion_control)"
      echo "PREV_QDISC=$(sysctl_get net.core.default_qdisc)"
    } > "$BBR_PREV"
  fi

  mkdir -p "$SYSCTL_DIR" "$MODULES_LOAD_DIR"
  cat > "$BBR_CONF" <<EOF
# Dibuat oleh menu BBR (CHANELOG VPN SCRIPT).
# Hapus lewat menu "BBR OFF", jangan edit manual.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  echo "tcp_bbr" > "$MODULES_CONF"

  sysctl -p "$BBR_CONF" >/dev/null 2>&1

  if bbr_is_on; then
    echo -e "  ${GREEN}[OK]${NC} BBR aktif (congestion control: $(sysctl_get net.ipv4.tcp_congestion_control))."
    if [[ "$(sysctl_get net.core.default_qdisc)" != "fq" ]]; then
      echo -e "  ${DIM}Default qdisc belum fq (dibatasi kernel/container). Di kernel >= 4.13${NC}"
      echo -e "  ${DIM}BBR tetap berjalan normal tanpa fq.${NC}"
    fi
    echo -e "  ${DIM}Koneksi yang sudah berjalan tetap pakai algoritma lama;${NC}"
    echo -e "  ${DIM}koneksi baru otomatis memakai BBR. Permanen setelah reboot.${NC}"
    return 0
  fi

  rm -f "$BBR_CONF" "$MODULES_CONF" "$BBR_PREV"
  echo -e "  ${RED}[GAGAL]${NC} Kernel menolak perubahan, BBR tidak aktif. Perubahan dibatalkan."
  return 1
}

# ─── BBR OFF ───────────────────────────────────────────────
bbr_disable() {
  local PREV_CC="" PREV_QDISC="" cc qd
  [[ -f "$BBR_PREV" ]] && source "$BBR_PREV"

  cc="${PREV_CC:-cubic}"; qd="${PREV_QDISC:-fq_codel}"
  [[ "$cc" == "bbr" ]] && cc="cubic"
  sysctl_get net.ipv4.tcp_available_congestion_control | grep -qw "$cc" || cc="reno"

  rm -f "$BBR_CONF" "$MODULES_CONF" "$BBR_PREV"
  sysctl -w net.ipv4.tcp_congestion_control="$cc" >/dev/null 2>&1
  sysctl -w net.core.default_qdisc="$qd" >/dev/null 2>&1

  if bbr_is_on; then
    echo -e "  ${RED}[GAGAL]${NC} BBR masih aktif, cek manual: sysctl net.ipv4.tcp_congestion_control"
    return 1
  fi
  echo -e "  ${GREEN}[OK]${NC} BBR dimatikan, kembali ke ${WHITE}$cc${NC} (qdisc ${WHITE}$qd${NC})."

  # File sysctl lain (bawaan provider/manual) bisa menyalakan BBR lagi setelah reboot.
  local others
  others=$(grep -rlsE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr' \
             /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d 2>/dev/null)
  if [[ -n "$others" ]]; then
    echo -e "  ${YELLOW}[!]${NC} File lain masih menyetel BBR, akan aktif lagi setelah reboot:"
    echo "$others" | sed 's/^/      /'
  fi
  return 0
}

# ─── IPv6 OFF ──────────────────────────────────────────────
ipv6_disable() {
  if ! ipv6_present; then
    echo -e "  ${YELLOW}[i]${NC} IPv6 tidak tersedia di kernel ini (sudah nonaktif)."
    return 0
  fi

  # Pengaman 1: sesi SSH sekarang lewat IPv6 -> koneksi akan putus.
  local client_ip="${SSH_CONNECTION%% *}"
  if [[ "$client_ip" == *:* ]]; then
    echo -e "  ${RED}[!]${NC} Anda sedang login SSH lewat IPv6 (${client_ip})."
    echo -e "      Menonaktifkan IPv6 akan memutus sesi ini dan bisa mengunci Anda dari VPS."
    if [[ "$ASSUME_YES" == "1" ]]; then
      echo -e "  ${RED}[BATAL]${NC} Mode -y tidak boleh dipakai di sesi IPv6. Login lewat IPv4 dulu."
      return 1
    fi
    confirm "Tetap lanjut? (tidak disarankan)" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }
  fi

  # Pengaman 2: tidak ada jalur IPv4 -> VPS akan offline total.
  if [[ -z "$(ip -4 route show default 2>/dev/null)" ]]; then
    echo -e "  ${RED}[BATAL]${NC} Tidak ada default route IPv4. VPS ini sepertinya hanya IPv6,"
    echo -e "          menonaktifkan IPv6 akan membuatnya offline."
    return 1
  fi

  echo -e "  ${YELLOW}Perhatian:${NC}"
  echo -e "  - Kalau domain Anda punya record ${WHITE}AAAA${NC} (IPv6) di DNS/Cloudflare,"
  echo -e "    hapus dulu, kalau tidak client yang memilih IPv6 tidak bisa konek."
  confirm "Nonaktifkan IPv6 sekarang?" || { echo -e "  ${YELLOW}Dibatalkan${NC}"; return 1; }

  mkdir -p "$SYSCTL_DIR"
  cat > "$IPV6_CONF" <<EOF
# Dibuat oleh menu IPv6 (CHANELOG VPN SCRIPT).
# Hapus lewat menu "IPv6 ON", jangan edit manual.
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
# Loopback ::1 dibiarkan hidup supaya layanan lokal tidak error.
net.ipv6.conf.lo.disable_ipv6=0
EOF
  sysctl -p "$IPV6_CONF" >/dev/null 2>&1

  if ipv6_is_off; then
    echo -e "  ${GREEN}[OK]${NC} IPv6 dinonaktifkan (permanen setelah reboot)."
    return 0
  fi
  rm -f "$IPV6_CONF"
  echo -e "  ${RED}[GAGAL]${NC} Kernel menolak perubahan, IPv6 tetap aktif."
  return 1
}

# ─── IPv6 ON ───────────────────────────────────────────────
ipv6_enable() {
  if ! ipv6_present; then
    echo -e "  ${RED}[GAGAL]${NC} IPv6 dimatikan dari kernel (ipv6.disable=1), tidak bisa dihidupkan dari sini."
    return 1
  fi
  rm -f "$IPV6_CONF"
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1

  if ipv6_is_off; then
    echo -e "  ${RED}[GAGAL]${NC} IPv6 masih nonaktif, cek manual: sysctl net.ipv6.conf.all.disable_ipv6"
    return 1
  fi
  echo -e "  ${GREEN}[OK]${NC} IPv6 diaktifkan."
  echo -e "  ${DIM}Alamat IPv6 publik muncul beberapa detik lagi. Kalau tidak muncul,${NC}"
  echo -e "  ${DIM}restart jaringan atau reboot VPS.${NC}"
  return 0
}

# ─── Penjelasan BBR ────────────────────────────────────────
bbr_info() {
  clear
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}APA ITU BBR?${NC}"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  echo -e "  BBR adalah algoritma pengatur kecepatan TCP buatan Google."
  echo -e "  Bedanya dengan bawaan (CUBIC):"
  echo -e "  ${CYAN}$LINE${NC}"
  echo -e "  - CUBIC menurunkan kecepatan saat ada paket hilang."
  echo -e "    BBR mengukur bandwidth & latensi asli jalur, jadi"
  echo -e "    tidak panik pada packet loss yang sepele."
  echo -e "  - Hasilnya: kiriman dari server (download di HP/PC user)"
  echo -e "    lebih kencang & stabil,"
  echo -e "    terutama di jalur jauh (Indonesia ke VPS luar negeri)"
  echo -e "    dan jaringan seluler yang loss-nya tinggi."
  echo -e "  - Latensi (ping) saat jaringan padat cenderung lebih rendah."
  echo -e "  ${CYAN}$LINE${NC}"
  echo -e "  ${WHITE}Catatan:${NC}"
  echo -e "  - Efeknya ke trafik TCP (SSH-WS, SSL, VMess/VLess/Trojan WS)."
  echo -e "    UDP (misal lewat UDPGW) tidak dipengaruhi."
  echo -e "  - Tidak menambah kuota/bandwidth VPS, hanya memakainya lebih efisien."
  echo -e "  - Butuh kernel >= 4.9 dan VPS bertipe KVM/VM (bukan OpenVZ/LXC)."
  echo -e "  - Aman: bisa dimatikan kapan saja lewat menu ini."
  pause
}

# ─── Menu ──────────────────────────────────────────────────
quick_optimize() { bbr_enable; echo ""; ipv6_disable; }

run_action() {
  echo ""
  "$@"
  pause
}

bbr_menu() {
  clear
  render_status
  echo ""
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_2col "$(ui_menu_num 01 'BBR ON' "$GREEN")"          "$(ui_menu_num 02 'BBR OFF' "$RED")"
  ui_2col "$(ui_menu_num 03 'IPv6 OFF' "$RED")"          "$(ui_menu_num 04 'IPv6 ON' "$GREEN")"
  ui_2col "$(ui_menu_num 05 'BBR ON + IPv6 OFF')"        "$(ui_menu_num 06 'Penjelasan BBR')"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_line "$(ui_menu_num 00 'Kembali ke Menu Utama' "$DIM")"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  echo -ne "  ${WHITE}${BOLD}Pilih menu [0-6]${NC} ${DIM}›${NC} "
  read -r choice

  case "$choice" in
    1) run_action bbr_enable ;;
    2) run_action bbr_disable ;;
    3) run_action ipv6_disable ;;
    4) run_action ipv6_enable ;;
    5) run_action quick_optimize ;;
    6) bbr_info ;;
    0) bash "$SCRIPT_DIR/menu.sh"; return ;;
    *) echo -e "  ${RED}[!] Pilihan tidak valid${NC}"; sleep 1 ;;
  esac
  bbr_menu
}

# ─── Entry point ───────────────────────────────────────────
if [[ -n "$1" ]]; then
  CLI=1
  [[ "$2" == "-y" ]] && ASSUME_YES=1
  case "$1" in
    status)    render_status ;;
    bbr-on)    bbr_enable ;;
    bbr-off)   bbr_disable ;;
    ipv6-on)   ipv6_enable ;;
    ipv6-off)  ipv6_disable ;;
    all-on)    quick_optimize ;;
    *) echo "Pemakaian: bash $0 [status|bbr-on|bbr-off|ipv6-on|ipv6-off|all-on] [-y]"; exit 1 ;;
  esac
  exit $?
fi

bbr_menu
