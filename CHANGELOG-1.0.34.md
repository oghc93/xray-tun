# 1.0.34
- Server Message (banner) Dropbear tampil: Dropbear baru mengabaikan DROPBEAR_BANNER, jadi opsi `-b /etc/vpn-script/banner.txt` ditambahkan ke DROPBEAR_EXTRA_ARGS (install.sh + `ensure_dropbear_banner` di lib.sh, otomatis saat update; Dropbear di-restart hanya bila berubah).
- Banner bawaan diganti ke tampilan baru (1800 byte; batas Dropbear 2000 byte).
- Banner buatan sendiri di /etc/vpn-script/banner.txt tidak ditimpa saat update.
