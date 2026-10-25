# cocote (Go) — tahap 1: proxy SSH-WS

Pengganti `ws-dropbear` dan `ws-openssh` (Python, satu thread per koneksi).
Perilaku sama: header `X-Real-Host`, `X-Split`, `X-Pass`, balasan `101`, hanya
boleh ke 127.0.0.1/localhost, idle timeout 180 detik, dan khusus ws-openssh
membuang "HTTP/1.1 200 OK" palsu dari payload split.

## Build
Jalankan workflow **build-cocote-go** di GitHub Actions (tab Actions → Run
workflow). Hasil: `cocote-linux-amd64` dan `cocote-linux-arm64` (artifact).

## Pasang manual di server (uji dulu, aman)
    install -m755 cocote-linux-amd64 /usr/local/bin/cocote
    systemctl edit ws-dropbear   # isi: [Service]
                                 #      ExecStart=
                                 #      ExecStart=/usr/local/bin/cocote ws-dropbear 2095
    systemctl restart ws-dropbear
Ulangi untuk ws-openssh (port 2093). Kembali ke Python: hapus override-nya.
