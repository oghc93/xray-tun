#!/usr/bin/env python3
"""
maxlogin_service.py - service lokal untuk Nginx auth_request + CLI pengelola.

  serve                         jalankan service (systemd: vpn-maxlogin.service)
  sync                          sinkronkan akun dari db script (vmess/vless/trojan)
  show [user]                   tampilkan akun, slot, dan perangkat aktif
  links USER [--domain D]       cetak path/link per slot perangkat
  rotate USER IDX               cabut token slot dan terbitkan yang baru
  xray-restore            kembalikan akun berlimit ke inbound lama (saat MaxLogin dimatikan)
  xray-sync [--runtime]   pindahkan akun berlimit ke inbound -ml (backup config dulu)
  set USER --max N [--disable|--enable]
  sweep                         bebaskan sesi kedaluwarsa sekarang
"""
import json
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from maxlogin_core import MaxLoginCore, load_config, PROTOS  # noqa: E402

PATH_RE = re.compile(r"^/(vless-ws|vmess-ws|trojan-ws|vless-ntls|vmess-ntls)/([A-Za-z0-9]{16,64})(?:[?].*)?$")


def make_handler(core):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):   # log kita sendiri
            pass

        def _reply(self, code, reason=""):
            self.send_response(code)
            self.send_header("X-ML-Reason", reason)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            if self.path == "/health":
                return self._reply(200, "ok")
            if self.path != "/auth":
                return self._reply(404, "not_found")
            uri = self.headers.get("X-Original-URI", "")
            ip = self.headers.get("X-Real-IP", "") or self.client_address[0]
            m = PATH_RE.match(uri)
            if not m:
                core.log("login_denied", reason="bad_path", ip=ip, uri=uri[:80])
                return self._reply(403, "bad_path")
            proto = m.group(1).split("-")[0]
            try:
                ok, reason, _ = core.authorize(m.group(2), proto, ip)
            except Exception as e:   # galat internal: ikuti kebijakan on_error
                core.log("error", where="authorize", err=str(e)[:200])
                if core.cfg.get("on_error", "allow") == "allow":
                    return self._reply(200, "error_open")
                return self._reply(403, "error_closed")
            return self._reply(200 if ok else 403, reason)

    return H


def xray_user_bytes(cfg):
    """{username: total_bytes} dari Xray Stats API; {} bila tak tersedia."""
    try:
        out = subprocess.run([cfg["xray_bin"], "api", "statsquery", "--server=" + cfg["xray_api"],
                              "-pattern", "user>>>"], capture_output=True, text=True, timeout=6).stdout
        data = json.loads(out or "{}")
    except Exception:
        return {}
    res = {}
    for s in data.get("stat", []) or []:
        p = s.get("name", "").split(">>>")
        if len(p) == 4 and p[2] == "traffic":
            try:
                res[p[1]] = res.get(p[1], 0) + int(s.get("value", 0))
            except (TypeError, ValueError):
                pass
    return res


def sweeper(core, stop):
    prev = {}
    last_sync = 0
    while not stop.is_set():
        try:
            core.sweep()
            if core.cfg.get("xray_stats"):
                cur = xray_user_bytes(core.cfg)
                for user, b in cur.items():
                    if user in prev and b != prev[user]:
                        core.heartbeat_account(user)
                prev = cur
            if time.time() - last_sync >= int(core.cfg.get("sync_interval", 60)):
                core.sync_from_script()
                if core.cfg.get("xray_manage"):
                    import xray_adapter
                    r = xray_adapter.sync_limited(core.cfg["xray_config"], core.limited_credentials(),
                                                  core.cfg["xray_bin"], core.cfg["xray_api"])
                    if r["changed"] or r["runtime_errors"]:
                        core.log("xray_sync", moved=r["moved"], errors=r["runtime_errors"], backup=r["backup"])
                last_sync = time.time()
        except Exception as e:
            core.log("error", where="sweeper", err=str(e)[:200])
        stop.wait(float(core.cfg["sweep_interval"]))


