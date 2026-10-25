#!/bin/bash
# Pengelola MaxLogin Xray (satu pintu). Idempotent. Tidak menyentuh SSHWS/Dropbear.
#   maxlogin-xray.sh on [--fresh]   pasang + aktifkan penuh (file, service, Nginx, Xray, otomatis)
#   maxlogin-xray.sh off            matikan; akun berlimit dikembalikan ke inbound lama
#   maxlogin-xray.sh update         dipanggil run_update: segarkan file; aktif bila sudah ON
#   maxlogin-xray.sh status
#   maxlogin-xray.sh inject FILE    sisipkan include Nginx ke FILE (tanpa test/reload)
set -u
SD="${SD:-/etc/vpn-script}"; ML="$SD/addon/maxlogin"; RT="$SD/maxlogin"; MARK="$SD/.maxlogin-xray"
CFG="$SD/maxlogin.json"; XCONF="${XCONF:-/etc/xray/config.json}"
NGX="${NGINX_CONF:-/etc/nginx/conf.d/xray.conf}"; MAPF="${MAP_CONF:-/etc/nginx/conf.d/maxlogin-map.conf}"
NGX_TEST="${NGINX_TEST_CMD:-nginx -t}"; NGX_RELOAD="${NGINX_RELOAD_CMD:-systemctl reload nginx}"
M="$RT/maxlogin_service.py"; export MAXLOGIN_CONFIG="$CFG"
say() { echo "[maxlogin] $*"; }
sysd() { [ -n "${MLX_NO_SYSTEMD:-}" ] && return 0; systemctl "$@"; }
XBIN() { command -v xray 2>/dev/null || echo /usr/local/bin/xray; }

do_files() {
  [ -f "$ML/maxlogin_core.py" ] || { say "file sumber tidak ada di $ML"; return 1; }
  # python3 & jq dibutuhkan; pasang otomatis bila belum ada
  if ! command -v python3 >/dev/null || ! command -v jq >/dev/null; then
    say "memasang python3 & jq..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 jq >/dev/null 2>&1
  fi
  command -v python3 >/dev/null || { say "python3 tidak ada dan gagal dipasang otomatis"; return 1; }
  command -v jq >/dev/null || { say "jq tidak ada dan gagal dipasang otomatis"; return 1; }
  mkdir -p "$RT" /var/lib/vpn-script
  cp "$ML"/maxlogin_core.py "$ML"/maxlogin_service.py "$ML"/xray_adapter.py "$ML"/nginx-maxlogin*.inc "$RT"/
  [ -f "$CFG" ] || cp "$ML/maxlogin.json.example" "$CFG"
  if [ -z "${MLX_NO_SYSTEMD:-}" ]; then
    cp "$ML/vpn-maxlogin.service" /etc/systemd/system/vpn-maxlogin.service
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
    systemctl daemon-reload; systemctl enable vpn-maxlogin >/dev/null 2>&1
    systemctl restart vpn-maxlogin
  fi
}

# Sisipkan include (idempotent) di dua tempat: blok TLS (sebelum location ws pertama) dan
# blok port 80 (sebelum location ntls pertama). Sudah ada = dilewati (juga untuk pemasangan lama
# tanpa komentar penanda): diperiksa dari 3 baris tepat di atas location tujuan.
inc_before() { sed -n "$(( $2 > 3 ? $2 - 3 : 1 )),$(( $2 - 1 ))p" "$1" | grep -q "nginx-maxlogin.inc"; }

do_inject() {
  local f="$1" ln rc=0
  [ -f "$f" ] || return 1
  cp "$RT/nginx-maxlogin-http.inc" "$MAPF" 2>/dev/null || cp "$ML/nginx-maxlogin-http.inc" "$MAPF"
  ln=$(grep -nE '^[[:space:]]*location[[:space:]]+/(trojan-ws|vless-ws|vmess-ws)[[:space:]]*\{' "$f" | head -1 | cut -d: -f1)
  if [ -z "$ln" ]; then
    say "tidak menemukan location ws (TLS) di $f"; rc=1
  elif ! inc_before "$f" "$ln"; then
    sed -i "${ln}i\\    include $RT/nginx-maxlogin.inc; # maxlogin-tls\\n" "$f"
  fi
  ln=$(grep -nE '^[[:space:]]*location[[:space:]]+/(vless-ntls|vmess-ntls)[[:space:]]*\{' "$f" | head -1 | cut -d: -f1)
  if [ -n "$ln" ] && ! inc_before "$f" "$ln"; then
    sed -i "${ln}i\\    include $RT/nginx-maxlogin.inc; # maxlogin-ntls\\n" "$f"
  fi   # tidak ada blok ntls: dilewati (bukan galat)
  return $rc
}

