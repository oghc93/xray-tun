# Cocote Pannel

Script all-in-one untuk mengelola VPS tunnel / VPN lewat satu menu di terminal: **SSH, SSH-WS, VMess, VLess, Trojan, Shadowsocks, OpenVPN**, lengkap dengan Nginx, HAProxy, Dropbear, bot Telegram, dan Backup & Restore.

Panel web (opsional) ada di repo terpisah: [`oghc93/cocote-3x-ui`](https://github.com/oghc93/cocote-3x-ui).

## Fitur

- Satu menu untuk semua protokol: buat, lihat, perpanjang, dan hapus akun (SSH / SSH-WS, VMess WS, VLess WS, Trojan WS/gRPC, Shadowsocks)
- **Multiplex port 443**: SSH-WS TLS, Xray, SSH-SSL, dan OpenVPN berbagi satu port. HAProxy memilah koneksi berdasarkan isi payload, jadi SNI bebas
- **OpenVPN**: TCP 1194 dan UDP 2200, plus OpenVPN lewat WebSocket (`/ovpn-ws`, port 80 dan 443). Akun OpenVPN = akun SSH yang sama
- **Backup & Restore lewat bot Telegram**: backup harian otomatis, `/backup` dan `/restore` langsung dari chat
- Notifikasi akun lewat bot Telegram
- Batas sesi per akun (SSH, Dropbear, Xray) dan kuota akun
- Blokir torrent, BBR & IPv6, monitor layanan dan system info
- Ganti domain dan perpanjang SSL (Let's Encrypt via acme.sh) dari menu
- Update script dan panel dari menu, tanpa install ulang

## Syarat

- VPS baru dengan Debian atau Ubuntu (memakai `apt`), akses `root`
- Domain yang sudah diarahkan (A record) ke IP VPS
- Port 80 dan 443 terbuka (diperlukan untuk penerbitan SSL)

## Install

```bash
apt update -y && apt install -y wget curl && wget -q https://raw.githubusercontent.com/oghc93/xray-tun/main/install.sh -O install.sh && chmod +x install.sh && bash install.sh
```

Installer akan meminta:

1. **Domain** yang sudah mengarah ke IP VPS
2. **Bot Telegram** (opsional): token dari @BotFather dan Chat ID dari @userinfobot. Boleh dikosongkan dan diisi nanti lewat menu **19 Backup & Restore**

Setelah selesai, buka menu dengan:

```bash
vpn
```

## Menu

| No | Menu | No | Menu |
|----|------|----|------|
| 01 | SSH / SSH-WS | 11 | Status Layanan |
| 02 | VMess WS | 12 | System Info |
| 03 | VLess WS | 13 | Bot Telegram |
| 04 | Trojan WS/gRPC | 14 | Update Panel Web |
| 05 | Shadowsocks | 15 | BBR & IPv6 |
| 06 | Nginx | 16 | OpenVPN |
| 07 | Dropbear | 17 | Keamanan |
| 08 | HAProxy SSL | 18 | Monitor & Tools |
| 09 | Change Domain | 19 | Backup & Restore |
| 10 | Update Script | 20 | Uninstall |
| | | 21 | Web Panel (pasang/update panel) |
| | | 22 | Rebuild OS VPS |

## Update

```text
vpn → 10 (Update Script)     # script
vpn → 14 (Update Panel Web)  # panel web
```

Update hanya mengunduh file script dan tidak mengubah akun atau konfigurasi yang sudah berjalan. Setelah update, jalankan menu 10 sekali lagi kalau ada langkah baru yang belum aktif: update pertama masih memakai kode lama yang sudah ada di memori.

Cek versi terpasang:

```bash
cat /etc/vpn-script/VERSION
```

## OpenVPN

- Pasang dari `vpn → 16 → 01`. Port bawaan TCP 1194 dan UDP 2200
- File client dibuat di `/etc/vpn-script/ovpn/`: `vpn-tcp.ovpn`, `vpn-udp.ovpn`, `vpn-ws.ovpn` (nTLS 80), `vpn-wss.ovpn` (TLS 443). Bisa dikirim ke Telegram dari menu OpenVPN
- Login memakai username dan password akun SSH yang sama, batas 1 sesi per akun
- Mode WebSocket / SNI di port 443 dipakai lewat aplikasi yang mendukung payload dan SNI (mis. HTTP Custom). Payload:

  ```text
  GET /ovpn-ws HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]
  ```

- Agar OpenVPN ikut di port 443, jalankan sekali setelah install OpenVPN:

  ```bash
  bash /etc/vpn-script/addon/enable-ssl-multiplex.sh enable
  ```

- Nama service systemd: `openvpn-server@vpn-script-tcp` dan `openvpn-server@vpn-script-udp`

## Backup & Restore (Telegram)

- Isi token dan Chat ID di `vpn → 19`, lalu aktifkan bot
- Backup otomatis harian pukul 03:00, file dikirim ke chat Telegram-mu
- Perintah bot: `/backup`, `/restore` (lalu kirim file backup), `/cancel`
- **File backup berisi data rahasia** (akun, kunci, sertifikat). Simpan hanya di chat pribadi dan jangan dibagikan

## Struktur repo

```text
xray-tun/
├── install.sh            ← installer
├── lib.sh                ← fungsi bersama + daftar file untuk update
├── menu.sh               ← menu utama (perintah: vpn)
├── VERSION
├── menu/                 ← submenu (sshws, vmess, vless, trojan, ss, openvpn, backup, ...)
├── addon/                ← komponen tambahan (multiplex 443, maxlogin, torrent-block, tg-backup.py, ...)
└── systemd/              ← unit systemd tambahan
```

## Pemecahan masalah

| Gejala | Penyebab / solusi |
|--------|-------------------|
| Browser menampilkan "tidak aman" di panel | Sertifikat cadangan (self-signed) terpakai. Terbitkan ulang SSL dari menu **09 Change Domain** atau `acme.sh --issue` dengan `--server letsencrypt` |
| Panel menampilkan 404 setelah multiplex di-apply | Jalankan Update Script (menu 10) dan Update Panel Web (menu 14). Blok panel sekarang disimpan di `/etc/nginx/snippets/vpn-panel-ui.conf` |
| OpenVPN tidak konek | Cek `systemctl is-active openvpn-server@vpn-script-tcp openvpn-server@vpn-script-udp` dan pastikan multiplex 443 aktif (`grep -c multiplex_ovpn /etc/haproxy/haproxy.cfg` menghasilkan `2`) |
| Installer menolak domain | Pastikan A record mengarah ke IP VPS. Bila memakai Cloudflare (awan oranye), IP akan berbeda, pilih lanjut |

## Keamanan

- Jangan membagikan token GitHub atau token bot Telegram. Jika pernah terbuka di chat atau screenshot, segera revoke
- Jangan commit file rahasia ke repo (`.env`, kunci, sertifikat, file backup)

## Lisensi dan kredit

Dikelola oleh [@oghc93](https://github.com/oghc93). Bagian script memakai komponen open source (Xray-core, Nginx, HAProxy, Dropbear, OpenVPN, acme.sh).
