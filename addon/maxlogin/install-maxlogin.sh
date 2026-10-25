#!/bin/bash
# Pasang MaxLogin Xray (OPT-IN). Tidak mengubah SSHWS/Dropbear. Tidak menimpa config tanpa backup.
#   install-maxlogin.sh install     salin file + unit + config contoh (tidak menyalakan apa pun yang mengubah Xray)
#   install-maxlogin.sh enable-xray  sekali: inbound -ml + restart Xray + otomatis (xray_manage=true)
#   install-maxlogin.sh check       cek nginx -t dengan include (tanpa reload)
#   install-maxlogin.sh rollback    hentikan service, lepas unit, pulihkan config Xray dari backup terbaru
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"; DST=/etc/vpn-script/maxlogin
case "${1:-}" in
install)
  mkdir -p "$DST" /var/lib/vpn-script
  cp "$SRC"/maxlogin_core.py "$SRC"/maxlogin_service.py "$SRC"/xray_adapter.py "$SRC"/nginx-maxlogin*.inc "$DST"/
  [ -f /etc/vpn-script/maxlogin.json ] || cp "$SRC/maxlogin.json.example" /etc/vpn-script/maxlogin.json
  cp "$SRC/vpn-maxlogin.service" /etc/systemd/system/ && systemctl daemon-reload
  cat > /etc/logrotate.d/vpn-maxlogin <<'LR'
/var/log/vpn-maxlogin.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
LR
  systemctl enable --now vpn-maxlogin && sleep 1 && curl -s http://127.0.0.1:10901/health; echo
  echo "Service jalan. Langkah berikut (manual, lihat docs/MAXLOGIN_XRAY.md): include Nginx + xray-sync."
  ;;
check)
  nginx -t ;;
enable-xray)
  # SEKALI: tambah inbound -ml ke config Xray (backup), validasi, restart Xray, lalu aktifkan otomatis
  X=/usr/local/bin/xray; [ -x "$X" ] || X=$(command -v xray)
  export MAXLOGIN_CONFIG=/etc/vpn-script/maxlogin.json
  M=/etc/vpn-script/maxlogin/maxlogin_service.py
  python3 "$M" sync || exit 1
  python3 "$M" xray-sync | head -3
  if ! "$X" run -test -c /etc/xray/config.json >/dev/null 2>&1; then
    echo "config Xray TIDAK valid, dipulihkan"; B=$(ls -t /etc/xray/config.json.ml-bak.* | head -1); cp "$B" /etc/xray/config.json; exit 1
  fi
  sed -i 's/"xray_manage"[[:space:]]*:[[:space:]]*false/"xray_manage": true/' /etc/vpn-script/maxlogin.json
  systemctl restart vpn-maxlogin; systemctl restart xray; sleep 2; systemctl is-active xray
  ss -ltn | grep -E "10101|10102|10105" ;;
rollback)
  systemctl disable --now vpn-maxlogin 2>/dev/null; rm -f /etc/systemd/system/vpn-maxlogin.service; systemctl daemon-reload
  B=$(ls -t /etc/xray/config.json.ml-bak.* 2>/dev/null | head -1)
  if [ -n "$B" ]; then cp "$B" /etc/xray/config.json && echo "config Xray dipulihkan dari $B (restart xray untuk menerapkan)"; else echo "tidak ada backup config Xray"; fi
  echo "Hapus baris include maxlogin di config Nginx secara manual lalu: nginx -t && systemctl reload nginx" ;;
*) echo "pakai: $0 install|check|rollback"; exit 1 ;;
esac