do_nginx() {
  [ -f "$NGX" ] || { say "config Nginx tidak ada: $NGX"; return 1; }
  if [ -f "$MAPF" ]; then
    local cp_; cp_=$(mktemp); cp "$NGX" "$cp_"
    do_inject "$cp_" >/dev/null 2>&1; cmp -s "$cp_" "$NGX" && { rm -f "$cp_"; say "Nginx: include sudah lengkap"; return 0; }
    rm -f "$cp_"
  fi
  local bak; bak="$NGX.bak.maxlogin.$(date +%s)"
  cp "$NGX" "$bak"
  if do_inject "$NGX" && $NGX_TEST >/dev/null 2>&1; then
    $NGX_RELOAD >/dev/null 2>&1; say "Nginx: include terpasang (backup $bak)"; return 0
  fi
  say "Nginx GAGAL validasi, dipulihkan"; cp "$bak" "$NGX"; rm -f "$MAPF"; $NGX_TEST >/dev/null 2>&1; return 1
}

do_xray() {
  [ -f "$XCONF" ] || { say "config Xray tidak ada"; return 1; }
  python3 "$M" sync >/dev/null || return 1
  local had=0
  jq -e '.inbounds[]|select(.tag=="vless-ws-ml")' "$XCONF" >/dev/null 2>&1 && had=1
  python3 "$M" xray-sync >/dev/null || { say "xray-sync gagal"; return 1; }
  jq -e '.inbounds[]|select(.tag=="vless-ws-ml")' "$XCONF" >/dev/null 2>&1 || { say "inbound -ml tidak terbentuk di $XCONF"; return 1; }
  if ! "$(XBIN)" run -test -c "$XCONF" >/dev/null 2>&1; then
    local b; b=$(ls -t "$XCONF".ml-bak.* 2>/dev/null | head -1)
    [ -n "$b" ] && cp "$b" "$XCONF"
    say "config Xray TIDAK valid, dipulihkan"; return 1
  fi
  if grep -q '"xray_manage"' "$CFG"; then
    sed -i 's/"xray_manage"[[:space:]]*:[[:space:]]*false/"xray_manage": true/' "$CFG"
  else
    sed -i 's/^{/{\n  "xray_manage": true,/' "$CFG"
  fi
  sysd restart vpn-maxlogin
  if [ "$had" = 1 ]; then
    python3 "$M" xray-sync --runtime >/dev/null; say "Xray: akun berlimit dipindah lewat API (tanpa restart)"
  else
    sysd restart xray; say "Xray: inbound -ml ditambahkan, Xray di-restart sekali"
  fi
}

live() { grep -qs "nginx-maxlogin.inc" "$NGX" 2>/dev/null || grep -Eqs '"xray_manage"[[:space:]]*:[[:space:]]*true' "$CFG" 2>/dev/null; }

case "${1:-}" in
  on)
    do_files && do_nginx && do_xray || { say "GAGAL: lihat pesan di atas (tidak ada yang diaktifkan penuh)"; exit 1; }
    touch "$MARK"; say "AKTIF" ;;
  off)
    rm -f "$MARK"
    if [ -f "$M" ]; then
      sed -i 's/"xray_manage"[[:space:]]*:[[:space:]]*true/"xray_manage": false/' "$CFG" 2>/dev/null
      python3 "$M" xray-restore >/dev/null 2>&1
      sysd disable --now vpn-maxlogin >/dev/null 2>&1
      sysd restart xray
    fi
    say "DIMATIKAN. Akun berlimit kembali memakai link biasa (kirim ulang link tanpa token ke pembeli)." ;;
  update)
    do_files || exit 1
    if [ -f "$MARK" ] || live || [ "${MAXLOGIN_AUTO:-0}" = 1 ]; then
      touch "$MARK"; do_nginx; do_xray
      say "diperbarui (MaxLogin aktif)"
    else
      say "file terpasang, belum diaktifkan. Aktifkan: bash $ML/maxlogin-xray.sh on"
      sysd disable --now vpn-maxlogin >/dev/null 2>&1
    fi ;;
  inject) do_inject "${2:-$NGX}" ;;
  status)
    echo "tanda aktif : $([ -f "$MARK" ] && echo ya || echo tidak)"
    echo "service     : $(systemctl is-active vpn-maxlogin 2>/dev/null)"
    echo "nginx       : $(grep -qs nginx-maxlogin.inc "$NGX" && echo include-ada || echo include-tidak-ada)"
    echo "xray_manage : $(grep -Eqs '"xray_manage"[[:space:]]*:[[:space:]]*true' "$CFG" && echo true || echo false)"
    [ -f "$M" ] && python3 "$M" show 2>/dev/null ;;
  *) echo "pakai: $0 on|off|update|status|inject FILE"; exit 1 ;;
esac
