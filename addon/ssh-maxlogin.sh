#!/bin/bash
# ============================================================
# addon/ssh-maxlogin.sh
# PAM maxlogins (PREVENTIVE) untuk OpenSSH -- menjaga jalur
# WS-TLS (port 443) & SSL (Stunnel/multiplex). Dipanggil otomatis
# dari create_ssh()/edit_ssh_limits()/delete_ssh() di lib.sh.
# ============================================================
LIMITS_DIR="/etc/security/limits.d"
PAM_SSHD="/etc/pam.d/sshd"
SSHD_CONFIG="/etc/ssh/sshd_config"

install_pam_maxlogin() {
    if ! grep -qE "^session\s+required\s+pam_limits\.so" "$PAM_SSHD" 2>/dev/null; then
        echo "session required pam_limits.so" >> "$PAM_SSHD"
    fi
    grep -qE "^UsePAM" "$SSHD_CONFIG" && sed -i 's/^UsePAM.*/UsePAM yes/' "$SSHD_CONFIG" \
        || echo "UsePAM yes" >> "$SSHD_CONFIG"

    # Samakan pesan koneksi dengan Dropbear (banner.txt yang sama)
    if [[ -f /etc/vpn-script/banner.txt ]]; then
        if grep -qE "^Banner" "$SSHD_CONFIG"; then
            sed -i 's|^Banner.*|Banner /etc/vpn-script/banner.txt|' "$SSHD_CONFIG"
        else
            echo "Banner /etc/vpn-script/banner.txt" >> "$SSHD_CONFIG"
        fi
    fi
    mkdir -p "$LIMITS_DIR"
    if sshd -t 2>/dev/null; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
        echo "[OK] PAM maxlogins aktif untuk OpenSSH."
    else
        echo "[ERROR] sshd_config invalid! Cek manual sebelum lanjut."
        exit 1
    fi
}

set_ssh_maxlogin() {
    local username="$1" max="${2:-2}"
    [[ "$max" =~ ^[0-9]+$ ]] || { echo "[ERROR] max harus angka."; exit 1; }
    if [[ "$max" -eq 0 ]]; then
        rm -f "$LIMITS_DIR/vpn-${username}.conf"
        return
    fi
    # Batas PAM = limit+1: sesi ke-(limit+1) sengaja masih boleh masuk supaya
    # terdeteksi daemon dan kena penalti bertingkat; sesi berikutnya ditolak.
    local pam_max=$((max+1))
    mkdir -p "$LIMITS_DIR"
    cat > "$LIMITS_DIR/vpn-${username}.conf" <<EOF
# Auto-generated oleh ssh-maxlogin.sh -- JANGAN edit manual.
# Akun VPN: $username
$username hard maxlogins $pam_max
$username soft maxlogins $pam_max
EOF
}

remove_ssh_maxlogin() {
    rm -f "$LIMITS_DIR/vpn-${1}.conf"
}

case "$1" in
    install) install_pam_maxlogin ;;
    set)     set_ssh_maxlogin "$2" "$3" ;;
    remove)  remove_ssh_maxlogin "$2" ;;
    *) echo "Usage: $0 {install|set username max|remove username}"; exit 1 ;;
esac
