#!/usr/bin/env python3
"""Tes INTEGRASI adapter: Xray asli. Bukti: akun berlimit tidak bisa lewat path polos."""
import json, os, signal, subprocess, sys, tempfile, time, http.server, threading, shutil
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "addon", "maxlogin"))
import xray_adapter as xa
XRAY = os.environ.get("XRAY_BIN", shutil.which("xray") or "/tmp/it/xray")
T = tempfile.mkdtemp(prefix="mlxa_"); procs = []; res = []
U = {"budi": "11111111-1111-1111-1111-111111111111", "andi": "33333333-3333-3333-3333-333333333333",
     "cici": "44444444-4444-4444-4444-444444444444"}
ENV = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}

def check(n, c, i=""): res.append(bool(c)); print(("PASS " if c else "FAIL ") + n + (("  [%s]" % i) if i else ""), flush=True)
def spawn(cmd, log):
    p = subprocess.Popen(cmd, stdout=open(T + "/" + log, "w"), stderr=subprocess.STDOUT, start_new_session=True, env=ENV); procs.append(p); return p
def client(uid, path, port, sock):
    cfg = {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1", "port": sock, "protocol": "socks", "settings": {"udp": False}}],
           "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": "127.0.0.1", "port": port, "users": [{"id": uid, "encryption": "none"}]}]},
                          "streamSettings": {"network": "ws", "wsSettings": {"path": path}}}]}
    fn = T + "/c%d.json" % sock; json.dump(cfg, open(fn, "w")); spawn([XRAY, "run", "-c", fn], "c%d.log" % sock); time.sleep(1)
def fetch(sock):
    r = subprocess.run(["curl", "-s", "--noproxy", "", "--max-time", "5", "--socks5-hostname", "127.0.0.1:%d" % sock, "http://127.0.0.1:18998/"], capture_output=True, text=True)
    return r.stdout == "OK"
def start_xray():
    return spawn([XRAY, "run", "-c", T + "/x.json"], "x.log")
def legacy(users):
    return {"tag": "vless-ws-tls", "listen": "127.0.0.1", "port": 10002, "protocol": "vless",
            "settings": {"clients": [{"id": U[u], "email": u} for u in users], "decryption": "none"},
            "streamSettings": {"network": "ws", "wsSettings": {"path": "/vless-ws"}}}
def main():
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(s): s.send_response(200); s.send_header("Content-Length", "2"); s.end_headers(); s.wfile.write(b"OK")
        def log_message(s, *a): pass
    threading.Thread(target=http.server.ThreadingHTTPServer(("127.0.0.1", 18998), H).serve_forever, daemon=True).start()
    cfg = {"log": {"loglevel": "warning"}, "api": {"tag": "api", "services": ["HandlerService", "StatsService"]},
           "stats": {}, "policy": {"levels": {"0": {"statsUserOnline": True}}},
           "inbounds": [legacy(["budi", "andi"]),
                        {"tag": "api", "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}],
           "routing": {"rules": [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]},
           "outbounds": [{"protocol": "freedom"}]}
    json.dump(cfg, open(T + "/x.json", "w"))
    x = start_xray(); time.sleep(1.5)
    client(U["budi"], "/vless-ws", 10002, 12001); client(U["andi"], "/vless-ws", 10002, 12002)
    check("sebelum sync: budi lewat path polos (celah bypass terbukti ada)", fetch(12001))
    check("sebelum sync: andi lewat path polos", fetch(12002))
    # sync: budi berlimit, andi tidak
    r = xa.sync_limited(T + "/x.json", {"budi": {"vless": U["budi"]}}, XRAY, runtime=False)
    check("sync menulis config + backup", r["changed"] and r["backup"] and os.path.exists(r["backup"]))
    os.killpg(x.pid, signal.SIGKILL); time.sleep(1); x = start_xray(); time.sleep(1.5)  # inbound -ml baru butuh restart sekali
    client(U["budi"], "/vless-ws", 10002, 12003); client(U["andi"], "/vless-ws", 10002, 12004)
    check("setelah sync: budi (berlimit) DITOLAK di path polos", not fetch(12003))
    check("setelah sync: andi (tanpa limit) tetap normal di path polos", fetch(12004))
    client(U["budi"], "/vless-ml", 10102, 12005)
    check("budi tetap bisa lewat inbound -ml (jalur bertoken)", fetch(12005))
    r2 = xa.sync_limited(T + "/x.json", {"budi": {"vless": U["budi"]}}, XRAY, runtime=False)
    check("sync idempoten: tanpa perubahan kedua kali", not r2["changed"])
    # runtime tanpa restart: andi jadi berlimit; cici akun baru berlimit
    cfg = json.load(open(T + "/x.json"))
    r3 = xa.sync_limited(T + "/x.json", {"budi": {"vless": U["budi"]}, "andi": {"vless": U["andi"]}, "cici": {"vless": U["cici"]}}, XRAY, runtime=True)
    check("runtime adu/rmu tanpa error", not r3["runtime_errors"], str(r3["runtime_errors"]))
    time.sleep(0.5)
    client(U["andi"], "/vless-ws", 10002, 12006); client(U["andi"], "/vless-ml", 10102, 12007)
    check("andi berlimit via API (tanpa restart): path polos DITOLAK", not fetch(12006))
    check("andi berlimit via API: jalur -ml berhasil", fetch(12007))
    client(U["cici"], "/vless-ml", 10102, 12008)
    check("cici (akun baru) langsung bisa lewat -ml tanpa restart", fetch(12008))
    # antrean ulang: API mati saat sync -> operasi disimpan; API hidup -> diterapkan tanpa perubahan config
    cfg2 = json.load(open(T + "/x.json"))
    U["dodi"] = "55555555-5555-5555-5555-555555555555"
    cfg2["inbounds"].insert(0, {**legacy([]), "settings": {"clients": [{"id": U["dodi"], "email": "dodi"}], "decryption": "none"}})
    json.dump(cfg2, open(T + "/x.json", "w"))
    lim = {"budi": {"vless": U["budi"]}, "andi": {"vless": U["andi"]}, "cici": {"vless": U["cici"]}, "dodi": {"vless": U["dodi"]}}
    r4 = xa.sync_limited(T + "/x.json", lim, XRAY, server="127.0.0.1:19", runtime=True)
    check("API mati: error dilaporkan & operasi diantre", r4["runtime_errors"] and os.path.exists(T + "/x.json.ml-pending.json"))
    r5 = xa.sync_limited(T + "/x.json", lim, XRAY, runtime=True)
    check("API hidup lagi: antrean diterapkan, tanpa error", not r5["runtime_errors"] and not os.path.exists(T + "/x.json.ml-pending.json"), str(r5["runtime_errors"]))
    client(U["dodi"], "/vless-ml", 10102, 12009)
    check("dodi (dipindah via antrean) bisa lewat -ml", fetch(12009))

def cleanup():
    for p in procs:
        try: os.killpg(p.pid, signal.SIGKILL)
        except Exception: pass
if __name__ == "__main__":
    try: main()
    finally: cleanup()
    print("\nHASIL ADAPTER: %d/%d lulus (log di %s)" % (sum(res), len(res), T)); sys.exit(0 if all(res) else 1)
