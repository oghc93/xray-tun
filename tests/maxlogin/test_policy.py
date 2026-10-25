"""Tes unit MaxLogin (kebijakan, registry, concurrency, expiry, restart, galat).
Jalankan: python3 -m unittest discover -s tests/maxlogin -v
CATATAN: ini tes UNIT atas logika kebijakan. Tes dengan Nginx dan Xray sungguhan ada di integration.sh."""
import json, os, sys, tempfile, threading, time, unittest, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from multiprocessing import Pool
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "addon", "maxlogin"))
from maxlogin_core import MaxLoginCore, DEFAULT_CONFIG, group_key  # noqa
import maxlogin_service as svc  # noqa


def mkcfg(tmp, **kw):
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(db_path=os.path.join(tmp, "ml.db"), log_path=os.path.join(tmp, "ml.log"),
               script_dir=tmp, ip_group_bits=32, ip_pools="", ttl_seconds=100, hold_seconds=600,
               xray_stats=False)
    cfg.update(kw)
    return cfg


def _worker(args):          # untuk tes multi-proses
    cfg, token, ip = args
    return MaxLoginCore(cfg).authorize(token, "vless", ip)[0]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cfg = mkcfg(self.tmp)
        self.core = MaxLoginCore(self.cfg)

    def toks(self, user):
        return [t["token"] for t in self.core.tokens(user)]


