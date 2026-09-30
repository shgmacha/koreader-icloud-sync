#!/usr/bin/env python3
"""KOReader iCloud bridge.

Serves one iCloud Drive folder over HTTP on the LAN so the icloudsync.koplugin
running on a Kindle can two-way sync with it.

Endpoints (all but /health need the X-Sync-Token header):
  GET    /health            -> {"ok": true}
  GET    /manifest          -> {"version": 1, "files": [...], "pending": [...]}
  GET    /file/<path>       -> file bytes
  PUT    /file/<path>       -> upload (headers: Content-Length, X-Mtime)
  DELETE /file/<path>       -> move to <root>/.koreader-trash/<run-id>/<path>

Stdlib only; runs on the macOS system python3 (3.9).
"""

import argparse
import hmac
import json
import logging
import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

MANIFEST_VERSION = 1
TRASH_DIR = ".koreader-trash"
ALLOWED_EXTS = {
    "epub", "pdf", "mobi", "azw", "azw3", "fb2", "cbz", "cbr", "djvu",
    "txt", "rtf", "docx", "html", "md",
}
FAT_ILLEGAL = set(':*?"<>|\\')
CHUNK = 64 * 1024
BRCTL_THROTTLE = 60

DEFAULT_CONFIG = os.path.expanduser("~/.config/koreader-icloud-bridge/config.json")
DEFAULT_ROOT = os.path.expanduser(
    "~/Library/Mobile Documents/com~apple~CloudDocs/KOReader")

log = logging.getLogger("icloud_bridge")


# --- pure helpers -----------------------------------------------------------

def is_syncable(rel):
    """Shared sync rule (mirrored in syncplan.lua's isSyncable)."""
    if not isinstance(rel, str) or rel == "" or rel.startswith("/"):
        return False
    parts = rel.split("/")
    for seg in parts:
        if seg in ("", ".", "..") or seg.startswith("."):
            return False
        if any(c in FAT_ILLEGAL for c in seg):
            return False
    name = parts[-1]
    if name.endswith(".part") or name.endswith(".old"):
        return False
    if any(seg.endswith(".sdr") for seg in parts[:-1]):
        return True
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return ext in ALLOWED_EXTS


def resolve_safe(root, rel):
    """Absolute path for rel inside root, or None if it would escape root."""
    root_real = os.path.realpath(root)
    target = os.path.realpath(os.path.join(root_real, rel))
    if target == root_real or not target.startswith(root_real + os.sep):
        return None
    return target


