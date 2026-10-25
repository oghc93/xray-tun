#!/usr/bin/env python3
"""
maxlogin_core.py - inti MaxLogin Xray (kebijakan + registry sesi).

Model (lihat docs/MAXLOGIN_XRAY.md):
  * Satu akun punya N "slot perangkat" (N = max_devices). Tiap slot punya token acak.
  * Token dipasang di path link WS: /vless-ws/<token>, /vmess-ws/<token>, /trojan-ws/<token>.
    Token milik AKUN, bukan milik protokol -> batas berlaku lintas VLESS/VMess/Trojan.
  * Slot terikat pada "tanda tangan asal" (IP yang digabung per kolam/kisaran) selama aktif.
    Koneksi lain ke slot yang sama dari asal berbeda saat slot aktif DITOLAK; perangkat yang
    sudah aktif tidak disentuh. Banyak koneksi dari asal yang sama = satu perangkat.
  * Aktif = ada koneksi baru / trafik akun dalam TTL. Setelah TTL slot bebas (sesi berakhir).
  * Semua keputusan dalam satu transaksi SQLite (BEGIN IMMEDIATE) -> atomik antar-proses.

Hanya pustaka standar Python.
"""
import json
import os
import secrets
import sqlite3
import time
import threading

DEFAULT_CONFIG = {
    "db_path": "/var/lib/vpn-script/maxlogin.db",
    "log_path": "/var/log/vpn-maxlogin.log",
    "listen_host": "127.0.0.1",
    "listen_port": 10901,
    "ttl_seconds": 120,        # slot dianggap bebas bila tak ada aktivitas sebanyak ini
    "hold_seconds": 600,       # trafik akun memperpanjang slot yang terakhir terlihat dalam rentang ini
    "sweep_interval": 10,
    "ip_group_bits": 16,       # IPv4: 16 = per /16, 24 = per /24, 32 = per IP
    "ip_pools": "112.215,140.213",   # kisaran satu operator (CGNAT) dihitung satu perangkat
    "on_error": "allow",       # galat internal service: allow (buka) | deny (tutup)
    "xray_stats": True,
    "xray_bin": "xray",
    "xray_api": "127.0.0.1:10085",
    "xray_manage": False,            # True = service memindahkan akun berlimit ke inbound -ml
    "xray_config": "/etc/xray/config.json",
    "script_dir": "/etc/vpn-script",
    "token_len": 24,
    "shared_min_limit": 10,    # limit >= ini -> mode LINK TUNGGAL (1 token, hingga N asal bersamaan); 0 = mati
    "shared_ttl_seconds": 300, # asal di mode tunggal dianggap pergi bila tak ada koneksi baru selama ini
}

PROTOS = ("vless", "vmess", "trojan")


def load_config(path=None):
    cfg = dict(DEFAULT_CONFIG)
    path = path or os.environ.get("MAXLOGIN_CONFIG", "/etc/vpn-script/maxlogin.json")
    if os.path.isfile(path):
        with open(path) as f:
            cfg.update(json.load(f))
    return cfg


# ── identitas asal (tanda tangan) ────────────────────────────────────────────
def group_key(ip, bits=16, pools=""):
    """IP -> kunci perangkat. Kisaran dalam satu kolam = satu kunci; IPv6 per /64."""
    ip = (ip or "").strip()
    if not ip:
        return "unknown"
    if ip.startswith("::ffff:"):
        ip = ip[7:]
    if ":" in ip:
        h = ip.split(":")
        h = (h + ["0"] * 4)[:4]
        return "v6:" + ":".join(h)
    o = ip.split(".")
    if len(o) != 4:
        return "raw:" + ip
    p16 = o[0] + "." + o[1]
    for i, pool in enumerate(p for p in (pools or "").split() if p):
        if p16 in pool.split(","):
            return "pool%d" % (i + 1)
    if bits <= 16:
        return "v4:" + p16
    if bits <= 24:
        return "v4:" + p16 + "." + o[2]
    return "v4:" + ip


