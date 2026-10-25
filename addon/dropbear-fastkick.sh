#!/bin/bash
# ============================================================
# addon/dropbear-fastkick.sh  (penegak limit device SSH, semua jalur)
# Poll 5 detik. Menghitung sesi akun (Dropbear + OpenSSH). Kalau melebihi
# limit: akun dikunci + semua sesi diputus selama masa penalti bertingkat
# (2 menit -> 30 menit -> 2 jam -> 24 jam, lihat penalty_* di lib.sh),
# lalu dibuka lagi otomatis. Nama file dipertahankan supaya service lama
# (dropbear-fastkick.service) tetap jalan tanpa perubahan.
# ============================================================
SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh"

POLL=5
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log "ssh limit-device dimulai (poll=${POLL}s, penalti bertingkat)"

ssh_exp_valid() {   # user -> 0 jika akun belum kedaluwarsa
  local exp
  exp=$(grep "^$1|" "$DB_SSH" 2>/dev/null | head -1 | cut -d'|' -f3)
  [[ -z "$exp" ]] && return 1
  local e; e=$(date -d "$exp" +%s 2>/dev/null) || return 0
  (( e >= $(date +%s) ))
}

release_penalties() {
    local name kind user
    while read -r name; do
        [[ -z "$name" ]] && continue
        kind=${name%%_*}; user=${name#*_}
        [[ "$kind" == "ssh" ]] || continue
        penalty_release_mark ssh "$user"
        is_quota_disabled ssh "$user" && continue
        if ssh_exp_valid "$user"; then
            usermod -U "$user" 2>/dev/null
            log "$user: masa putus selesai, akun dibuka lagi"
        fi
    done < <(penalty_expired_files)
}

while true; do
    while IFS='|' read -r user pass exp created limit quota; do
        [[ -z "$user" ]] && continue
        limit="${limit:-$SESSION_LIMIT_DEFAULT}"
        [[ "$limit" =~ ^[0-9]+$ ]] || continue
        [[ "$limit" -eq 0 ]] && continue
        penalty_exempt "$user" && continue
        penalty_active ssh "$user" && continue

        # Satu proses dropbear/sshd milik user = satu sesi/perangkat
        count=$(pgrep -u "$user" -x 'dropbear|sshd' 2>/dev/null | wc -l)
        if [[ "$count" -le "$limit" ]]; then penalty_grace_ok ssh "$user" 0; continue; fi
        penalty_grace_ok ssh "$user" 1 || continue

        res=$(penalty_apply ssh "$user"); strikes=${res% *}; dur=${res#* }
        log "$user: sesi=$count > limit=$limit -> putus $(penalty_fmt "$dur") (pelanggaran ke-$strikes)"
        usermod -L "$user" 2>/dev/null
        pkill -KILL -u "$user" 2>/dev/null

        tg_notify "🚫 <b>Limit Device Terlampaui (SSH)</b>

Username: <code>$user</code>
Sesi aktif: <code>$count</code> (limit: <code>$limit</code>)
Pelanggaran ke: <code>$strikes</code>
Aksi: akun diputus <code>$(penalty_fmt "$dur")</code>, lalu aktif lagi otomatis" "limit"
    done < <(list_ssh)
    release_penalties
    sleep "$POLL"
done
