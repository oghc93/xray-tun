#!/bin/bash
# ============================================================
# addon/quota-limiter.sh
# Pencatat pemakaian PERMANEN per akun + penegak kuota.
#
#  - Dijalankan cron tiap menit (/etc/cron.d/vpn-quota-limiter).
#  - Counter Xray (Stats API) dan iptables SSH reset kalau Xray
#    direstart / VPS reboot. Script ini menambahkan selisihnya ke
#    buku besar $DB_DIR/usage.db sehingga total pemakaian tidak
#    hilang. Format: JENIS|USER|TOTAL_BYTE|COUNTER_TERAKHIR
#    (JENIS: x = Xray, s = SSH).
#  - Akun yang punya batas kuota (>0 MB) dan sudah melewatinya
#    DI-SUSPEND (bukan dihapus). Naikkan kuota lewat "Edit Limit"
#    atau perpanjang akun untuk mengaktifkannya lagi.
#  - Matikan penegakan (pencatatan tetap jalan):
#      touch /etc/vpn-script/.quota-enforce-off
# ============================================================
SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh" 2>/dev/null || true
[[ "$(type -t list_ssh)" == function ]] || exit 0

mkdir -p /run 2>/dev/null
exec 9>/run/vpn-quota-limiter.lock
flock -n 9 || exit 0

LEDGER="$DB_DIR/usage.db"
[[ -f "$LEDGER" ]] || : > "$LEDGER"
CUR=$(mktemp); VALID=$(mktemp); NEW=$(mktemp)
trap 'rm -f "$CUR" "$VALID" "$NEW"' EXIT

# ── 1) kumpulkan counter saat ini ───────────────────────────
# Xray: satu query untuk semua user (uplink + downlink)
if command -v xray >/dev/null 2>&1; then
  xray_stat_query "user>>>" 2>/dev/null | jq -r '
    [.stat[]? | select(.name|test("^user>>>.+>>>traffic>>>(uplink|downlink)$"))
     | {u:(.name|split(">>>")[1]), v:((.value // 0)|tonumber)}]
    | group_by(.u)[] | "x|\(.[0].u)|\(map(.v)|add)"' 2>/dev/null >> "$CUR"
fi
# SSH: counter iptables per akun (chain dibuat kalau belum ada, termasuk akun tanpa batas kuota)
while IFS='|' read -r user _; do
  [[ -z "$user" ]] && continue
  echo "s|$user" >> "$VALID"
  id "$user" >/dev/null 2>&1 || continue
  chain=$(ssh_quota_chain "$user")
  iptables -L "$chain" -n >/dev/null 2>&1 || setup_ssh_quota_accounting "$user" >/dev/null 2>&1
  b=$(iptables -L "$chain" -v -x -n 2>/dev/null | awk '/RETURN/{s+=$2} END{printf "%.0f", s+0}')
  [[ "$b" =~ ^[0-9]+$ ]] && echo "s|$user|$b" >> "$CUR"
done < <(list_ssh)
for l in list_vmess list_vless list_trojan list_ss; do
  while IFS='|' read -r user _; do [[ -n "$user" ]] && echo "x|$user" >> "$VALID"; done < <($l)
done

# ── 2) perbarui buku besar (tambah selisih, tahan reset counter) ──
awk -F'|' -v OFS='|' '
  FILENAME==ARGV[1] { t[$1"|"$2]=$3; l[$1"|"$2]=$4; next }
  FILENAME==ARGV[2] { c=$3+0; k=$1"|"$2
                      if (k in l) { if (c>=l[k]) t[k]+=c-l[k]; else t[k]+=c } else { t[k]=c }
                      l[k]=c; next }
  FILENAME==ARGV[3] { ok[$1"|"$2]=1; next }
  END { for (k in t) if (k in ok) { split(k,a,"|"); printf "%s|%s|%.0f|%.0f\n", a[1],a[2],t[k],l[k] } }
' "$LEDGER" "$CUR" "$VALID" > "$NEW" && cat "$NEW" > "$LEDGER"

# ── 3) penegakan kuota ──────────────────────────────────────
[[ -f "$SCRIPT_DIR/.quota-enforce-off" ]] && exit 0
declare -A USED=()
while IFS='|' read -r k u t _; do USED["$k|$u"]="$t"; done < "$LEDGER"
RELOAD=0

suspend_notify() {
  local proto="$1" user="$2" quota_mb="$3" used_mb="$4"
  tg_notify "⛔ <b>Kuota habis</b>: ${user} (${proto}) terpakai ${used_mb} MB dari ${quota_mb} MB. Akun disuspend." limit 2>/dev/null
}
check_xray() {   # proto prefix quota_field_user quota
  local proto="$1" prefix="$2" user="$3" quota="$4" t used_mb
  [[ "$quota" =~ ^[0-9]+$ && "$quota" -gt 0 ]] || return 0
  is_quota_disabled "$proto" "$user" && return 0
  t="${USED[x|$user]:-0}"; used_mb=$(( t / 1048576 ))
  (( used_mb >= quota )) || return 0
  xray_disable_client "$prefix" "$user"
  mark_quota_disabled "$proto" "$user"
  RELOAD=1
  suspend_notify "$proto" "$user" "$quota" "$used_mb"
}
while IFS='|' read -r user _ _ _ _ quota; do [[ -n "$user" ]] && check_xray vmess  vmess  "$user" "$quota"; done < <(list_vmess)
while IFS='|' read -r user _ _ _ _ quota; do [[ -n "$user" ]] && check_xray vless  vless  "$user" "$quota"; done < <(list_vless)
while IFS='|' read -r user _ _ _ _ quota; do [[ -n "$user" ]] && check_xray trojan trojan "$user" "$quota"; done < <(list_trojan)
while IFS='|' read -r user _ _ _ _ _ quota; do [[ -n "$user" ]] && check_xray ss    "ss-"  "$user" "$quota"; done < <(list_ss)

while IFS='|' read -r user _ _ _ _ quota; do
  [[ -n "$user" && "$quota" =~ ^[0-9]+$ && "$quota" -gt 0 ]] || continue
  is_quota_disabled ssh "$user" && continue
  used_mb=$(( ${USED[s|$user]:-0} / 1048576 ))
  (( used_mb >= quota )) || continue
  usermod -L "$user" 2>/dev/null
  pkill -KILL -u "$user" 2>/dev/null
  mark_quota_disabled ssh "$user"
  suspend_notify ssh "$user" "$quota" "$used_mb"
done < <(list_ssh)

if (( RELOAD )); then
  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null
fi
exit 0
