# 1.0.31
MaxLogin Xray: dua mode, dipilih otomatis dari angka limit akun.
- Limit di bawah `shared_min_limit` (bawaan 10): mode PER-PERANGKAT. N link (`-dev1..N`), tiap link satu asal pada satu waktu. Untuk akun jualan.
- Limit >= `shared_min_limit`: mode LINK TUNGGAL. Satu link (`-shared`) boleh dipakai hingga N asal jaringan berbeda bersamaan; asal ke-(N+1) ditolak `device_limit`, asal lama tidak diputus. Untuk akun sample/gratis berlimit besar (mis. 50+).
- `shared_ttl_seconds` (bawaan 300): asal di mode tunggal dianggap pergi bila tak ada koneksi baru selama itu.
- Ubah limit melewati ambang otomatis mengganti mode (token slot 0 tetap, ikatan asal dilepas). `shared_min_limit: 0` mematikan mode tunggal.
- DB lama dimigrasi otomatis (kolom `mode`, tabel `origins`). Tes: unit 29, integrasi Nginx+Xray 27.
