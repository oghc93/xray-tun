#!/bin/bash
# ============================================================
# addon/real-ip-fix.sh
# Saat multiplex 443 aktif (HAProxy -> Nginx 127.0.0.1:8443), Nginx hanya
# melihat 127.0.0.1 sehingga Xray tidak tahu IP asli pemakai (limit device
# Xray tidak bisa jalan). Skrip ini menyalakan PROXY protocol HAProxy->Nginx
# dan memakainya sebagai IP asli di Nginx. Idempotent, ada backup+rollback.
# ============================================================
HAPROXY_CONF="${HAPROXY_CONF:-/etc/haproxy/haproxy.cfg}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/xray.conf}"
MARKER="${MARKER:-/etc/vpn-script/.multiplex-443-active}"
DRY="${REALIP_NO_RELOAD:-0}"

[[ -f "$MARKER" ]] || { echo "[INFO] multiplex 443 tidak aktif, tidak perlu."; exit 0; }
[[ -f "$HAPROXY_CONF" && -f "$NGINX_CONF" ]] || { echo "[SKIP] config HAProxy/Nginx tidak ditemukan."; exit 0; }

ha_done=false; ng_done=false
grep -qE "server nginx-internal .*send-proxy" "$HAPROXY_CONF" && ha_done=true
grep -qE "listen 127.0.0.1:8443 .*proxy_protocol" "$NGINX_CONF" && ng_done=true
if $ha_done && $ng_done; then echo "[OK] IP asli sudah diteruskan (HAProxy -> Nginx)."; exit 0; fi

ts=$(date +%Y%m%d%H%M%S)
cp "$HAPROXY_CONF" "$HAPROXY_CONF.realip.$ts"; cp "$NGINX_CONF" "$NGINX_CONF.realip.$ts"

if ! $ha_done; then
  sed -i -E '/^\s*server nginx-internal 127\.0\.0\.1:8443/ s/$/ send-proxy-v2 check-send-proxy/' "$HAPROXY_CONF"
fi
if ! $ng_done; then
  sed -i -E 's|^(\s*)listen 127\.0\.0\.1:8443 ssl http2;|\1listen 127.0.0.1:8443 ssl http2 proxy_protocol;\n\1set_real_ip_from 127.0.0.1;\n\1real_ip_header proxy_protocol;|' "$NGINX_CONF"
fi

rollback() {
  echo "[GAGAL] $1 -> rollback"
  cp "$HAPROXY_CONF.realip.$ts" "$HAPROXY_CONF"; cp "$NGINX_CONF.realip.$ts" "$NGINX_CONF"
  exit 1
}
haproxy -c -f "$HAPROXY_CONF" >/dev/null 2>&1 || rollback "haproxy.cfg tidak valid"
${NGINX_TEST_CMD:-nginx -t} >/dev/null 2>&1 || rollback "nginx config tidak valid"
grep -qE "listen 127.0.0.1:8443 .*proxy_protocol" "$NGINX_CONF" || rollback "pola listen 8443 tidak ditemukan di Nginx"
grep -qE "server nginx-internal .*send-proxy" "$HAPROXY_CONF" || rollback "pola server nginx-internal tidak ditemukan di HAProxy"

if [[ "$DRY" != "1" ]]; then
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
fi
echo "[OK] IP asli pemakai kini diteruskan ke Nginx/Xray (backup: *.realip.$ts)"
