#!/usr/bin/env python3
"""Tes INTEGRASI MaxLogin: Nginx (auth_request) + Xray asli + klien Xray asli.
Butuh: xray (env XRAY_BIN), nginx, python3. Tidak menyentuh /etc.
Jalankan: XRAY_BIN=/path/xray python3 tests/maxlogin/integration.py
"""
import json, os, signal, subprocess, sys, tempfile, time, socket, threading, http.server, shutil
HERE = os.path.dirname(os.path.abspath(__file__))
SVC = os.path.join(HERE, "..", "..", "addon", "maxlogin", "maxlogin_service.py")
XRAY = os.environ.get("XRAY_BIN", shutil.which("xray") or "/tmp/it/xray")
T = tempfile.mkdtemp(prefix="mlit_")
P = dict(web=18999, ml=10901, nginx=18080, vless=10102, vmess=10101, trojan=10105)
INC = os.path.join(HERE, "..", "..", "addon", "maxlogin")
procs, results = [], []
UUID_L, UUID_M, PW_T = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", "pw-budi"
CRED = {"budi": (UUID_L, UUID_M, PW_T),
        "samp": ("55555555-5555-5555-5555-555555555555", "66666666-6666-6666-6666-666666666666", "pw-samp")}
ENV = dict(os.environ, MAXLOGIN_CONFIG=T + "/ml.json")
for k in ("http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
    ENV.pop(k, None)

def w(name, data):
    with open(os.path.join(T, name), "w") as f:
        f.write(data if isinstance(data, str) else json.dumps(data))

def spawn(cmd, log, env=None):
    p = subprocess.Popen(cmd, stdout=open(os.path.join(T, log), "w"), stderr=subprocess.STDOUT, env=env or ENV, start_new_session=True)
    procs.append(p); return p

def ws_in(tag, port, proto, path, cl):
    return {"tag": tag, "listen": "127.0.0.1", "port": port, "protocol": proto,
            "settings": cl, "streamSettings": {"network": "ws", "wsSettings": {"path": path}}}

def check(name, cond, info=""):
    results.append((name, bool(cond))); print(("PASS " if cond else "FAIL ") + name + (("  [" + info + "]") if info else ""), flush=True)

def web():
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(s): s.send_response(200); s.send_header("Content-Length", "2"); s.end_headers(); s.wfile.write(b"OK")
        def log_message(s, *a): pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", P["web"]), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

def client(proto, token, src, port, kind="ws", acct="budi"):
    UUID_L, UUID_M, PW_T = CRED[acct]
    out = {"vless": {"protocol": "vless", "settings": {"vnext": [{"address": "127.0.0.1", "port": P["nginx"], "users": [{"id": UUID_L, "encryption": "none"}]}]}},
           "vmess": {"protocol": "vmess", "settings": {"vnext": [{"address": "127.0.0.1", "port": P["nginx"], "users": [{"id": UUID_M, "security": "auto"}]}]}},
           "trojan": {"protocol": "trojan", "settings": {"servers": [{"address": "127.0.0.1", "port": P["nginx"], "password": PW_T}]}}}[proto]
    out["streamSettings"] = {"network": "ws", "wsSettings": {"path": "/%s-%s/%s" % (proto, kind, token)}}
    out["sendThrough"] = src
    cfg = {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": {"udp": False}}], "outbounds": [out]}
    n = "c_%d.json" % port; w(n, cfg)
    spawn([XRAY, "run", "-c", os.path.join(T, n)], "c_%d.log" % port); time.sleep(1.0)

def fetch(port):
    r = subprocess.run(["curl", "-s", "--noproxy", "", "--max-time", "6", "--socks5-hostname", "127.0.0.1:%d" % port,
                        "http://127.0.0.1:%d/" % P["web"]], capture_output=True, text=True)
    return r.stdout == "OK"

def cli(*a):
    return subprocess.run([sys.executable, SVC] + list(a), capture_output=True, text=True, env=ENV).stdout

def mllog():
    try: return [json.loads(l) for l in open(T + "/ml.log") if l.strip()]
    except Exception: return []

def start_ml():
    return spawn([sys.executable, SVC, "serve"], "ml.out")

def start_nginx():
    subprocess.run(["nginx", "-c", T + "/nginx.conf"], check=True)

def main():
    os.makedirs(T + "/sd/db"); web()
    w("xray.json", {"log": {"loglevel": "warning", "access": T + "/access.log"}, "inbounds": [
        ws_in("l", P["vless"], "vless", "/vless-ml", {"clients": [{"id": UUID_L, "email": "budi"}, {"id": CRED["samp"][0], "email": "samp"}], "decryption": "none"}),
        ws_in("m", P["vmess"], "vmess", "/vmess-ml", {"clients": [{"id": UUID_M, "email": "budi"}, {"id": CRED["samp"][1], "email": "samp"}]}),
        ws_in("t", P["trojan"], "trojan", "/trojan-ml", {"clients": [{"password": PW_T, "email": "budi"}, {"password": CRED["samp"][2], "email": "samp"}]})],
        "outbounds": [{"protocol": "freedom"}]})
    # db script palsu supaya sync tidak menonaktifkan akun
    for f, i in (("vless.db", 0), ("vmess.db", 1), ("trojan.db", 2)):
        open(T + "/sd/db/" + f, "w").write("budi|%s|2099-01-01|2026-01-01|2|0\nsamp|%s|2099-01-01|2026-01-01|3|0\n" % (CRED["budi"][i], CRED["samp"][i]))
    w("ml.json", {"db_path": T + "/ml.db", "log_path": T + "/ml.log", "listen_port": P["ml"], "ip_group_bits": 32,
                  "ip_pools": "", "shared_min_limit": 3, "shared_ttl_seconds": 6, "ttl_seconds": 6, "sweep_interval": 2, "xray_stats": False, "script_dir": T + "/sd"})
    # Nginx memakai snippet ASLI dari addon/maxlogin (bukan salinan tes)
    w("nginx.conf", "pid %s/nginx.pid; error_log %s/nginx.err; worker_processes 1;\nevents { worker_connections 256; }\n"
      "http { access_log %s/nginx.acc;\n include %s/nginx-maxlogin-http.inc;\n"
      " server { listen 127.0.0.1:%d; include %s/nginx-maxlogin.inc; location / { return 404; } } }\n"
      % (T, T, T, INC, P["nginx"], INC))
    spawn([XRAY, "run", "-c", T + "/xray.json"], "xray.log"); time.sleep(1.5)
    ml = start_ml(); time.sleep(1.2); start_nginx(); time.sleep(0.8)
    cli("set", "budi", "--max", "2")
    tok = [l.split()[-1] if False else l for l in []]
    shown = json.loads(cli("show", "budi") or "{}") if False else None
    import sqlite3
    db = sqlite3.connect(T + "/ml.db"); toks = [r[0] for r in db.execute("select token from slots where username='budi' order by idx")]; db.close()
    check("setup: 2 slot token dibuat untuk budi", len(toks) == 2, str(len(toks)))
    A, B, C = "127.0.0.2", "127.0.0.3", "127.0.0.4"

    # ── akun sample: LINK TUNGGAL (limit 3 >= shared_min_limit) ──
    cli("sync")
    db = sqlite3.connect(T + "/ml.db"); st = [r[0] for r in db.execute("select token from slots where username='samp' and revoked=0")]; db.close()
    check("sample: limit 3 -> satu token saja (mode link tunggal)", len(st) == 1, str(len(st)))
    P1, P2, P3, P4 = "127.0.0.21", "127.0.0.22", "127.0.0.23", "127.0.0.24"
    client("vless", st[0], P1, 11100, acct="samp"); client("vmess", st[0], P2, 11101, acct="samp"); client("trojan", st[0], P3, 11102, acct="samp")
    check("sample: 3 perangkat berbeda memakai SATU token (vless/vmess/trojan) -> semua berhasil",
          fetch(11100) and fetch(11101) and fetch(11102))
    client("vless", st[0], P4, 11103, acct="samp")
    check("sample: perangkat ke-4 dengan token yang sama DITOLAK", not fetch(11103))
    check("sample: 3 perangkat awal tetap aktif setelah yang ke-4 ditolak", fetch(11100) and fetch(11101) and fetch(11102))
    check("log sample: device_limit untuk perangkat ke-4", any(e.get("event") == "login_denied" and e.get("reason") == "device_limit" and e.get("ip") == P4 for e in mllog()))

    # 1 perangkat A di slot0 (vless)
    client("vless", toks[0], A, 11080)
    check("A (slot0, vless) lewat Nginx+Xray berhasil", fetch(11080))
    check("log: login_allowed tercatat untuk A", any(e.get("event") == "login_allowed" and e.get("ip") == A for e in mllog()))
    # banyak koneksi dari perangkat yang sama = 1 perangkat
    ok = all(fetch(11080) for _ in range(5))
    check("banyak koneksi dari A tetap diizinkan (1 perangkat)", ok)
    # jalur nTLS (port 80) memakai token & slot yang sama: perangkat A boleh, perangkat lain ditolak
    client("vless", toks[0], A, 11090, "ntls")
    check("A lewat jalur nTLS (/vless-ntls/<token>) berhasil", fetch(11090))
    client("vless", toks[0], "127.0.0.9", 11091, "ntls")
    check("perangkat lain lewat nTLS dengan token slot0: DITOLAK", not fetch(11091))
    # perangkat B memakai token yang sama (slot0 terisi A) -> harus DITOLAK
    client("vless", toks[0], B, 11081)
    check("B memakai token slot0 milik A: DITOLAK (403)", not fetch(11081))
    check("log: login_denied device_limit untuk B", any(e.get("event") == "login_denied" and e.get("reason") == "device_limit" and e.get("ip") == B for e in mllog()))
    check("A tetap aktif setelah B ditolak", fetch(11080))
    # B memakai slot1 (vmess, lintas protokol) -> diizinkan
    client("vmess", toks[1], B, 11082)
    check("B di slot1 via VMess (lintas protokol, akun sama) berhasil", fetch(11082))
    # perangkat ketiga C: kedua slot terisi -> tolak, lewat trojan dengan token slot1 & slot0
    client("trojan", toks[1], C, 11083)
    check("C (perangkat ke-3) di slot1 via Trojan: DITOLAK", not fetch(11083))
    client("trojan", toks[0], C, 11084)
    check("C (perangkat ke-3) di slot0 via Trojan: DITOLAK", not fetch(11084))
    check("A & B tetap aktif setelah C ditolak", fetch(11080) and fetch(11082))
    # token palsu / tanpa token
    client("vless", "AAAAAAAAAAAAAAAAAAAAAAAA", A, 11085)
    check("token tidak dikenal: DITOLAK", not fetch(11085))
    # TTL: berhenti memakai slot0 -> setelah TTL, C boleh mengambil slot0
    for p in list(procs):
        pass
    time.sleep(0)  # A (11080) berhenti dipakai: tunggu TTL
    time.sleep(9)
    check("slot kedaluwarsa dibersihkan sweeper (session_ended tercatat)", any(e.get("event") == "session_ended" for e in mllog()))
    check("C kini boleh memakai slot0 setelah TTL", fetch(11084))
    # rotasi token membatalkan token lama
    out = cli("rotate", "budi", "0")
    db = sqlite3.connect(T + "/ml.db"); nt = [r[0] for r in db.execute("select token from slots where username='budi' and idx=0")][0]; db.close()
    check("rotate: token baru berbeda", nt != toks[0])
    client("vless", toks[0], "127.0.0.5", 11086)
    check("token lama setelah rotate: DITOLAK", not fetch(11086))
    # akun dinonaktifkan
    cli("set", "budi", "--max", "2", "--disable")
    client("vless", nt, "127.0.0.6", 11087)
    check("akun dinonaktifkan: DITOLAK", not fetch(11087))
    cli("set", "budi", "--max", "2", "--enable")
    # layanan MaxLogin mati -> on_error=allow (default) vs deny
    db = sqlite3.connect(T + "/ml.db"); toks2 = [r[0] for r in db.execute("select token from slots where username='budi' order by idx")]; db.close()
    os.killpg(ml.pid, signal.SIGKILL); time.sleep(1)
    client("vless", toks2[1], "127.0.0.7", 11088)
    check("service mati: Nginx menolak (auth 5xx) = fail-closed, tidak ada bypass", not fetch(11088),
          "auth_request tanpa upstream = 500, jadi fail-closed")
    ml = start_ml(); time.sleep(1.5)
    client("vless", toks2[1], "127.0.0.7", 11089)
    check("service restart: state SQLite dipertahankan & login normal", fetch(11089))
    # tes concurrent: 8 perangkat berbeda berebut 1 slot kosong
    cli("set", "budi", "--max", "1")
    db = sqlite3.connect(T + "/ml.db"); t1 = [r[0] for r in db.execute("select token from slots where username='budi' and revoked=0")]; db.close()
    time.sleep(8)  # biarkan slot lama kedaluwarsa
    res = []
    def go(i):
        import urllib.request
        ip = "127.0.1.%d" % (10 + i)
        s = socket.socket(); s.bind((ip, 0)); s.connect(("127.0.0.1", P["nginx"]))
        s.sendall(("GET /vless-ws/%s HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n" % t1[0]).encode())
        res.append(s.recv(200).split(b"\r\n")[0]); s.close()
    ths = [threading.Thread(target=go, args=(i,)) for i in range(8)]
    [t.start() for t in ths]; [t.join() for t in ths]
    n_ok = sum(1 for r in res if b" 101" in r or b" 200" in r or b" 400" in r)
    n_deny = sum(1 for r in res if b" 403" in r)
    check("concurrent: 8 perangkat berebut 1 slot -> tepat 1 lolos auth", n_ok == 1 and n_deny == 7, "lolos=%d tolak=%d" % (n_ok, n_deny))

def cleanup():
    for p in procs:
        try: os.killpg(p.pid, signal.SIGKILL)
        except Exception: pass
    try: os.kill(int(open(T + "/nginx.pid").read()), signal.SIGTERM)
    except Exception: pass

if __name__ == "__main__":
    try: main()
    finally: cleanup()
    bad = [n for n, ok in results if not ok]
    print("\nHASIL INTEGRASI: %d/%d lulus (log di %s)" % (len(results) - len(bad), len(results), T))
    sys.exit(1 if bad else 0)
