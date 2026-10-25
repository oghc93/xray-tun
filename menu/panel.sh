#!/bin/bash
# ============================================================
#   CHANELOG VPN SCRIPT - WEB PANEL / API
#   Pasang panel web lengkap, atau API saja (untuk Panel Worker
#   multi-VPS). Repo: oghc93/cocote-3x-ui
# ============================================================

SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh"

PANEL_RAW="https://raw.githubusercontent.com/oghc93/cocote-3x-ui/refs/heads/main/deploy"
PANEL_WEB="/var/www/vpn-panel/index.html"
API_PHP="/var/www/vpn-api/index.php"
API_KEY_FILE="$SCRIPT_DIR/api-key.txt"

panel_installed() { [[ -f "$PANEL_WEB" ]]; }
api_installed()   { [[ -f "$API_PHP" ]]; }

# $1 = full | api
panel_install() {
  local mode="${1:-full}"
  echo ""
  echo -e "  ${CYAN}[*]${NC} Mengunduh installer..."
  local tmp; tmp=$(mktemp)
  if ! wget -q --timeout=30 "$PANEL_RAW/install.sh" -O "$tmp" || [[ ! -s "$tmp" ]] || ! bash -n "$tmp" 2>/dev/null; then
    echo -e "  ${RED}[!] Gagal mengunduh installer dari:${NC}"
    echo -e "  ${DIM}$PANEL_RAW/install.sh${NC}"
    echo -e "  ${YELLOW}Cek koneksi VPS / pastikan file ada di GitHub (repo cocote-3x-ui).${NC}"
    rm -f "$tmp"; return 1
  fi
  echo -e "  ${CYAN}$LINE${NC}"
  if [[ "$mode" == "api" ]]; then API_ONLY=1 bash "$tmp"; else API_ONLY=0 bash "$tmp"; fi
  local rc=$?
  rm -f "$tmp"
  if [[ $rc -ne 0 ]]; then
    echo -e "\n  ${RED}[!] Instalasi gagal (kode $rc). Lihat pesan di atas.${NC}"
    return 1
  fi
  if ! command -v vpn-update >/dev/null 2>&1; then
    local vu; vu=$(mktemp)
    if wget -q --timeout=30 "$PANEL_RAW/update.sh" -O "$vu" && [[ -s "$vu" ]] && bash -n "$vu" 2>/dev/null; then
      install -m 755 "$vu" /usr/local/bin/vpn-update
    fi
    rm -f "$vu"
  fi
  if [[ "$mode" == "api" ]]; then
    echo -e "\n  ${GREEN}[OK]${NC} API terpasang. URL API: ${WHITE}https://$(get_domain)/api${NC}"
    echo -e "  Tampilkan API key lewat menu ini (pilihan 3)."
  else
    echo -e "\n  ${GREEN}[OK]${NC} Panel terpasang. Buka: ${WHITE}https://$(get_domain)/panel/${NC}"
  fi
  return 0
}

confirm_reinstall() {
  echo -ne "  ${YELLOW}Sudah terpasang. Pasang ulang? Ketik 'YA'${NC}: "; read -r y
  [[ "$y" == "YA" ]]
}

show_api_info() {
  if ! api_installed; then
    echo -e "  ${RED}[!] API belum terpasang. Pilih 1 (API saja) atau 2 (panel lengkap).${NC}"; return
  fi
  echo ""
  echo -e "  URL API : ${WHITE}https://$(get_domain)/api${NC}"
  if [[ -s "$API_KEY_FILE" ]]; then
    echo -e "  API key : ${WHITE}$(cat "$API_KEY_FILE")${NC}"
    echo -e "  ${DIM}Isi keduanya di Panel Worker -> Kelola server. Jangan dibagikan.${NC}"
  else
    echo -e "  ${RED}[!] File API key tidak ditemukan ($API_KEY_FILE).${NC}"
  fi
}

panel_menu() {
  clear
  echo -e "${CYAN}$UI_BOX_TOP${NC}"
  ui_line_center "${WHITE}${BOLD}WEB PANEL / API${NC}"
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  if panel_installed; then ui_line "Panel web : ${GREEN}terpasang${NC}  ${DIM}https://$(get_domain)/panel/${NC}"
  else ui_line "Panel web : ${YELLOW}belum terpasang${NC}"; fi
  if api_installed; then ui_line "API       : ${GREEN}terpasang${NC}  ${DIM}https://$(get_domain)/api${NC}"
  else ui_line "API       : ${YELLOW}belum terpasang${NC}"; fi
  echo -e "${CYAN}$UI_BOX_MID${NC}"
  ui_line "$(ui_menu_num 1 'Pasang API saja (untuk Panel Worker)')"
  ui_line "$(ui_menu_num 2 'Pasang panel web lengkap (tampilan + API)')"
  ui_line "$(ui_menu_num 3 'Tampilkan URL API & API key')"
  ui_line "$(ui_menu_num 4 'Update (vpn-update)')"
  ui_line "$(ui_menu_num 0 'Kembali' "$DIM")"
  echo -e "${CYAN}$UI_BOX_BOT${NC}"
  echo ""
  echo -ne "  ${WHITE}${BOLD}Pilih${NC} ${DIM}›${NC} "
  read -r c

  case "$c" in
    1) if api_installed && ! panel_installed; then confirm_reinstall && panel_install api || echo -e "  ${YELLOW}[!] Dibatalkan${NC}"
       elif panel_installed; then echo -e "  ${YELLOW}[!] Panel lengkap sudah terpasang (sudah termasuk API). Tidak perlu API saja.${NC}"
       else panel_install api; fi ;;
    2) if panel_installed; then confirm_reinstall && panel_install full || echo -e "  ${YELLOW}[!] Dibatalkan${NC}"
       else panel_install full; fi ;;
    3) show_api_info ;;
    4) if command -v vpn-update >/dev/null 2>&1; then vpn-update; else echo -e "  ${RED}[!] vpn-update belum terpasang. Pasang API/panel dulu.${NC}"; fi ;;
    0|"") bash "$SCRIPT_DIR/menu.sh"; return ;;
    *) echo -e "  ${RED}[!] Pilihan tidak valid${NC}" ;;
  esac
  echo ""
  read -rp "  Tekan Enter untuk kembali..." _
  panel_menu
}

panel_menu
