#!/bin/bash
# ============================================================
#   menu/backup.sh -- Backup & Restore via Bot Telegram
#   (engine: addon/tg-backup.py)
#
#   CLI:  backup.sh install   pasang service+cron (non-interaktif, dipakai installer)
#         backup.sh now       backup sekarang & kirim ke Telegram
#         backup.sh           menu interaktif
#   Token & Chat ID dipakai bersama menu "Bot Telegram" (.pro-config).
# ============================================================
SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh"

PY="$SCRIPT_DIR/addon/tg-backup.py"
SVC="tg-backup-bot"
SVC_FILE="/etc/systemd/system/${SVC}.service"
CRON_FILE="/etc/cron.d/tg-backup"
LINE="──────────────────────────────────────────────"

has_token() { load_pro_config; [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; }

ensure_deps() {
  command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && return 0
  apt-get install -y python3 curl >/dev/null 2>&1
}

write_service() {
  cat > "$SVC_FILE" <<UNIT
[Unit]
Description=Telegram Backup/Restore Bot
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 -u $PY bot
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload 2>/dev/null
}

cron_on()  { echo "0 3 * * * root /usr/bin/python3 $PY backup >/dev/null 2>&1" > "$CRON_FILE"; }
cron_off() { rm -f "$CRON_FILE"; }
cron_is()  { [[ -f "$CRON_FILE" ]]; }
bot_is()   { systemctl is-active --quiet "$SVC" 2>/dev/null; }

bot_on() {
  has_token || { echo -e "  ${RED}[!] Bot Token/Chat ID belum diisi. Pilih menu 1 dulu.${NC}"; return 1; }
  ensure_deps
  [[ -f "$PY" ]] || { echo -e "  ${RED}[!] $PY tidak ada. Jalankan Update Script.${NC}"; return 1; }
  chmod +x "$PY"
  write_service
  systemctl enable --now "$SVC" >/dev/null 2>&1
  sleep 1
  if bot_is; then echo -e "  ${GREEN}[OK]${NC} Bot backup aktif. Buka bot di Telegram, kirim /start"
  else echo -e "  ${RED}[!] Bot gagal jalan.${NC} Cek: journalctl -u $SVC -n 20"; return 1; fi
}

bot_off() {
  systemctl disable --now "$SVC" >/dev/null 2>&1
  echo -e "  ${GREEN}[OK]${NC} Bot backup dimatikan."
}

# Dipakai installer: pasang service + cron harian; bot hanya dijalankan kalau token sudah ada
do_install() {
  ensure_deps
  [[ -f "$PY" ]] || { echo "  [!] $PY tidak ada, backup dilewati"; return 0; }
  chmod +x "$PY"
  write_service
  cron_on
  if has_token; then
    systemctl enable --now "$SVC" >/dev/null 2>&1
    sleep 1
    if bot_is; then echo -e "  ${GREEN}[OK]${NC} Bot backup/restore Telegram aktif (backup otomatis tiap 03:00)"
    else echo -e "  ${YELLOW}[!]${NC} Bot backup belum jalan, cek: journalctl -u $SVC -n 20"; fi
  else
    echo -e "  ${YELLOW}[INFO]${NC} Token Telegram belum diisi: isi lewat menu 'Backup & Restore' -> 1, lalu bot aktif otomatis."
  fi
}

setup_token() {
  load_pro_config
  echo ""
  echo -e "  ${DIM}1. Chat @BotFather -> /newbot -> dapat TOKEN${NC}"
  echo -e "  ${DIM}2. Chat @userinfobot -> catat 'Id' kamu -> CHAT ID${NC}"
  echo ""
  echo -ne "  ${YELLOW}Bot Token${NC} [Enter = biarkan '${TELEGRAM_BOT_TOKEN:+tersimpan}${TELEGRAM_BOT_TOKEN:-kosong}']: "
  read -r t; t="${t:-$TELEGRAM_BOT_TOKEN}"
  echo -ne "  ${YELLOW}Chat ID${NC}   [Enter = biarkan '${TELEGRAM_CHAT_ID:-kosong}']: "
  read -r c; c="${c:-$TELEGRAM_CHAT_ID}"
  TELEGRAM_BOT_TOKEN="$t"; TELEGRAM_CHAT_ID="$c"
  save_pro_config
  if has_token; then
    cron_on
    # restart supaya token baru terbaca
    write_service; ensure_deps; systemctl enable "$SVC" >/dev/null 2>&1; systemctl restart "$SVC" >/dev/null 2>&1
    sleep 1
    bot_is && echo -e "  ${GREEN}[OK]${NC} Tersimpan. Bot backup aktif, kirim /start di Telegram." \
           || echo -e "  ${RED}[!] Tersimpan, tapi bot belum jalan.${NC} Cek: journalctl -u $SVC -n 20"
  else
    echo -e "  ${YELLOW}[!] Token/Chat ID kosong, bot tidak aktif.${NC}"
  fi
}

backup_now() {
  has_token || { echo -e "  ${RED}[!] Bot Token/Chat ID belum diisi (menu 1).${NC}"; return 1; }
  ensure_deps
  echo -e "  ${CYAN}[*]${NC} Membuat backup & mengirim ke Telegram..."
  python3 "$PY" backup && echo -e "  ${GREEN}[OK]${NC} Cek Telegram kamu." || echo -e "  ${RED}[!] Gagal.${NC}"
}

bk_menu() {
  clear
  load_pro_config
  local tk bs cs
  has_token && tk="${GREEN}terisi${NC}" || tk="${RED}belum diisi${NC}"
  bot_is && bs="${GREEN}AKTIF${NC}" || bs="${RED}mati${NC}"
  cron_is && cs="${GREEN}aktif (tiap 03:00)${NC}" || cs="${YELLOW}mati${NC}"
  echo -e "${CYAN}$LINE${NC}"
  echo -e "  ${WHITE}${BOLD}BACKUP & RESTORE (Bot Telegram)${NC}"
  echo -e "${CYAN}$LINE${NC}"
  echo -e "  Token/Chat ID  : $tk"
  echo -e "  Bot perintah   : $bs"
  echo -e "  Backup harian  : $cs"
  echo -e "${CYAN}$LINE${NC}"
  echo -e "  ${WHITE}1)${NC} Isi / ubah Bot Token & Chat ID"
  echo -e "  ${WHITE}2)${NC} Backup sekarang (kirim ke Telegram)"
  echo -e "  ${WHITE}3)${NC} Aktifkan bot backup/restore"
  echo -e "  ${WHITE}4)${NC} Matikan bot"
  echo -e "  ${WHITE}5)${NC} Backup harian otomatis: nyala/mati"
  echo -e "  ${WHITE}0)${NC} Kembali"
  echo -e "${CYAN}$LINE${NC}"
  echo -e "  ${DIM}Restore: kirim /restore ke bot, lalu kirim file backup (.tar.gz).${NC}"
  echo -ne "  ${WHITE}Pilih${NC} › "
  read -r ch
  case "$ch" in
    1) setup_token ;;
    2) backup_now ;;
    3) bot_on ;;
    4) bot_off ;;
    5) if cron_is; then cron_off; echo -e "  ${GREEN}[OK]${NC} Backup harian dimatikan."; else cron_on; echo -e "  ${GREEN}[OK]${NC} Backup harian aktif (03:00)."; fi ;;
    0) exec bash "$SCRIPT_DIR/menu.sh" ;;
    *) echo -e "  ${RED}[!] Pilihan tidak valid${NC}" ;;
  esac
  echo -ne "  ${DIM}Tekan Enter...${NC}"; read -r
  bk_menu
}

case "${1:-}" in
  install) do_install ;;
  now)     backup_now ;;
  "")      bk_menu ;;
  *)       echo "Pakai: backup.sh [install|now]"; exit 1 ;;
esac
