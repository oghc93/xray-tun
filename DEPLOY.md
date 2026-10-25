# Cara Deploy ke Server yang SUDAH JALAN (bukan install baru)

Paket ini isinya seluruh source All-Tun + patch maxlogin sudah menyatu
langsung di `lib.sh` dan `addon/`. Fresh install VPS baru otomatis dapat
semuanya lewat `install.sh`. Untuk server yang sudah jalan, timpa manual:

```bash
# 1. Backup dulu
cp -r /etc/vpn-script /etc/vpn-script.bak-$(date +%s)

# 2. Salin file yang sudah dipatch
cp lib.sh /etc/vpn-script/lib.sh
cp addon/ssh-maxlogin.sh addon/dropbear-fastkick.sh addon/xray-maxlogin-daemon.sh /etc/vpn-script/addon/
cp addon/enable-ssl-multiplex.sh /etc/vpn-script/addon/enable-ssl-multiplex.sh   # cuma kalau kamu pakai fitur ini
chmod +x /etc/vpn-script/addon/*.sh

# 3. Hapus limiter lama (kalau masih ada)
rm -f /etc/vpn-script/addon/session-limiter.sh
rm -f /etc/vpn-script/addon/xray-device-limiter.sh
rm -f /etc/vpn-script/addon/quota-limiter.sh
crontab -l | grep -v "session-limiter.sh\|xray-device-limiter.sh\|quota-limiter.sh" | crontab -

# 4. Pasang PAM maxlogins (OpenSSH)
bash /etc/vpn-script/addon/ssh-maxlogin.sh install

# 5. Pasang systemd service
cp systemd/dropbear-fastkick.service systemd/xray-maxlogin.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now dropbear-fastkick.service
systemctl enable --now xray-maxlogin.service

# 6. Sinkron limit ke akun SSH yang sudah ada
while IFS='|' read -r user pass exp created limit quota; do
    [[ -z "$user" ]] && continue
    bash /etc/vpn-script/addon/ssh-maxlogin.sh set "$user" "${limit:-2}"
done < /etc/vpn-script/db/ssh.db

# 7. Kalau kamu pakai multiplex-443, jalankan ulang addon-nya biar
#    haproxy.cfg ikut update ke backend OpenSSH:
[ -f /etc/vpn-script/.multiplex-443-active ] && bash /etc/vpn-script/addon/enable-ssl-multiplex.sh
```

## Setelah itu, WAJIB TES dari client:
- WS nTLS (path `/ssh-ws`, port 80/8880/dst) -- harus tetap ke Dropbear
- WS TLS (path `/ssh-ws` atau `/ssh-ws-ssh`, port 443) -- harus ke OpenSSH
- SSH-SSL (Stunnel 777 dan/atau multiplex 443) -- harus ke OpenSSH

## Cek status:
```bash
systemctl status dropbear-fastkick
systemctl status xray-maxlogin
tail -f /var/log/vpn-dropbear-fastkick.log /var/log/vpn-xray-maxlogin.log
```

## Ringkasan arsitektur akhir:
| Jalur | Backend | Jenis Limit |
|---|---|---|
| WS nTLS (80/8880/8080/2080/2082) | Dropbear | Reaktif (dropbear-fastkick, poll 5s + cooldown 30s) |
| WS TLS (443) + SSL (Stunnel/multiplex) | OpenSSH | **Preventive** (PAM maxlogins) |
| VMess/VLess/Trojan/SS | Xray | Reaktif (xray-maxlogin-daemon, poll 5s + cooldown 30s) |