class TestLimits(Base):
    def _fill(self, n):
        self.core.upsert_account("budi", n)
        t = self.toks("budi")
        self.assertEqual(len(t), n)
        for i, tok in enumerate(t):                      # n perangkat, tiap perangkat satu slot
            self.assertTrue(self.core.authorize(tok, "vless", "10.0.0.%d" % (i + 1), now=1000)[0])
        return t

    def test_limit_1_2_3_new_device_rejected_old_stay(self):
        for n in (1, 2, 3):
            self.setUp()
            t = self._fill(n)
            for extra in range(n):                       # perangkat baru memakai slot mana pun: ditolak
                ok, why, _ = self.core.authorize(t[extra], "vless", "99.9.9.%d" % extra, now=1010)
                self.assertFalse(ok); self.assertEqual(why, "device_limit")
            for i, tok in enumerate(t):                  # perangkat lama tetap diizinkan
                self.assertTrue(self.core.authorize(tok, "vless", "10.0.0.%d" % (i + 1), now=1020)[0])
            self.assertEqual(self.core.active_devices("budi", now=1020), n)

    def test_many_connections_same_device_count_once(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        for i in range(50):
            self.assertTrue(self.core.authorize(tok, "vless", "10.0.0.5", now=1000 + i)[0])
        self.assertEqual(self.core.active_devices("budi", now=1050), 1)

    def test_cross_protocol_shared_limit(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        self.assertTrue(self.core.authorize(tok, "vless", "10.0.0.5", now=1000)[0])
        self.assertTrue(self.core.authorize(tok, "vmess", "10.0.0.5", now=1001)[0])    # perangkat sama
        self.assertTrue(self.core.authorize(tok, "trojan", "10.0.0.5", now=1002)[0])
        for p in ("vless", "vmess", "trojan"):                                          # perangkat lain
            self.assertFalse(self.core.authorize(tok, p, "10.0.0.6", now=1003)[0])

    def test_same_carrier_pool_counts_as_one_device(self):
        c = MaxLoginCore(mkcfg(self.tmp, ip_pools="112.215,140.213", ip_group_bits=16))
        c.upsert_account("toke", 1)
        tok = c.tokens("toke")[0]["token"]
        self.assertTrue(c.authorize(tok, "trojan", "112.215.209.119", now=1000)[0])
        self.assertTrue(c.authorize(tok, "trojan", "140.213.99.99", now=1001)[0])
        self.assertFalse(c.authorize(tok, "trojan", "36.70.1.2", now=1002)[0])

    def test_unknown_and_bad_tokens(self):
        self.assertEqual(self.core.authorize("x" * 24, "vless", "1.1.1.1")[1], "unknown_token")

    def test_reducing_limit_revokes_extra_slots(self):
        self.core.upsert_account("budi", 3)
        t = self.toks("budi")
        self.core.upsert_account("budi", 1)
        self.assertEqual(self.core.authorize(t[2], "vless", "1.1.1.1", now=1)[1], "token_revoked")
        self.assertTrue(self.core.authorize(t[0], "vless", "1.1.1.1", now=1)[0])


class TestLifecycle(Base):
    def test_session_expiry_frees_slot_and_cleanup(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        self.assertTrue(self.core.authorize(tok, "vless", "10.0.0.1", now=1000)[0])
        self.assertFalse(self.core.authorize(tok, "vless", "10.0.0.2", now=1050)[0])
        self.assertEqual(self.core.sweep(now=1050), [])                       # belum kedaluwarsa
        self.assertEqual(self.core.sweep(now=1101), [("budi", 0)])            # TTL 100 dtk lewat
        self.assertEqual(self.core.active_devices("budi", now=1101), 0)
        ok, why, _ = self.core.authorize(tok, "vless", "10.0.0.2", now=1102)  # perangkat baru kini boleh
        self.assertTrue(ok); self.assertEqual(why, "bound")

    def test_expired_slot_rebinds_even_without_sweep(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        self.core.authorize(tok, "vless", "10.0.0.1", now=1000)
        self.assertTrue(self.core.authorize(tok, "vless", "10.0.0.2", now=1200)[0])

    def test_heartbeat_extends_session(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        self.core.authorize(tok, "vless", "10.0.0.1", now=1000)
        self.core.heartbeat_account("budi", now=1090)
        self.assertEqual(self.core.sweep(now=1150), [])
        self.assertFalse(self.core.authorize(tok, "vless", "10.0.0.2", now=1150)[0])

    def test_account_expired_disabled_revoked_credentials(self):
        self.core.upsert_account("budi", 1, expires_at=2000)
        tok = self.toks("budi")[0]
        self.assertTrue(self.core.authorize(tok, "vless", "1.1.1.1", now=1999)[0])
        self.assertEqual(self.core.authorize(tok, "vless", "1.1.1.1", now=2000)[1], "account_expired")
        self.core.upsert_account("budi", 1)
        self.core.disable_account("budi")
        self.assertEqual(self.core.authorize(tok, "vless", "1.1.1.1")[1], "account_disabled")
        self.core.upsert_account("budi", 1, enabled=True)
        new = self.core.rotate_token("budi", 0)
        self.assertEqual(self.core.authorize(tok, "vless", "1.1.1.1")[1], "unknown_token")   # lama dicabut
        self.assertTrue(self.core.authorize(new, "vless", "1.1.1.1")[0])

    def test_restart_keeps_state(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        self.core.authorize(tok, "vless", "10.0.0.1", now=time.time())
        core2 = MaxLoginCore(self.cfg)                       # "restart service"
        self.assertFalse(core2.authorize(tok, "vless", "10.0.0.2")[0])
        self.assertTrue(core2.authorize(tok, "vless", "10.0.0.1")[0])

    def test_log_records_allow_deny_end(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        self.core.authorize(tok, "vless", "10.0.0.1", now=1000)
        self.core.authorize(tok, "vless", "10.0.0.2", now=1001)
        self.core.sweep(now=1500)
        ev = [json.loads(l)["event"] for l in open(self.cfg["log_path"])]
        self.assertIn("login_allowed", ev); self.assertIn("login_denied", ev); self.assertIn("session_ended", ev)


class TestConcurrency(Base):
    def test_threads_cannot_exceed_limit(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        with ThreadPoolExecutor(32) as ex:
            res = list(ex.map(lambda i: self.core.authorize(tok, "vless", "10.1.%d.%d" % (i // 250, i % 250 + 1), now=1000)[0], range(200)))
        self.assertEqual(sum(res), 1)

    def test_processes_cannot_exceed_limit(self):
        self.core.upsert_account("budi", 2)
        t = self.toks("budi")
        jobs = [(self.cfg, t[i % 2], "10.2.0.%d" % (i + 1)) for i in range(60)]
        with Pool(8) as p:
            res = p.map(_worker, jobs)
        self.assertEqual(sum(res), 2)          # tepat satu perangkat per slot
        self.assertEqual(self.core.active_devices("budi", now=time.time()), 2)


class TestSync(Base):
    def _w(self, name, text):
        with open(os.path.join(self.tmp, "db", name), "w") as f:
            f.write(text)

    def test_sync_from_script_db_and_quota_disabled(self):
        os.makedirs(os.path.join(self.tmp, "db"))
        self._w("vless.db", "a|u|2099-01-01|2026-01-01|2|0\nfree|u|2099-01-01|2026-01-01|0|0\nq|u|2099-01-01|2026-01-01|1|50\n")
        self._w("vmess.db", "a|u|2099-01-01|2026-01-01|3|0\n")
        os.makedirs(os.path.join(self.tmp, ".quota-disabled"))
        with open(os.path.join(self.tmp, ".quota-disabled", "vless_q"), "w"):
            pass
        self.assertEqual(self.core.sync_from_script(), 2)            # 'free' (0) tidak diatur
        self.assertEqual(len(self.toks("a")), 3)                      # lintas protokol: ambil yang terbesar
        self.assertEqual(self.core.authorize(self.toks("q")[0], "vless", "1.1.1.1")[1], "account_disabled")
        os.remove(os.path.join(self.tmp, "db", "vless.db"))           # masih ada di vmess.db -> tetap aktif
        self.core.sync_from_script()
        self.assertTrue(self.core.authorize(self.toks("a")[0], "vless", "1.1.1.9")[0])
        os.remove(os.path.join(self.tmp, "db", "vmess.db"))           # hilang dari semua db -> kredensial dicabut
        self.core.sync_from_script()
        self.assertEqual(self.core.authorize(self.toks("a")[0], "vless", "1.1.1.1")[1], "account_disabled")


class TestServiceErrors(Base):
    def _http(self, core, uri, ip="1.1.1.1"):
        srv = ThreadingHTTPServer(("127.0.0.1", 0), svc.make_handler(core))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        req = urllib.request.Request("http://127.0.0.1:%d/auth" % srv.server_port,
                                     headers={"X-Original-URI": uri, "X-Real-IP": ip})
        try:
            with urllib.request.urlopen(req) as r:
                code = r.status
        except urllib.error.HTTPError as e:
            code = e.code
            e.close()
        srv.shutdown()
        srv.server_close()
        return code

    def test_http_allow_deny_and_bad_path(self):
        self.core.upsert_account("budi", 1)
        tok = self.toks("budi")[0]
        self.assertEqual(self._http(self.core, "/vless-ws/" + tok, "10.0.0.1"), 200)
        self.assertEqual(self._http(self.core, "/trojan-ws/" + tok, "10.0.0.2"), 403)
        self.assertEqual(self._http(self.core, "/vless-ws/short", "10.0.0.2"), 403)

    def test_internal_error_policy(self):
        for mode, want in (("allow", 200), ("deny", 403)):
            core = MaxLoginCore(mkcfg(self.tmp, on_error=mode))
            def boom(*a, **k): raise RuntimeError("db rusak")
            core.authorize = boom
            self.assertEqual(self._http(core, "/vless-ws/" + "a" * 24), want)


class TestShared(Base):
    """Mode LINK TUNGGAL: limit >= shared_min_limit -> satu token, hingga N asal bersamaan."""
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cfg = mkcfg(self.tmp, shared_min_limit=10, shared_ttl_seconds=100)
        self.core = MaxLoginCore(self.cfg)

    def test_one_token_up_to_n_origins_then_rejected(self):
        self.core.upsert_account("sample", 12)
        self.assertEqual(self.core.account_mode("sample"), "shared")
        t = self.toks("sample"); self.assertEqual(len(t), 1)
        for i in range(12):
            ok, why, _ = self.core.authorize(t[0], "vless", "10.1.0.%d" % i, now=1000)
            self.assertTrue(ok, i); self.assertEqual(why, "bound")
        ok, why, _ = self.core.authorize(t[0], "vless", "10.9.9.9", now=1010)
        self.assertFalse(ok); self.assertEqual(why, "device_limit")
        for i in range(12):                              # asal lama tetap diizinkan
            self.assertTrue(self.core.authorize(t[0], "vless", "10.1.0.%d" % i, now=1020)[0])
        self.assertEqual(self.core.active_devices("sample", now=1020), 12)

    def test_many_connections_same_origin_count_once_and_cross_protocol(self):
        self.core.upsert_account("sample", 10)
        tok = self.toks("sample")[0]
        for _ in range(50):
            self.assertTrue(self.core.authorize(tok, "vless", "10.1.0.1", now=1000)[0])
        for i, proto in enumerate(("vless", "vmess", "trojan") * 3):   # 9 asal lagi lintas protokol
            self.assertTrue(self.core.authorize(tok, proto, "10.2.0.%d" % i, now=1000)[0])
        self.assertEqual(self.core.active_devices("sample", now=1000), 10)
        self.assertFalse(self.core.authorize(tok, "trojan", "10.3.0.1", now=1000)[0])

    def test_origin_expiry_frees_seat_and_logs(self):
        self.core.upsert_account("sample", 10)
        tok = self.toks("sample")[0]
        for i in range(10):
            self.core.authorize(tok, "vless", "10.1.0.%d" % i, now=1000)
        self.assertFalse(self.core.authorize(tok, "vless", "10.9.9.9", now=1050)[0])
        # 10.1.0.0 aktif terus; sisanya diam lewat shared_ttl_seconds=100
        self.core.authorize(tok, "vless", "10.1.0.0", now=1140)
        ok, why, _ = self.core.authorize(tok, "vless", "10.9.9.9", now=1150)
        self.assertTrue(ok)
        ev = [json.loads(l) for l in open(self.cfg["log_path"])]
        self.assertTrue(any(e["event"] == "session_ended" for e in ev))
        self.assertEqual(self.core.active_devices("sample", now=1150), 2)

    def test_sweep_clears_origins(self):
        self.core.upsert_account("sample", 10)
        tok = self.toks("sample")[0]
        for i in range(3):
            self.core.authorize(tok, "vless", "10.1.0.%d" % i, now=1000)
        self.assertEqual(len(self.core.sweep(now=1500)), 3)
        self.assertEqual(self.core.active_devices("sample", now=1500), 0)

    def test_mode_threshold_and_switching(self):
        self.core.upsert_account("u", 9)
        self.assertEqual((self.core.account_mode("u"), len(self.toks("u"))), ("device", 9))
        self.core.upsert_account("u", 10)
        self.assertEqual(self.core.account_mode("u"), "shared")
        live = [t for t in self.core.tokens("u") if not t["revoked"]]
        self.assertEqual(len(live), 1)
        tok0 = live[0]["token"]
        self.core.upsert_account("u", 2)
        self.assertEqual(self.core.account_mode("u"), "device")
        self.assertEqual(len([t for t in self.core.tokens("u") if not t["revoked"]]), 2)
        self.assertEqual(self.core.tokens("u")[0]["token"], tok0)       # token slot 0 tetap
        # shared_min_limit = 0 mematikan mode tunggal
        self.setUp(); self.core.cfg["shared_min_limit"] = 0
        self.core.upsert_account("v", 12)
        self.assertEqual((self.core.account_mode("v"), len(self.toks("v"))), ("device", 12))

    def test_switch_clears_bindings(self):
        self.core.upsert_account("u", 12)
        tok = self.toks("u")[0]
        self.core.authorize(tok, "vless", "10.1.0.1", now=1000)
        self.core.upsert_account("u", 2)
        self.assertEqual(self.core.active_devices("u", now=1000), 0)

    def test_concurrent_distinct_origins_exact_limit(self):
        self.core.upsert_account("sample", 10)
        tok = self.toks("sample")[0]
        with ThreadPoolExecutor(40) as ex:
            res = list(ex.map(lambda i: self.core.authorize(tok, "vless", "10.5.%d.1" % i, now=1000)[0], range(40)))
        self.assertEqual(sum(res), 10)
        self.assertEqual(self.core.active_devices("sample", now=1000), 10)

    def test_processes_exact_limit(self):
        self.core.upsert_account("sample", 10)
        tok = self.toks("sample")[0]
        with Pool(8) as pool:
            res = pool.map(_worker, [(self.cfg, tok, "10.6.%d.1" % i) for i in range(30)])
        self.assertEqual(sum(res), 10)

    def test_disable_rotate_clear_origins(self):
        self.core.upsert_account("sample", 10)
        tok = self.toks("sample")[0]
        self.core.authorize(tok, "vless", "10.1.0.1", now=1000)
        new = self.core.rotate_token("sample", 0)
        self.assertNotEqual(new, tok)
        self.assertEqual(self.core.active_devices("sample", now=1000), 0)
        self.assertEqual(self.core.authorize(tok, "vless", "10.1.0.1", now=1001)[1], "unknown_token")
        self.core.authorize(new, "vless", "10.1.0.1", now=1002)
        self.core.disable_account("sample")
        self.assertEqual(self.core.authorize(new, "vless", "10.1.0.1", now=1003)[1], "account_disabled")
        self.assertEqual(self.core.active_devices("sample", now=1003), 0)

    def test_expired_account_rejected_in_shared_mode(self):
        self.core.upsert_account("sample", 10, expires_at=2000)
        tok = self.toks("sample")[0]
        self.assertTrue(self.core.authorize(tok, "vless", "10.1.0.1", now=1000)[0])
        self.assertEqual(self.core.authorize(tok, "vless", "10.1.0.1", now=2001)[1], "account_expired")

    def test_cli_tokens_prefix_and_old_db_migration(self):
        import io, contextlib, sqlite3
        self.core.upsert_account("sample", 10); self.core.upsert_account("jual", 2)
        cfgf = os.path.join(self.tmp, "c.json"); json.dump(self.cfg, open(cfgf, "w"))
        os.environ["MAXLOGIN_CONFIG"] = cfgf
        def run(*a):
            b = io.StringIO()
            with contextlib.redirect_stdout(b): svc.main(list(a))
            return b.getvalue().split()
        self.assertTrue(run("tokens", "sample")[0].startswith("shared:"))
        j = run("tokens", "jual"); self.assertEqual(len(j), 2); self.assertFalse(j[0].startswith("shared:"))
        # DB lama tanpa kolom mode: dimigrasi otomatis, akun lama jadi per-perangkat
        old = os.path.join(self.tmp, "old.db"); c = sqlite3.connect(old)
        c.executescript("CREATE TABLE accounts(username TEXT PRIMARY KEY,max_devices INTEGER NOT NULL DEFAULT 1,"
                        "enabled INTEGER NOT NULL DEFAULT 1,expires_at INTEGER,updated_at INTEGER NOT NULL DEFAULT 0);"
                        "INSERT INTO accounts(username,max_devices) VALUES('lama',2);")
        c.commit(); c.close()
        core2 = MaxLoginCore(mkcfg(self.tmp, db_path=old))
        self.assertEqual(core2.account_mode("lama"), "device")


class TestGroupKey(unittest.TestCase):
    def test_keys(self):
        self.assertEqual(group_key("140.213.37.227", 16, ""), group_key("140.213.45.191", 16, ""))
        self.assertNotEqual(group_key("36.70.1.2", 16, ""), group_key("114.5.6.7", 16, ""))
        self.assertEqual(group_key("2404:8000:1:2:a::1", 16, ""), group_key("2404:8000:1:2:b::9", 16, ""))


if __name__ == "__main__":
    unittest.main()
