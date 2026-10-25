#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tg-backup.py  -  Backup & Restore akun SSH-WS / Xray / OVPN lewat bot Telegram

Pemakaian:
  python3 tg-backup.py backup   -> buat backup lalu kirim ke Telegram
  python3 tg-backup.py bot      -> jalankan bot (menerima /backup, /restore, file backup)

Config: /etc/tg-backup.conf
  BOT_TOKEN=123456:ABC...
  ADMIN_ID=123456789
"""
import io
import json
import os
import socket
import subprocess
import sys
import tarfile
import time
import urllib.request

CONF = "/etc/tg-backup.conf"
API_BASE = os.environ.get("TG_API", "https://api.telegram.org")

# ---------------------------------------------------------------------------
# Folder yang di-backup (yang tidak ada otomatis dilewati).
# SESUAIKAN dengan lokasi data akun di script kamu.
# ---------------------------------------------------------------------------
BACKUP_PATHS = [
    "/etc/vpn-script",        # db akun (db/*.db), domain, .pro-config, flag kuota
    "/etc/xray",              # config.json (daftar client) + sertifikat
    "/etc/openvpn",           # opsional: hanya ada kalau OVPN terpasang
    "/var/www/html/ovpn",     # opsional: file .ovpn client
]

# Hanya path berawalan ini yang boleh di-restore (pengaman)
ALLOWED_PREFIXES = tuple(p.lstrip("/") for p in BACKUP_PATHS)

# Service yang di-restart setelah restore (yang tidak ada dilewati)
RESTART_SERVICES = ["xray", "xray-maxlogin-daemon", "openvpn", "openvpn@server"]

RESTORE_WAIT = 300  # detik menunggu file setelah /restore


# ---------------------------------------------------------------------------
# Config & Telegram helper
# ---------------------------------------------------------------------------
def read_kv(path):
    conf = {}
    if not os.path.exists(path):
        return conf
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip().strip('"').strip("'")
    return conf


def load_conf():
    conf = read_kv(CONF)
    # Fallback: pakai bot Telegram yang sudah diisi di menu panel
    if not conf.get("BOT_TOKEN") or not conf.get("ADMIN_ID"):
        pro = read_kv("/etc/vpn-script/.pro-config")
        conf.setdefault("BOT_TOKEN", pro.get("TELEGRAM_BOT_TOKEN", ""))
        conf.setdefault("ADMIN_ID", pro.get("TELEGRAM_CHAT_ID", ""))
    if not conf.get("BOT_TOKEN") or not conf.get("ADMIN_ID"):
        sys.exit("BOT_TOKEN / ADMIN_ID belum diisi di " + CONF)
    return conf


CONF_DATA = {}


def api(method, payload=None, timeout=40):
    url = "%s/bot%s/%s" % (API_BASE, CONF_DATA["BOT_TOKEN"], method)
    data = json.dumps(payload or {}).encode()
    req = urllib.request.Request(url, data, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def send_text(text, chat_id=None):
    try:
        api("sendMessage", {"chat_id": chat_id or CONF_DATA["ADMIN_ID"], "text": text})
        return True
    except Exception as e:
        print("gagal kirim pesan:", e, flush=True)
        return False


def send_file(path, caption=""):
    url = "%s/bot%s/sendDocument" % (API_BASE, CONF_DATA["BOT_TOKEN"])
    r = subprocess.run(
        ["curl", "-s", "-F", "chat_id=" + CONF_DATA["ADMIN_ID"],
         "-F", "caption=" + caption, "-F", "document=@" + path, url],
        capture_output=True, text=True)
    try:
        return json.loads(r.stdout).get("ok", False)
    except Exception:
        return False


def download_file(file_id, dest):
    info = api("getFile", {"file_id": file_id})
    if not info.get("ok"):
        raise RuntimeError("getFile gagal (file > 20MB?)")
    fp = info["result"]["file_path"]
    url = "%s/file/bot%s/%s" % (API_BASE, CONF_DATA["BOT_TOKEN"], fp)
    urllib.request.urlretrieve(url, dest)


# ---------------------------------------------------------------------------
# Akun SSH (user sistem Linux)
# ---------------------------------------------------------------------------
def export_ssh_users():
    shadow = {}
    with open("/etc/shadow") as f:
        for line in f:
            p = line.rstrip("\n").split(":")
            if len(p) >= 8:
                shadow[p[0]] = p
    users = []
    with open("/etc/passwd") as f:
        for line in f:
            p = line.rstrip("\n").split(":")
            if len(p) < 7:
                continue
            name, _, uid, gid, gecos, home, shell = p[:7]
            uid = int(uid)
            if 1000 <= uid < 60000 and name != "nobody" and name in shadow:
                s = shadow[name]
                users.append({"name": name, "uid": uid, "gecos": gecos,
                              "home": home, "shell": shell,
                              "hash": s[1], "expire": s[7]})
    return users


def restore_ssh_users(users):
    added = skipped = failed = 0
    for u in users:
        if subprocess.run(["id", u["name"]], capture_output=True).returncode == 0:
            skipped += 1
            continue
        base = ["useradd", "-M", "-s", u["shell"], "-c", u["gecos"],
                "-d", u["home"], u["name"]]
        r = subprocess.run(["useradd", "-u", str(u["uid"])] + base[1:],
                           capture_output=True)
        if r.returncode != 0:  # UID bentrok -> biarkan sistem pilih
            r = subprocess.run(base, capture_output=True)
        if r.returncode != 0:
            failed += 1
            continue
        subprocess.run(["chpasswd", "-e"], input=("%s:%s\n" % (u["name"], u["hash"])).encode(),
                       capture_output=True)
        if u["expire"].isdigit():
            date = time.strftime("%Y-%m-%d", time.gmtime(int(u["expire"]) * 86400))
            subprocess.run(["usermod", "-e", date, u["name"]], capture_output=True)
        added += 1
    return added, skipped, failed


# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
def add_bytes(tar, name, data):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mtime = time.time()
    tar.addfile(ti, io.BytesIO(data))


def make_backup(out_dir="/tmp"):
    host = socket.gethostname()
    ts = time.strftime("%Y%m%d-%H%M%S")
    path = os.path.join(out_dir, "backup-%s-%s.tar.gz" % (host, ts))
    users = export_ssh_users()
    included = [p for p in BACKUP_PATHS if os.path.exists(p)]
    manifest = {"host": host, "time": ts, "paths": included,
                "ssh_users": len(users), "version": 1}
    with tarfile.open(path, "w:gz") as tar:
        add_bytes(tar, "manifest.json", json.dumps(manifest, indent=2).encode())
        add_bytes(tar, "users.json", json.dumps(users, indent=2).encode())
        for p in included:
            tar.add(p, arcname=p.lstrip("/"))
    os.chmod(path, 0o600)
    return path, manifest


def do_backup():
    path, m = make_backup()
    size = os.path.getsize(path) / 1024
    caption = "Backup %s\nSSH user: %d\nFolder: %s\nUkuran: %.1f KB" % (
        m["host"], m["ssh_users"], ", ".join(m["paths"]) or "-", size)
    ok = send_file(path, caption)
    os.remove(path)
    return ok, m


# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
def safe_member(m):
    n = m.name
    if n.startswith("/") or ".." in n.split("/"):
        return False
    if m.issym() or m.islnk() or m.isdev():
        return False
    return n.startswith(ALLOWED_PREFIXES)


def do_restore(path):
    # validasi dulu
    with tarfile.open(path, "r:gz") as tar:
        names = tar.getnames()
        if "manifest.json" not in names or "users.json" not in names:
            raise ValueError("Bukan file backup yang valid (manifest tidak ada)")
        users = json.load(tar.extractfile("users.json"))

    # backup pengaman sebelum menimpa
    os.makedirs("/root/pre-restore", exist_ok=True)
    safety, _ = make_backup("/root/pre-restore")

    count = 0
    with tarfile.open(path, "r:gz") as tar:
        for m in tar.getmembers():
            if m.name in ("manifest.json", "users.json") or not safe_member(m):
                continue
            kw = {"filter": "tar"} if hasattr(tarfile, "tar_filter") else {}
            tar.extract(m, "/", **kw)
            count += 1

    added, skipped, failed = restore_ssh_users(users)

    for svc in RESTART_SERVICES:
        if subprocess.run(["systemctl", "cat", svc], capture_output=True).returncode == 0:
            subprocess.run(["systemctl", "restart", svc], capture_output=True)

    return count, added, skipped, failed, safety


# ---------------------------------------------------------------------------
# Bot
# ---------------------------------------------------------------------------
HELP = ("Bot Backup/Restore akun VPN\n\n"
        "/backup  - buat backup & kirim ke sini\n"
        "/restore - mulai restore, lalu kirim file backup (.tar.gz)\n"
        "/cancel  - batalkan restore")


def run_bot():
    admin = str(CONF_DATA["ADMIN_ID"])
    offset = 0
    waiting_until = 0
    # Pastikan tidak ada webhook (webhook membuat getUpdates tidak menerima pesan)
    try:
        api("deleteWebhook", {"drop_pending_updates": False})
    except Exception as e:
        print("deleteWebhook gagal:", e, flush=True)
    try:
        me = api("getMe").get("result", {}).get("username", "?")
    except Exception as e:
        sys.exit("Token bot tidak valid / tidak bisa menghubungi Telegram: %s" % e)
    print("Bot @%s jalan, admin id %s" % (me, admin), flush=True)
    if not send_text("Bot backup/restore aktif.\n\n" + HELP):
        print("PERINGATAN: gagal kirim pesan ke ADMIN_ID %s. Cek Chat ID & "
              "pastikan sudah kirim /start ke bot." % admin, flush=True)
    while True:
        try:
            res = api("getUpdates", {"offset": offset, "timeout": 30,
                                     "allowed_updates": ["message"]}, timeout=45)
        except Exception as e:
            print("poll error:", e, flush=True)
            time.sleep(5)
            continue
        for upd in res.get("result", []):
            offset = upd["update_id"] + 1
            msg = upd.get("message")
            if not msg:
                continue
            if str(msg["chat"]["id"]) != admin:
                cid = str(msg["chat"]["id"])
                print("ditolak: pesan dari chat %s (admin = %s)" % (cid, admin), flush=True)
                send_text("Akses ditolak. Chat ID ini: %s\n"
                          "Kalau ini kamu, isi Chat ID tersebut di menu Backup & Restore." % cid, cid)
                continue
            text = (msg.get("text") or "").strip()
            if text.startswith("/"):
                text = text.split()[0].split("@")[0].lower()
            doc = msg.get("document")
            caption = (msg.get("caption") or "").strip()

            if text in ("/start", "/help"):
                send_text(HELP)
            elif text == "/backup":
                send_text("Membuat backup...")
                try:
                    ok, _ = do_backup()
                    if not ok:
                        send_text("Gagal mengirim file backup.")
                except Exception as e:
                    send_text("Backup gagal: %s" % e)
            elif text == "/restore":
                waiting_until = time.time() + RESTORE_WAIT
                send_text("Kirim file backup (.tar.gz) dalam %d menit. /cancel untuk batal." %
                          (RESTORE_WAIT // 60))
            elif text == "/cancel":
                waiting_until = 0
                send_text("Restore dibatalkan.")
            elif doc:
                if not (time.time() < waiting_until or caption == "/restore"):
                    send_text("Kirim /restore dulu sebelum mengirim file backup.")
                    continue
                if not (doc.get("file_name") or "").endswith(".tar.gz"):
                    send_text("File harus berformat .tar.gz hasil backup bot ini.")
                    continue
                waiting_until = 0
                send_text("File diterima, memulai restore...")
                tmp = "/tmp/restore-upload.tar.gz"
                try:
                    download_file(doc["file_id"], tmp)
                    c, a, s, f, safety = do_restore(tmp)
                    send_text("Restore selesai.\n"
                              "File dipulihkan: %d\n"
                              "SSH user baru: %d | sudah ada (dilewati): %d | gagal: %d\n"
                              "Backup pengaman: %s" % (c, a, s, f, safety))
                except Exception as e:
                    send_text("Restore gagal: %s" % e)
                finally:
                    if os.path.exists(tmp):
                        os.remove(tmp)


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("Jalankan sebagai root")
    if len(sys.argv) < 2 or sys.argv[1] not in ("backup", "bot"):
        sys.exit(__doc__)
    CONF_DATA.update(load_conf())
    if sys.argv[1] == "backup":
        ok, m = do_backup()
        print("terkirim" if ok else "gagal kirim", m)
    else:
        run_bot()
