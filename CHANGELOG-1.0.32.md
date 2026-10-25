# 1.0.32
- Perbaikan: akun ganda (username sama) bisa membuat Xray gagal start ("User ... already exists").
  - API/panel kini menolak username yang sudah ada; create_* menolak duplikat.
  - delete_trojan menghapus berdasarkan email (bukan password); delete_ss menangani banyak password.