class MaxLoginCore:
    def __init__(self, cfg=None):
        self.cfg = cfg or load_config()
        self._log_lock = threading.Lock()
        self._lastlog = {}
        d = os.path.dirname(self.cfg["db_path"])
        if d:
            os.makedirs(d, exist_ok=True)
        self._init_db()

    # ── DB ───────────────────────────────────────────────────────────────────
    def _conn(self):
        c = sqlite3.connect(self.cfg["db_path"], timeout=15, isolation_level=None)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA busy_timeout=15000")
        return c

    def _init_db(self):
        c = self._conn()
        try:
            c.executescript("""
            CREATE TABLE IF NOT EXISTS accounts(
              username TEXT PRIMARY KEY,
              max_devices INTEGER NOT NULL DEFAULT 1,
              enabled INTEGER NOT NULL DEFAULT 1,
              expires_at INTEGER,
              updated_at INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS slots(
              token TEXT PRIMARY KEY,
              username TEXT NOT NULL,
              idx INTEGER NOT NULL,
              sig TEXT,
              ip TEXT,
              proto TEXT,
              bound_at INTEGER,
              last_seen INTEGER,
              revoked INTEGER NOT NULL DEFAULT 0,
              UNIQUE(username, idx)
            );
            CREATE INDEX IF NOT EXISTS slots_user ON slots(username);
            CREATE TABLE IF NOT EXISTS origins(
              token TEXT NOT NULL,
              sig TEXT NOT NULL,
              ip TEXT,
              proto TEXT,
              bound_at INTEGER,
              last_seen INTEGER,
              PRIMARY KEY(token, sig)
            );
            """)
            cols = [r[1] for r in c.execute("PRAGMA table_info(accounts)")]
            if "mode" not in cols:
                c.execute("ALTER TABLE accounts ADD COLUMN mode TEXT NOT NULL DEFAULT 'device'")
        finally:
            c.close()

    # ── log ──────────────────────────────────────────────────────────────────
    def log(self, event, **kw):
        rec = {"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "event": event}
        rec.update(kw)
        line = json.dumps(rec, ensure_ascii=False)
        try:
            with self._log_lock:
                with open(self.cfg["log_path"], "a") as f:
                    f.write(line + "\n")
        except OSError:
            pass

    def _newtoken(self):
        return secrets.token_urlsafe(32).replace("-", "").replace("_", "")[: self.cfg["token_len"]]

    # ── manajemen akun & kredensial ──────────────────────────────────────────
    def _mode_for(self, max_devices):
        thr = int(self.cfg.get("shared_min_limit", 10) or 0)
        return "shared" if thr > 0 and int(max_devices) >= thr else "device"

    def upsert_account(self, username, max_devices, enabled=True, expires_at=None, now=None):
        """Buat/ubah akun. Mode 'device': N slot (N token). Mode 'shared' (limit >= shared_min_limit):
        satu token yang boleh dipakai hingga N asal bersamaan. Slot berlebih dicabut."""
        now = int(now if now is not None else time.time())
        max_devices = max(0, int(max_devices))
        mode = self._mode_for(max_devices)
        nslots = 1 if (mode == "shared" and max_devices > 0) else max_devices
        c = self._conn()
        try:
            c.execute("BEGIN IMMEDIATE")
            prev = c.execute("SELECT mode FROM accounts WHERE username=?", (username,)).fetchone()
            c.execute("""INSERT INTO accounts(username,max_devices,enabled,expires_at,updated_at,mode)
                         VALUES(?,?,?,?,?,?)
                         ON CONFLICT(username) DO UPDATE SET max_devices=excluded.max_devices,
                           enabled=excluded.enabled, expires_at=excluded.expires_at,
                           updated_at=excluded.updated_at, mode=excluded.mode""",
                      (username, max_devices, 1 if enabled else 0, expires_at, now, mode))
            if prev is not None and prev["mode"] != mode:
                # ganti mode: lepas semua ikatan asal (token slot 0 tetap sama)
                c.execute("DELETE FROM origins WHERE token IN (SELECT token FROM slots WHERE username=?)", (username,))
                c.execute("UPDATE slots SET sig=NULL WHERE username=?", (username,))
            have = {r["idx"]: r for r in c.execute("SELECT * FROM slots WHERE username=?", (username,))}
            for i in range(nslots):
                if i not in have:
                    c.execute("INSERT INTO slots(username,idx,token) VALUES(?,?,?)",
                              (username, i, self._newtoken()))
                elif have[i]["revoked"]:
                    # slot yang dulu dicabut karena N turun: hidupkan lagi dengan token baru
                    c.execute("UPDATE slots SET revoked=0, token=?, sig=NULL, last_seen=NULL WHERE username=? AND idx=?",
                              (self._newtoken(), username, i))
            c.execute("UPDATE slots SET revoked=1, sig=NULL WHERE username=? AND idx>=?",
                      (username, nslots))
            c.execute("COMMIT")
        except Exception:
            try: c.execute("ROLLBACK")
            except Exception: pass
            raise
        finally:
            c.close()

    def set_enabled(self, username, enabled):
        c = self._conn()
        try:
            c.execute("UPDATE accounts SET enabled=? WHERE username=?", (1 if enabled else 0, username))
        finally:
            c.close()

    def disable_account(self, username, reason="disabled"):
        c = self._conn()
        try:
            c.execute("UPDATE accounts SET enabled=0, updated_at=? WHERE username=?", (int(time.time()), username))
            c.execute("UPDATE slots SET sig=NULL WHERE username=?", (username,))
            c.execute("DELETE FROM origins WHERE token IN (SELECT token FROM slots WHERE username=?)", (username,))
        finally:
            c.close()
        self.log("account_disabled", user=username, reason=reason)

    def tokens(self, username):
        c = self._conn()
        try:
            return [dict(r) for r in c.execute(
                "SELECT idx,token,sig,ip,last_seen,revoked FROM slots WHERE username=? ORDER BY idx", (username,))]
        finally:
            c.close()

    def account_mode(self, username):
        c = self._conn()
        try:
            r = c.execute("SELECT mode FROM accounts WHERE username=?", (username,)).fetchone()
            return r["mode"] if r else None
        finally:
            c.close()

    def origins(self, username):
        c = self._conn()
        try:
            return [dict(r) for r in c.execute(
                "SELECT o.sig,o.ip,o.proto,o.last_seen FROM origins o JOIN slots s ON s.token=o.token "
                "WHERE s.username=? ORDER BY o.bound_at", (username,))]
        finally:
            c.close()

    def rotate_token(self, username, idx):
        """Cabut kredensial lama slot dan terbitkan token baru."""
        new = self._newtoken()
        c = self._conn()
        try:
            old = c.execute("SELECT token FROM slots WHERE username=? AND idx=?", (username, int(idx))).fetchone()
            cur = c.execute("UPDATE slots SET token=?, sig=NULL, ip=NULL, last_seen=NULL, revoked=0 "
                            "WHERE username=? AND idx=?", (new, username, int(idx)))
            if old is not None:
                c.execute("DELETE FROM origins WHERE token=?", (old["token"],))
            if cur.rowcount == 0:
                return None
        finally:
            c.close()
        self.log("token_rotated", user=username, idx=int(idx))
        return new

    # ── keputusan inti ───────────────────────────────────────────────────────
    def authorize(self, token, proto, ip, now=None):
        """Kembalikan (diizinkan:bool, alasan:str, username|None). Atomik."""
        now = int(now if now is not None else time.time())
        ttl = int(self.cfg["ttl_seconds"])
        sig = group_key(ip, self.cfg["ip_group_bits"], self.cfg["ip_pools"])
        c = self._conn()
        try:
            c.execute("BEGIN IMMEDIATE")
            slot = c.execute("SELECT * FROM slots WHERE token=?", (token,)).fetchone()
            if slot is None:
                c.execute("COMMIT")
                return self._decide(False, "unknown_token", None, proto, ip, token)
            acc = c.execute("SELECT * FROM accounts WHERE username=?", (slot["username"],)).fetchone()
            user = slot["username"]
            if acc is None or not acc["enabled"]:
                c.execute("COMMIT")
                return self._decide(False, "account_disabled", user, proto, ip, token)
            if acc["expires_at"] is not None and now >= acc["expires_at"]:
                c.execute("COMMIT")
                return self._decide(False, "account_expired", user, proto, ip, token)
            if slot["revoked"]:
                c.execute("COMMIT")
                return self._decide(False, "token_revoked", user, proto, ip, token)

            if acc["mode"] == "shared":
                return self._authorize_shared(c, slot, acc, proto, ip, sig, now)

            active = slot["sig"] is not None and slot["last_seen"] is not None and (now - slot["last_seen"]) <= ttl
            if not active:
                reason = "rebound" if slot["sig"] is not None else "bound"
                c.execute("UPDATE slots SET sig=?, ip=?, proto=?, bound_at=?, last_seen=? WHERE token=?",
                          (sig, ip, proto, now, now, token))
                c.execute("COMMIT")
                return self._decide(True, reason, user, proto, ip, token)
            if slot["sig"] == sig:
                c.execute("UPDATE slots SET last_seen=?, ip=?, proto=? WHERE token=?", (now, ip, proto, token))
                c.execute("COMMIT")
                return self._decide(True, "ok", user, proto, ip, token)
            c.execute("COMMIT")
            return self._decide(False, "device_limit", user, proto, ip, token)
        except Exception:
            try: c.execute("ROLLBACK")
            except Exception: pass
            raise
        finally:
            c.close()

    def _authorize_shared(self, c, slot, acc, proto, ip, sig, now):
        """Mode link tunggal: satu token, hingga max_devices asal (kelompok IP) aktif bersamaan.
        Dipanggil di dalam transaksi BEGIN IMMEDIATE (atomik)."""
        token, user = slot["token"], slot["username"]
        ttl = int(self.cfg.get("shared_ttl_seconds", 300))
        gone = c.execute("SELECT sig,ip,bound_at,last_seen FROM origins WHERE token=? AND ?-last_seen>?",
                         (token, now, ttl)).fetchall()
        if gone:
            c.execute("DELETE FROM origins WHERE token=? AND ?-last_seen>?", (token, now, ttl))
        row = c.execute("SELECT 1 FROM origins WHERE token=? AND sig=?", (token, sig)).fetchone()
        if row:
            c.execute("UPDATE origins SET last_seen=?, ip=?, proto=? WHERE token=? AND sig=?", (now, ip, proto, token, sig))
            decision = (True, "ok")
        else:
            n = c.execute("SELECT COUNT(*) FROM origins WHERE token=?", (token,)).fetchone()[0]
            if n < int(acc["max_devices"]):
                c.execute("INSERT INTO origins(token,sig,ip,proto,bound_at,last_seen) VALUES(?,?,?,?,?,?)",
                          (token, sig, ip, proto, now, now))
                decision = (True, "bound")
            else:
                decision = (False, "device_limit")
        c.execute("COMMIT")
        for g in gone:
            self.log("session_ended", user=user, slot=0, ip=g["ip"], duration=(g["last_seen"] or now) - (g["bound_at"] or now))
        return self._decide(decision[0], decision[1], user, proto, ip, token)

    def _decide(self, ok, reason, user, proto, ip, token):
        # Anti-banjir log: kejadian sama (hasil+alasan+akun+slot+kelompok IP) dicatat paling sering
        # sekali per log_repeat_seconds; yang ditahan dihitung di field "repeat". Perubahan (bound/rebound) selalu dicatat.
        ev = "login_allowed" if ok else "login_denied"
        gap = float(self.cfg.get("log_repeat_seconds", 60))
        key = (ev, reason, user, (token or "")[:6], group_key(ip, self.cfg["ip_group_bits"], self.cfg["ip_pools"]))
        now = time.time()
        with self._log_lock:
            last, held = self._lastlog.get(key, (0, 0))
            quiet = reason in ("ok",) or not ok
            if quiet and gap > 0 and now - last < gap:
                self._lastlog[key] = (last, held + 1)
                return ok, reason, user
            self._lastlog[key] = (now, 0)
            if len(self._lastlog) > 5000:
                self._lastlog.clear()
        extra = {"repeat": held} if held else {}
        self.log(ev, user=user, reason=reason, proto=proto, ip=ip, slot=(token or "")[:6], **extra)
        return ok, reason, user

    # ── pembersihan & heartbeat ──────────────────────────────────────────────
    def sweep(self, now=None):
        """Bebaskan slot yang kedaluwarsa (TTL). Kembalikan daftar (user, idx)."""
        now = int(now if now is not None else time.time())
        ttl = int(self.cfg["ttl_seconds"])
        ended = []
        c = self._conn()
        try:
            c.execute("BEGIN IMMEDIATE")
            rows = c.execute("SELECT username,idx,ip,bound_at,last_seen FROM slots "
                             "WHERE sig IS NOT NULL AND (last_seen IS NULL OR ?-last_seen > ?)", (now, ttl)).fetchall()
            for r in rows:
                c.execute("UPDATE slots SET sig=NULL WHERE username=? AND idx=?", (r["username"], r["idx"]))
                ended.append((r["username"], r["idx"], r["ip"], (r["last_seen"] or now) - (r["bound_at"] or now)))
            sttl = int(self.cfg.get("shared_ttl_seconds", 300))
            orows = c.execute("SELECT o.token,o.sig,o.ip,o.bound_at,o.last_seen,s.username FROM origins o "
                              "JOIN slots s ON s.token=o.token WHERE ?-o.last_seen>?", (now, sttl)).fetchall()
            for r in orows:
                c.execute("DELETE FROM origins WHERE token=? AND sig=?", (r["token"], r["sig"]))
                ended.append((r["username"], 0, r["ip"], (r["last_seen"] or now) - (r["bound_at"] or now)))
            c.execute("COMMIT")
        except Exception:
            try: c.execute("ROLLBACK")
            except Exception: pass
            raise
        finally:
            c.close()
        for u, i, ip, dur in ended:
            self.log("session_ended", user=u, slot=i, ip=ip, duration=dur)
        return [(u, i) for u, i, _, _ in ended]

    def heartbeat_account(self, username, now=None):
        """Trafik akun bergerak -> perpanjang slot yang terakhir terlihat dalam hold_seconds."""
        now = int(now if now is not None else time.time())
        hold = int(self.cfg["hold_seconds"])
        c = self._conn()
        try:
            c.execute("UPDATE slots SET last_seen=? WHERE username=? AND sig IS NOT NULL AND ?-last_seen<=?",
                      (now, username, now, hold))
        finally:
            c.close()

    def active_devices(self, username, now=None):
        now = int(now if now is not None else time.time())
        ttl = int(self.cfg["ttl_seconds"])
        sttl = int(self.cfg.get("shared_ttl_seconds", 300))
        c = self._conn()
        try:
            n = c.execute("SELECT COUNT(*) FROM slots WHERE username=? AND sig IS NOT NULL AND ?-last_seen<=?",
                          (username, now, ttl)).fetchone()[0]
            n += c.execute("SELECT COUNT(*) FROM origins o JOIN slots s ON s.token=o.token "
                           "WHERE s.username=? AND ?-o.last_seen<=?", (username, now, sttl)).fetchone()[0]
            return n
        finally:
            c.close()

    def limited_credentials(self):
        """{user: {proto: secret}} untuk akun yang diatur MaxLogin (limit > 0, aktif)."""
        sd = self.cfg["script_dir"]; out = {}
        for proto in PROTOS:
            f = os.path.join(sd, "db", proto + ".db")
            if not os.path.isfile(f):
                continue
            for line in open(f):
                p = line.rstrip("\n").split("|")
                if len(p) < 5 or not p[0] or not p[1]:
                    continue
                try:
                    if int(p[4]) <= 0:
                        continue
                except ValueError:
                    continue
                out.setdefault(p[0], {})[proto] = p[1]
        return out

    # ── sinkron dari database akun script ────────────────────────────────────
    def sync_from_script(self, now=None):
        """Baca db vmess/vless/trojan script; satu akun = satu username (lintas protokol)."""
        sd = self.cfg["script_dir"]
        accounts = {}   # username -> dict(max, exp, disabled)
        for proto in PROTOS:
            f = os.path.join(sd, "db", proto + ".db")
            if not os.path.isfile(f):
                continue
            with open(f) as fh:
                for line in fh:
                    p = line.rstrip("\n").split("|")
                    if len(p) < 5 or not p[0]:
                        continue
                    user, exp, lim = p[0], p[2], p[4]
                    try:
                        lim = int(lim)
                    except ValueError:
                        lim = 0
                    a = accounts.setdefault(user, {"max": 0, "exp": None, "disabled": False})
                    a["max"] = max(a["max"], lim)
                    try:
                        e = int(time.mktime(time.strptime(exp, "%Y-%m-%d"))) + 86400
                        a["exp"] = e if a["exp"] is None else max(a["exp"], e)
                    except ValueError:
                        pass
                    if os.path.exists(os.path.join(sd, ".quota-disabled", "%s_%s" % (proto, user))):
                        a["disabled"] = True
        for user, a in accounts.items():
            if a["max"] <= 0:
                continue   # 0 = tanpa batas, tidak diatur MaxLogin
            self.upsert_account(user, a["max"], enabled=not a["disabled"], expires_at=a["exp"], now=now)
        # akun yang sudah dihapus dari db script: cabut kredensialnya
        c = self._conn()
        try:
            known = {r["username"] for r in c.execute("SELECT username FROM accounts")}
        finally:
            c.close()
        for user in known - {u for u, a in accounts.items() if a["max"] > 0}:
            self.disable_account(user, "removed_from_script_db")
        return len([1 for a in accounts.values() if a["max"] > 0])
