import http.client
import json
import os
import shutil
import tempfile
import threading
import unittest
from urllib.parse import quote

import icloud_bridge as b

TOKEN = "secret-token"

# Keep in sync with tests/test_syncplan.lua SYNCABLE_CASES.
SYNCABLE_CASES = [
    ("Dune.epub", True),
    ("Fiction/Dune.EPUB", True),
    ("Fiction/Dune.sdr/metadata.epub.lua", True),
    ("Fiction/Dune.sdr/cover.jpg", True),
    ("Fiction/Dune.sdr/metadata.epub.lua.old", False),
    ("Dune.epub.part", False),
    ("notes.jpg", False),
    ("noext", False),
    (".hidden.epub", False),
    (".koreader-trash/x/Dune.epub", False),
    ("a/../Dune.epub", False),
    ("./Dune.epub", False),
    ("/abs/Dune.epub", False),
    ("a//Dune.epub", False),
    ("", False),
    ("What? A book.epub", False),
    ("Café – Ünïcode.pdf", True),
]


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root)

    def touch(self, rel, data=b"x", mtime=None):
        full = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(data)
        if mtime:
            os.utime(full, (mtime, mtime))
        return full

    def test_is_syncable(self):
        for rel, want in SYNCABLE_CASES:
            with self.subTest(rel=rel):
                self.assertEqual(b.is_syncable(rel), want)

    def test_resolve_safe(self):
        self.assertTrue(b.resolve_safe(self.root, "a/b.epub").endswith("/a/b.epub"))
        self.assertIsNone(b.resolve_safe(self.root, "../x.epub"))
        self.assertIsNone(b.resolve_safe(self.root, "/etc/passwd"))
        self.assertIsNone(b.resolve_safe(self.root, ""))

    def test_resolve_safe_symlink_escape(self):
        outside = tempfile.mkdtemp()
        try:
            os.symlink(outside, os.path.join(self.root, "link"))
            self.assertIsNone(b.resolve_safe(self.root, "link/x.epub"))
        finally:
            shutil.rmtree(outside)

    def test_manifest_filters_and_sorts(self):
        self.touch("b.epub", b"12345", mtime=1000)
        self.touch("A/a.pdf", b"1", mtime=2000)
        self.touch("A/a.sdr/metadata.pdf.lua", b"meta")
        self.touch("A/a.sdr/metadata.pdf.lua.old")
        self.touch("pic.jpg")
        self.touch(".DS_Store")
        self.touch(".koreader-trash/run/old.epub")
        self.touch(".hidden/x.epub")
        m = b.build_manifest(self.root)
        self.assertEqual(m["version"], 1)
        self.assertEqual([f["path"] for f in m["files"]],
                         ["A/a.pdf", "A/a.sdr/metadata.pdf.lua", "b.epub"])
        by = {f["path"]: f for f in m["files"]}
        self.assertEqual(by["b.epub"]["size"], 5)
        self.assertEqual(by["b.epub"]["mtime"], 1000)
        self.assertEqual(m["pending"], [])

    def test_manifest_icloud_stub_is_pending_and_triggers_download(self):
        self.touch("Sci/.Big Atlas.pdf.icloud")
        self.touch(".junk.jpg.icloud")
        calls = []
        dl = b.Downloader(runner=calls.append)
        m = b.build_manifest(self.root, dl)
        self.assertEqual(m["pending"], ["Sci/Big Atlas.pdf"])
        self.assertEqual(m["files"], [])
        b.build_manifest(self.root, dl)
        self.assertEqual(len(calls), 1, "throttled to once per minute")
        self.assertTrue(calls[0].endswith("Sci/Big Atlas.pdf"))

    def test_manifest_unreadable_dir_raises(self):
        self.touch("Locked/a.epub")
        locked = os.path.join(self.root, "Locked")
        os.chmod(locked, 0)
        try:
            with self.assertRaises(OSError):
                b.build_manifest(self.root)
        finally:
            os.chmod(locked, 0o755)

    def test_manifest_empty_root(self):
        m = b.build_manifest(self.root)
        self.assertEqual((m["files"], m["pending"]), ([], []))


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.server = b.make_server(self.root, TOKEN, "127.0.0.1", 0,
                                    downloader=b.Downloader(runner=lambda p: None))
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.root)

    def req(self, method, path, body=None, headers=None, token=TOKEN):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict(headers or {})
        if token is not None:
            h["X-Sync-Token"] = token
        conn.request(method, path, body=body, headers=h)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, data

    def write(self, rel, data):
        full = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(data)

    def test_health_needs_no_token(self):
        status, data = self.req("GET", "/health", token=None)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data), {"ok": True})

    def test_bad_or_missing_token(self):
        self.assertEqual(self.req("GET", "/manifest", token=None)[0], 401)
        self.assertEqual(self.req("GET", "/manifest", token="nope")[0], 401)

    def test_missing_root(self):
        shutil.rmtree(self.root)
        status, data = self.req("GET", "/manifest")
        self.assertEqual(status, 500)
        os.makedirs(self.root)

    def test_unreadable_root_is_500_not_empty(self):
        os.chmod(self.root, 0)
        try:
            self.assertEqual(self.req("GET", "/manifest")[0], 500)
        finally:
            os.chmod(self.root, 0o755)

    def test_manifest_and_get(self):
        self.write("Fic/Dune Ünï.epub", b"book-bytes")
        status, data = self.req("GET", "/manifest")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)["files"][0]["path"], "Fic/Dune Ünï.epub")
        status, data = self.req("GET", "/file/" + quote("Fic/Dune Ünï.epub"))
        self.assertEqual((status, data), (200, b"book-bytes"))

    def test_get_missing_and_forbidden(self):
        self.assertEqual(self.req("GET", "/file/nope.epub")[0], 404)
        self.assertEqual(self.req("GET", "/file/" + quote("../x.epub", safe=""))[0], 403)
        self.assertEqual(self.req("GET", "/file/%2E%2E/x.epub")[0], 403)
        self.assertEqual(self.req("GET", "/file/pic.jpg")[0], 403)

    def test_put_roundtrip_preserves_bytes_and_mtime(self):
        body = os.urandom(200_000)
        status, data = self.req("PUT", "/file/" + quote("New/Book.sdr/metadata.epub.lua"),
                                body=body, headers={"X-Mtime": "1700000000"})
        self.assertEqual(status, 201)
        info = json.loads(data)
        self.assertEqual(info, {"path": "New/Book.sdr/metadata.epub.lua",
                                "size": len(body), "mtime": 1700000000})
        full = os.path.join(self.root, "New/Book.sdr/metadata.epub.lua")
        with open(full, "rb") as f:
            self.assertEqual(f.read(), body)
        self.assertEqual(int(os.stat(full).st_mtime), 1700000000)
        self.assertEqual(sorted(os.listdir(os.path.dirname(full))), ["metadata.epub.lua"])

    def test_put_overwrites(self):
        self.write("a.epub", b"old")
        self.req("PUT", "/file/a.epub", body=b"newer", headers={"X-Mtime": "5"})
        with open(os.path.join(self.root, "a.epub"), "rb") as f:
            self.assertEqual(f.read(), b"newer")

    def test_put_incomplete_body_leaves_nothing(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.putrequest("PUT", "/file/short.epub")
        conn.putheader("X-Sync-Token", TOKEN)
        conn.putheader("X-Mtime", "5")
        conn.putheader("Content-Length", "100")
        conn.endheaders()
        conn.send(b"only-ten!!")
        conn.sock.shutdown(1)  # half-close: server sees EOF early
        resp = conn.getresponse()
        self.assertEqual(resp.status, 400)
        conn.close()
        self.assertEqual(os.listdir(self.root), [])

    def test_put_requires_headers_and_syncable_path(self):
        self.assertEqual(self.req("PUT", "/file/a.epub", body=b"x")[0], 400)
        self.assertEqual(self.req("PUT", "/file/evil.sh", body=b"x",
                                  headers={"X-Mtime": "1"})[0], 403)
        self.assertEqual(self.req("PUT", "/manifest", body=b"x",
                                  headers={"X-Mtime": "1"})[0], 405)

    def test_delete_moves_to_trash_and_prunes(self):
        self.write("Fic/Dune.sdr/metadata.epub.lua", b"m")
        status, _ = self.req("DELETE", "/file/Fic/Dune.sdr/metadata.epub.lua",
                             headers={"X-Run-Id": "run1"})
        self.assertEqual(status, 204)
        self.assertFalse(os.path.exists(os.path.join(self.root, "Fic")))
        self.assertTrue(os.path.isfile(os.path.join(
            self.root, ".koreader-trash/run1/Fic/Dune.sdr/metadata.epub.lua")))
        m = json.loads(self.req("GET", "/manifest")[1])
        self.assertEqual(m["files"], [])

    def test_delete_missing_is_idempotent(self):
        self.assertEqual(self.req("DELETE", "/file/gone.epub")[0], 204)

    def test_post_not_allowed(self):
        self.assertEqual(self.req("POST", "/file/a.epub", body=b"x")[0], 405)


if __name__ == "__main__":
    unittest.main()