def serve(core):
    stop = threading.Event()
    threading.Thread(target=sweeper, args=(core, stop), daemon=True).start()
    srv = ThreadingHTTPServer((core.cfg["listen_host"], int(core.cfg["listen_port"])), make_handler(core))
    srv.daemon_threads = True
    core.log("service_started", listen="%s:%s" % (core.cfg["listen_host"], core.cfg["listen_port"]))
    try:
        srv.serve_forever()
    finally:
        stop.set()


def cmd_show(core, user=None):
    import sqlite3
    c = core._conn()
    try:
        accs = [dict(r) for r in c.execute("SELECT * FROM accounts" + (" WHERE username=?" if user else ""),
                                           (user,) if user else ())]
    finally:
        c.close()
    for a in accs:
        exp = time.strftime("%Y-%m-%d", time.localtime(a["expires_at"])) if a["expires_at"] else "-"
        print("%-16s max=%d aktif=%d enabled=%d mode=%s exp=%s" % (a["username"], a["max_devices"],
              core.active_devices(a["username"]), a["enabled"],
              "tunggal" if a.get("mode") == "shared" else "per-perangkat", exp))
        if a.get("mode") == "shared":
            for o in core.origins(a["username"]):
                print("    asal %-22s %s" % (o["sig"], o["ip"] or ""))
        for t in core.tokens(a["username"]):
            st = "dicabut" if t["revoked"] else ("aktif " + (t["sig"] or "")) if t["sig"] else "bebas"
            print("    slot %d  %s...  %s" % (t["idx"], t["token"][:6], st))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cfg = load_config()
    core = MaxLoginCore(cfg)
    cmd = argv[0]
    if cmd == "serve":
        serve(core)
    elif cmd == "sync":
        print("akun diatur MaxLogin:", core.sync_from_script())
    elif cmd == "show":
        cmd_show(core, argv[1] if len(argv) > 1 else None)
    elif cmd == "links":
        user = argv[1]
        dom = argv[argv.index("--domain") + 1] if "--domain" in argv else "DOMAIN"
        shared = core.account_mode(user) == "shared"
        for t in core.tokens(user):
            if t["revoked"]:
                continue
            print("link tunggal (dipakai hingga N perangkat):" if shared else "slot %d:" % t["idx"])
            for p in PROTOS:
                print("   %-6s path=/%s-ws/%s  (wss://%s:443)" % (p, p, t["token"], dom))
    elif cmd == "tokens":
        # token slot aktif satu per baris; kosong bila akun tak diatur/nonaktif
        c = core._conn()
        try:
            for r in c.execute("""SELECT s.token, a.mode FROM slots s JOIN accounts a ON a.username=s.username
                                  WHERE s.username=? AND s.revoked=0 AND a.enabled=1 ORDER BY s.idx""", (argv[1],)):
                print(("shared:" if r["mode"] == "shared" else "") + r["token"])
        finally:
            c.close()
    elif cmd == "rotate":
        print(core.rotate_token(argv[1], argv[2]) or "slot tidak ditemukan")
    elif cmd == "set":
        user = argv[1]
        mx = int(argv[argv.index("--max") + 1]) if "--max" in argv else None
        if mx is not None:
            core.upsert_account(user, mx, enabled="--disable" not in argv)
        elif "--disable" in argv:
            core.disable_account(user, "manual")
        elif "--enable" in argv:
            core.set_enabled(user, True)
    elif cmd == "xray-sync":
        import xray_adapter
        runtime = "--runtime" in argv   # tanpa --runtime: hanya tulis config (butuh restart Xray)
        r = xray_adapter.sync_limited(core.cfg["xray_config"], core.limited_credentials(),
                                      core.cfg["xray_bin"], core.cfg["xray_api"], runtime=runtime)
        print(json.dumps(r, indent=2))
    elif cmd == "xray-restore":
        import xray_adapter
        print(json.dumps(xray_adapter.restore_legacy(core.cfg["xray_config"], core.limited_credentials()), indent=2))
    elif cmd == "sweep":
        print("sesi dibebaskan:", core.sweep())
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
