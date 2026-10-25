#!/bin/bash
# ============================================================
#   CHANELOG VPN SCRIPT - BLOKIR BITTORRENT (ADDON)
#
#   Dua lapis, dinyalakan/dimatikan bersamaan:
#
#   1) XRAY (VMess/VLess/Trojan/Shadowsocks)
#      Tambah sniffing + aturan routing protocol "bittorrent"
#      -> blackhole. Config divalidasi dulu (xray run -test),
#      kalau Xray gagal start config lama dikembalikan.
#      Sniffing dipasang mode routeOnly: domain hasil sniff hanya
#      dipakai untuk routing, tujuan koneksi TIDAK diubah.
#
#   2) SSH / Dropbear (trafik tunnel SSH keluar dari VPS sebagai
#      trafik biasa): iptables chain VPN_TORRENT dengan string-match
#      penanda BitTorrent di chain OUTPUT & FORWARD. Dibuat ulang
#      saat boot lewat vpn-torrent-block.service.
#
#   Batasan jujur: yang terdeteksi hanya BitTorrent yang tidak
#   dienkripsi (handshake / tracker / DHT biasa). Torrent dengan
#   enkripsi protokol (MSE/PE) bisa lolos dari kedua lapis.
#
#   Pemakaian:
#     bash torrent-block.sh on | off | status [-y]
#     bash torrent-block.sh apply     (dipanggil systemd saat boot)
# ============================================================

SCRIPT_DIR="${VPN_SCRIPT_DIR:-/etc/vpn-script}"
XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
FLAG="$SCRIPT_DIR/.torrent-block-on"
UNIT="$SYSTEMD_DIR/vpn-torrent-block.service"
SELF="$SCRIPT_DIR/addon/torrent-block.sh"
CHAIN="VPN_TORRENT"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

ACTION="${1:-status}"
ASSUME_YES=0
[[ "$2" == "-y" ]] && ASSUME_YES=1

# Penanda spesifik BitTorrent (sengaja tidak memakai kata umum seperti
# "announce" atau "torrent" saja supaya web biasa tidak ikut terblokir).
TORRENT_STRINGS=(
  "BitTorrent protocol"
  "peer_id="
  "info_hash"
  "get_peers"
  "find_node"
  "announce_peer"
  "announce.php?passkey="
  ".torrent"
)

ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
err()  { echo -e "  ${RED}[GAGAL]${NC} $*"; }
info() { echo -e "  ${CYAN}[*]${NC} $*"; }

# ─── Lapis 2: iptables ─────────────────────────────────────
ipt_supported() {
  command -v iptables >/dev/null 2>&1 || return 1
  modprobe xt_string 2>/dev/null
  iptables -N VPN_TORRENT_TEST 2>/dev/null
  iptables -F VPN_TORRENT_TEST 2>/dev/null
  iptables -A VPN_TORRENT_TEST -m string --algo bm --string "x" -j DROP 2>/dev/null
  local rc=$?
  iptables -F VPN_TORRENT_TEST 2>/dev/null
  iptables -X VPN_TORRENT_TEST 2>/dev/null
  return $rc
}

ipt_apply() {
  iptables -N "$CHAIN" 2>/dev/null
  iptables -F "$CHAIN"
  local s
  for s in "${TORRENT_STRINGS[@]}"; do
    iptables -A "$CHAIN" -m string --algo bm --string "$s" -j DROP
  done
  local ch
  for ch in OUTPUT FORWARD; do
    iptables -C "$ch" -j "$CHAIN" 2>/dev/null || iptables -I "$ch" 1 -j "$CHAIN"
  done
}

ipt_remove() {
  command -v iptables >/dev/null 2>&1 || return 0
  local ch n
  for ch in OUTPUT FORWARD; do
    n=0
    # Batas 20 putaran: kalau -D gagal terus (mis. tanpa hak akses) jangan loop selamanya.
    while (( n < 20 )) && iptables -C "$ch" -j "$CHAIN" 2>/dev/null; do
      iptables -D "$ch" -j "$CHAIN" 2>/dev/null || break
      n=$((n+1))
    done
  done
  iptables -F "$CHAIN" 2>/dev/null
  iptables -X "$CHAIN" 2>/dev/null
  return 0
}

ipt_active() {
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -C OUTPUT -j "$CHAIN" 2>/dev/null
}

