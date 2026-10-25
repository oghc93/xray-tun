# 1.0.35
- Banner (Server Message) yang sama juga dipakai OpenSSH (jalur WS-TLS 443 & SSL): `ensure_ssh_banner` di lib.sh, otomatis saat install & update.
- Aman: drop-in `/etc/ssh/sshd_config.d/00-vpn-banner.conf` (atau baris di atas sshd_config bila tanpa Include), dicek `sshd -t`, rollback otomatis bila gagal, `reload` (sesi aktif tidak putus).
