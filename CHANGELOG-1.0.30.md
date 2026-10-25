# 1.0.30
MaxLogin Xray (batas perangkat via token di link) ikut terpasang oleh installer dan update.
- Instalasi baru: aktif otomatis (`addon/maxlogin/maxlogin-xray.sh on` dipanggil install.sh).
- Update (menu 10 / run_update): paket MaxLogin diunduh dan diperbarui. VPS lama TIDAK diaktifkan otomatis
  (link lama pembeli akan berhenti bekerja). Aktifkan: `bash /etc/vpn-script/addon/maxlogin/maxlogin-xray.sh on`.
  Yang sudah aktif (include Nginx / xray_manage) tetap aktif dan diperbarui.
- `maxlogin-xray.sh off`: matikan, akun berlimit dikembalikan ke inbound lama.
- Nginx dibuat ulang oleh script (regenerate_nginx_conf): include MaxLogin disisipkan lagi otomatis.
- lib.sh: buat/edit/hapus/aktifkan-ulang akun memanggil sinkron MaxLogin; link otomatis bertoken per perangkat.
- Log MaxLogin anti-banjir + logrotate; tampilan user online tidak lagi ganda untuk akun senama di beberapa protokol.
- Menu baru: [21] Web Panel (pasang panel bila belum ada; bila sudah: update / pasang ulang), [22] Rebuild OS VPS (sebelumnya 21).
  File baru: menu/panel.sh (masuk UPDATE_FILES dan daftar unduhan install.sh).
- Perbaikan: install.sh memasang python3; maxlogin-xray.sh memasang python3/jq otomatis bila belum ada (VPS minimal gagal mengaktifkan MaxLogin saat install pertama).
- nTLS (port 80) kini didukung untuk akun berlimit: link `.../vless-ntls/<token>` dan `.../vmess-ntls/<token>` (token & slot sama dengan jalur TLS). Include Nginx dipasang juga di blok port 80. gRPC tetap tidak tersedia untuk akun berlimit.
- ml_tokens mencoba ulang bila token kosong untuk akun berlimit (mencegah link gRPC polos muncul sesaat saat akun dibuat).