def _run_brctl(path):
    try:
        subprocess.Popen(["brctl", "download", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        log.warning("brctl download failed for %s: %s", path, e)


class Downloader:
    """Asks iCloud to materialize evicted files, at most once per file per minute."""

    def __init__(self, runner=_run_brctl, throttle=BRCTL_THROTTLE, clock=time.time):
        self.runner = runner
        self.throttle = throttle
        self.clock = clock
        self._last = {}
        self._lock = threading.Lock()

    def request(self, path):
        now = self.clock()
        with self._lock:
            if now - self._last.get(path, -1e18) < self.throttle:
                return
            self._last[path] = now
        self.runner(path)


def _raise(err):
    raise err


def build_manifest(root, downloader=None):
    """Raises OSError if any directory can't be read: a partial listing would
    look like deletions to the client."""
    files, pending = [], []
    os.listdir(root)  # surface permission errors on the root itself
    for dirpath, dirnames, filenames in os.walk(root, onerror=_raise):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir.replace(os.sep, "/") + "/"
        for name in filenames:
            # Evicted iCloud file: ".Name.ext.icloud"
            if name.startswith(".") and name.endswith(".icloud") and len(name) > 8:
                real = name[1:-len(".icloud")]
                rel = rel_dir + real
                if is_syncable(rel):
                    pending.append(rel)
                    if downloader:
                        downloader.request(os.path.join(dirpath, real))
                continue
            rel = rel_dir + name
            if not is_syncable(rel):
                continue
            full = os.path.join(dirpath, name)
            try:
                st = os.stat(full, follow_symlinks=False)
            except OSError:
                continue
            if not os.path.isfile(full) or os.path.islink(full):
                continue
            files.append({"path": rel, "size": st.st_size, "mtime": int(st.st_mtime)})
    files.sort(key=lambda f: f["path"])
    pending.sort()
    return {
        "version": MANIFEST_VERSION,
        "root": os.path.basename(os.path.normpath(root)),
        "generated": int(time.time()),
        "files": files,
        "pending": pending,
    }


def trash_path(root, run_id, rel):
    safe_run = "".join(c if c.isalnum() or c in "-_" else "_" for c in run_id) or "run"
    return os.path.join(root, TRASH_DIR, safe_run, rel)


def prune_empty_dirs(start_dir, root):
    root_real = os.path.realpath(root)
    d = os.path.realpath(start_dir)
    while d != root_real and d.startswith(root_real + os.sep):
        try:
            os.rmdir(d)  # only succeeds when empty
        except OSError:
            break
        d = os.path.dirname(d)


# --- HTTP -------------------------------------------------------------------

class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "KOReaderICloudBridge/1"
    protocol_version = "HTTP/1.1"

    # set on the server object: root, token, downloader

    def log_message(self, fmt, *args):
        log.info("%s %s", self.address_string(), fmt % args)

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, msg):
        self._send_json(code, {"error": msg})

    def _authorized(self):
        got = self.headers.get("X-Sync-Token", "")
        return hmac.compare_digest(got.encode("utf-8"), self.server.token.encode("utf-8"))

    def _route(self):
        """Returns (kind, rel) or None after sending an error."""
        path = urlsplit(self.path).path
        if path == "/health":
            return ("health", None)
        if not self._authorized():
            self._error(401, "bad token")
            return None
        if not os.path.isdir(self.server.root):
            self._error(500, "sync root missing")
            return None
        if path == "/manifest":
            return ("manifest", None)
        if path.startswith("/file/"):
            rel = unquote(path[len("/file/"):])
            if not is_syncable(rel) or resolve_safe(self.server.root, rel) is None:
                self._error(403, "path not allowed")
                return None
            return ("file", rel)
        self._error(404, "not found")
        return None

    def do_GET(self):
        r = self._route()
        if r is None:
            return
        kind, rel = r
        if kind == "health":
            return self._send_json(200, {"ok": True})
        if kind == "manifest":
            try:
                manifest = build_manifest(self.server.root, self.server.downloader)
            except OSError as e:
                log.error("cannot list sync root: %s", e)
                return self._error(500, "cannot read sync folder: %s" % e.strerror)
            return self._send_json(200, manifest)
        full = resolve_safe(self.server.root, rel)
        if not os.path.isfile(full):
            return self._error(404, "no such file")
        size = os.path.getsize(full)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        try:
            with open(full, "rb") as f:
                shutil.copyfileobj(f, self.wfile, CHUNK)
        except (BrokenPipeError, ConnectionResetError):
            log.warning("client disconnected while downloading %s", rel)

    def do_PUT(self):
        r = self._route()
        if r is None:
            return
        kind, rel = r
        if kind != "file":
            return self._error(405, "method not allowed")
        try:
            length = int(self.headers["Content-Length"])
            mtime = int(self.headers["X-Mtime"])
            if length < 0:
                raise ValueError
        except (TypeError, ValueError):
            return self._error(400, "Content-Length and X-Mtime required")
        full = resolve_safe(self.server.root, rel)
        parent = os.path.dirname(full)
        os.makedirs(parent, exist_ok=True)
        tmp = os.path.join(parent, "." + os.path.basename(full) + ".koreader-part")
        received = 0
        try:
            with open(tmp, "wb") as f:
                while received < length:
                    chunk = self.rfile.read(min(CHUNK, length - received))
                    if not chunk:
                        break
                    f.write(chunk)
                    received += len(chunk)
        except (OSError, ConnectionResetError) as e:
            log.warning("upload of %s failed: %s", rel, e)
        if received != length:
            _silent_remove(tmp)
            self.close_connection = True
            return self._error(400, "incomplete body")
        os.replace(tmp, full)
        os.utime(full, (mtime, mtime))
        st = os.stat(full)
        log.info("stored %s (%d bytes)", rel, st.st_size)
        self._send_json(201, {"path": rel, "size": st.st_size, "mtime": int(st.st_mtime)})

    def do_DELETE(self):
        r = self._route()
        if r is None:
            return
        kind, rel = r
        if kind != "file":
            return self._error(405, "method not allowed")
        full = resolve_safe(self.server.root, rel)
        if os.path.isfile(full):
            run_id = self.headers.get("X-Run-Id") or time.strftime("%Y-%m-%d_%H%M%S")
            dest = trash_path(self.server.root, run_id, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            os.replace(full, dest)
            prune_empty_dirs(os.path.dirname(full), self.server.root)
            log.info("trashed %s", rel)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _not_allowed(self):
        self.close_connection = True
        self._error(405, "method not allowed")

    do_POST = do_PATCH = _not_allowed


def _silent_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def make_server(root, token, host="0.0.0.0", port=8765, downloader=None):
    server = ThreadingHTTPServer((host, port), BridgeHandler)
    server.daemon_threads = True
    server.root = root
    server.token = token
    server.downloader = downloader if downloader is not None else Downloader()
    return server


def load_config(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--config", default=DEFAULT_CONFIG)
    p.add_argument("--root")
    p.add_argument("--port", type=int)
    p.add_argument("--bind")
    p.add_argument("--token")
    args = p.parse_args(argv)

    cfg = load_config(args.config)
    root = os.path.expanduser(args.root or cfg.get("root") or DEFAULT_ROOT)
    port = args.port or cfg.get("port") or 8765
    bind = args.bind or cfg.get("bind") or "0.0.0.0"
    token = args.token or cfg.get("token")

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not token:
        log.error("no token configured (run install.sh or pass --token)")
        return 2
    if not os.path.isdir(root):
        log.warning("sync root %s does not exist yet", root)
    server = make_server(root, token, bind, port)
    log.info("serving %s on %s:%d", root, bind, port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