# ─── Lapis 1: Xray ─────────────────────────────────────────
JQ_ON='
  (if any(.outbounds[]?; .tag == "blocked")
     then .
     else .outbounds = ((.outbounds // []) + [{"protocol":"blackhole","tag":"blocked","settings":{}}])
   end)
  | .inbounds = ((.inbounds // []) | map(
      if .tag == "api" then .
      else .sniffing = ({"destOverride":["http","tls"],"routeOnly":true} + (.sniffing // {}) + {"enabled":true})
      end))
  | (if any(.routing.rules[]?; ((.protocol // []) | index("bittorrent")))
       then .
       else .routing.rules = ([{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"}] + (.routing.rules // []))
     end)
'

JQ_OFF='
  .routing.rules = ((.routing.rules // []) | map(select((((.protocol // []) | index("bittorrent"))) | not)))
  | (if any(.routing.rules[]?; .outboundTag == "blocked")
       then .
       else .outbounds = ((.outbounds // []) | map(select(.tag != "blocked")))
     end)
  | .inbounds = ((.inbounds // []) | map(
      if (.sniffing // null) == {"destOverride":["http","tls"],"routeOnly":true,"enabled":true}
        then del(.sniffing) else . end))
'

xray_active() {
  [[ -f "$XRAY_CONFIG" ]] || return 1
  jq -e 'any(.routing.rules[]?; ((.protocol // []) | index("bittorrent")))' "$XRAY_CONFIG" >/dev/null 2>&1
}

# xray_patch "<program jq>"  -> ubah config, validasi, restart, rollback kalau gagal
xray_patch() {
  local prog="$1"
  [[ -f "$XRAY_CONFIG" ]] || { err "Config Xray tidak ditemukan ($XRAY_CONFIG)."; return 1; }
  command -v jq >/dev/null 2>&1 || { err "jq belum terpasang."; return 1; }

  local tmp prev
  tmp=$(mktemp); prev=$(mktemp)
  if ! jq "$prog" "$XRAY_CONFIG" > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp" "$prev"; err "Gagal memproses config Xray (jq)."; return 1
  fi
  if command -v xray >/dev/null 2>&1; then
    if ! xray run -test -c "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp" "$prev"; err "Config baru tidak lolos validasi Xray, dibatalkan (config lama utuh)."; return 1
    fi
  fi

  cp -a "$XRAY_CONFIG" "$prev"
  [[ -f "$XRAY_CONFIG.bak-torrent" ]] || cp -a "$XRAY_CONFIG" "$XRAY_CONFIG.bak-torrent"
  cat "$tmp" > "$XRAY_CONFIG"

  if [[ "${NO_RESTART:-0}" != "1" ]]; then
    systemctl restart xray 2>/dev/null
    sleep 2
    if ! systemctl is-active --quiet xray; then
      cat "$prev" > "$XRAY_CONFIG"
      systemctl restart xray 2>/dev/null
      rm -f "$tmp" "$prev"
      err "Xray gagal start dengan config baru, config lama dikembalikan."
      return 1
    fi
  fi
  rm -f "$tmp" "$prev"
  return 0
}

# ─── Persisten saat boot ───────────────────────────────────
unit_install() {
  cat > "$UNIT" <<EOF
[Unit]
Description=VPN Script - Blokir BitTorrent (iptables)
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $SELF apply

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null
  systemctl enable vpn-torrent-block.service >/dev/null 2>&1
}

unit_remove() {
  systemctl disable vpn-torrent-block.service >/dev/null 2>&1
  rm -f "$UNIT"
  systemctl daemon-reload 2>/dev/null
}

# ─── Aksi ──────────────────────────────────────────────────
cmd_on() {
  local x_ok=0 i_ok=0

  info "Lapis 1: Xray (VMess/VLess/Trojan/SS)..."
  if [[ "$ASSUME_YES" != "1" ]]; then
    echo -e "  ${DIM}Xray akan di-restart sebentar (sekitar 1-2 detik, koneksi Xray putus lalu konek ulang).${NC}"
    echo -ne "  ${WHITE}Lanjutkan? [y/N]${NC}: "
    read -r a
    [[ "$a" =~ ^[Yy]$ ]] || { warn "Dibatalkan."; return 1; }
  fi
  if xray_patch "$JQ_ON"; then ok "Aturan blokir BitTorrent aktif di Xray."; x_ok=1; fi

  info "Lapis 2: SSH/Dropbear (iptables)..."
  if ipt_supported; then
    ipt_apply && { ok "Chain $CHAIN terpasang (OUTPUT & FORWARD)."; i_ok=1; }
  else
    warn "iptables / modul xt_string tidak tersedia di VPS ini, lapis SSH dilewati."
  fi

  if (( x_ok || i_ok )); then
    : > "$FLAG"
    (( i_ok )) && unit_install
    ok "Blokir torrent AKTIF."
    echo -e "  ${DIM}Hanya torrent yang tidak terenkripsi yang terdeteksi.${NC}"
    return 0
  fi
  err "Tidak ada lapis yang berhasil dipasang."
  return 1
}

cmd_off() {
  local rc=0
  if xray_active; then
    if [[ "$ASSUME_YES" != "1" ]]; then
      echo -e "  ${DIM}Xray akan di-restart sebentar.${NC}"
      echo -ne "  ${WHITE}Lanjutkan? [y/N]${NC}: "
      read -r a
      [[ "$a" =~ ^[Yy]$ ]] || { warn "Dibatalkan."; return 1; }
    fi
    xray_patch "$JQ_OFF" && ok "Aturan BitTorrent dihapus dari Xray." || rc=1
  fi
  ipt_remove && ok "Chain $CHAIN dihapus."
  unit_remove
  rm -f "$FLAG"
  (( rc == 0 )) && ok "Blokir torrent NONAKTIF."
  return $rc
}

cmd_status() {
  local x i p
  xray_active && x="${GREEN}AKTIF${NC}" || x="${RED}mati${NC}"
  if ipt_active; then i="${GREEN}AKTIF${NC}"
  elif ipt_supported 2>/dev/null; then i="${RED}mati${NC}"
  else i="${DIM}tidak didukung kernel${NC}"; fi
  if systemctl is-enabled --quiet vpn-torrent-block.service 2>/dev/null; then p="${GREEN}ya${NC}"; else p="${DIM}tidak${NC}"; fi
  echo -e "  Xray (VMess/VLess/Trojan/SS) : $x"
  echo -e "  SSH/Dropbear (iptables)      : $i"
  echo -e "  Aktif lagi setelah reboot    : $p"
}

cmd_apply() {
  [[ -f "$FLAG" ]] || exit 0
  ipt_supported && ipt_apply
}

case "$ACTION" in
  on)     cmd_on ;;
  off)    cmd_off ;;
  status) cmd_status ;;
  apply)  cmd_apply ;;
  *) echo "Pemakaian: bash $0 [on|off|status|apply] [-y]"; exit 1 ;;
esac
