"""Runs scripts/apps-site-release.sh against a scratch git origin and a
local stand-in for apps.goodvantage.cloud, the way the release workflow's
apps-site job does. The stand-in implements the publishing API the vendored
publisher speaks: GET files, PUT /_upload/<path> and
POST /_catalog/apps/<app>, each write needing the app's bearer token."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import unquote, urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / "apps-site-release.sh"
TOKEN = "nevermore-test-token"
LABEL = "macOS 26 or later (Apple silicon and Intel)"


class StandInSite:
    """Serves and stores files under `root`; records every write in order."""

    def __init__(self, root):
        self.root = root.resolve()
        self.writes = []
        site = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body=b""):
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def target(self, path):
                target = (site.root / unquote(path).lstrip("/")).resolve()
                return target if site.root in target.parents else None

            def authorized(self):
                return self.headers.get("Authorization") == f"Bearer {TOKEN}"

            def do_GET(self):
                target = self.target(urlsplit(self.path).path)
                if target is None or not target.is_file():
                    return self.reply(404)
                self.reply(200, target.read_bytes())

            def do_PUT(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                path = urlsplit(self.path).path
                if not path.startswith("/_upload/"):
                    return self.reply(405)
                if not self.authorized():
                    return self.reply(401)
                # An app's token writes only that app's files.
                if not path.startswith("/_upload/nevermore/"):
                    return self.reply(403)
                target = self.target(path[len("/_upload"):])
                if target is None:
                    return self.reply(400)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(body)
                site.writes.append(path[len("/_upload/"):])
                self.reply(201)

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if urlsplit(self.path).path != "/_catalog/apps/nevermore":
                    return self.reply(404)
                if not self.authorized():
                    return self.reply(401)
                registration = json.loads(body)
                index_file = site.root / "apps.json"
                index = json.loads(index_file.read_text()) if index_file.exists() else {"schema": 1, "apps": []}
                entry = next((a for a in index["apps"] if a["id"] == "nevermore"), None)
                if entry is None:
                    entry = {"id": "nevermore"}
                    index["apps"].append(entry)
                channels = set(entry.get("channels", [])) | set(registration["channels"])
                entry.update({k: v for k, v in registration.items() if k != "channels"})
                entry["channels"] = [c for c in ("stable", "beta") if c in channels]
                index_file.write_text(json.dumps(index))
                site.writes.append("apps.json")
                self.reply(200, json.dumps({"app": entry}).encode())

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    def json(self, path):
        return json.loads((self.root / path).read_text())


class AppsSiteReleaseTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="NevermoreAppsSite-")
        self.root = Path(self.folder.name)
        self.git_env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        # A bare origin holding the tags, and a shallow clone without them,
        # as actions/checkout leaves the job's working tree.
        source = self.root / "source"
        self.git("init", "-q", "-b", "main", str(source), cwd=self.root)
        (source / "README").write_text("Nevermore\n")
        self.git("add", "README", cwd=source)
        self.git("commit", "-q", "-m", "Initial", cwd=source)
        self.git("clone", "-q", "--bare", str(source), str(self.root / "origin.git"), cwd=self.root)
        self.origin = self.root / "origin.git"
        self.source = source
        self.checkout = self.root / "checkout"
        self.git("clone", "-q", "--no-tags", "--depth=1", f"file://{self.origin}", str(self.checkout), cwd=self.root)

    def tearDown(self):
        self.folder.cleanup()

    def git(self, *args, cwd):
        subprocess.run(["git", *args], cwd=cwd, env=self.git_env, check=True,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=60)

    def tag(self, *args):
        self.git("tag", *args, cwd=self.source)
        self.git("push", "-q", str(self.origin), "--tags", cwd=self.source)

    def run_script(self, *args, site_url=None, token=TOKEN):
        env = {**self.git_env, "APPS_SITE_TOKEN": token}
        if site_url:
            env["APPS_SITE_URL"] = site_url
        return subprocess.run([str(SCRIPT), *args], cwd=self.checkout, env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)

    def notes(self, tag):
        notes = self.root / "notes.txt"
        result = self.run_script("notes", tag, str(notes))
        self.assertEqual(result.returncode, 0, result.stderr)
        return notes.read_text()

    def artifacts(self, *names):
        folder = self.root / "artifacts"
        (folder / "macos-dmg").mkdir(parents=True, exist_ok=True)
        for name in names:
            (folder / "macos-dmg" / name).write_bytes(f"disk image {name}".encode())
        return folder

    def test_notes_come_from_the_annotated_tag_message(self):
        self.tag("-a", "--cleanup=whitespace", "v0.2.0", "-m", "Highlights\n\n# Fixed\n- Sending works again")
        self.assertEqual(self.notes("v0.2.0"), "Highlights\n\n# Fixed\n- Sending works again\n")

    def test_a_message_that_only_names_the_version_is_no_notes(self):
        self.tag("-a", "v0.2.0", "-m", "Nevermore 0.2.0")
        self.assertEqual(self.notes("v0.2.0"), "")

    def test_a_lightweight_tag_has_no_notes(self):
        self.tag("v0.2.0")
        self.assertEqual(self.notes("v0.2.0"), "")

    def test_publishes_a_prerelease_to_the_beta_channel_with_the_manifest_last(self):
        artifacts = self.artifacts("Nevermore-0.1.0-beta.1-macos-universal.dmg",
                                   "Nevermore-0.1.0-beta.1-macos-universal.dmg.sha256")
        notes = self.root / "notes.txt"
        notes.write_text("First beta.\n")
        with StandInSite(self.root / "site") as site:
            result = self.run_script("publish", "v0.1.0-beta.1", str(artifacts), str(notes), site_url=site.url)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(site.writes, [
                "nevermore/0.1.0-beta.1/Nevermore-0.1.0-beta.1-macos-universal.dmg",
                "nevermore/0.1.0-beta.1/release.json",
                "apps.json",
                "nevermore/beta.json",
            ])
            manifest = site.json("nevermore/beta.json")
            dmg = artifacts / "macos-dmg" / "Nevermore-0.1.0-beta.1-macos-universal.dmg"
            self.assertEqual(manifest["channel"], "beta")
            self.assertEqual(manifest["version"], "0.1.0-beta.1")
            self.assertEqual(manifest["notes"], "First beta.")
            self.assertEqual(list(manifest["downloads"]), ["macos"])
            download = manifest["downloads"]["macos"]
            self.assertEqual(download["label"], LABEL)
            self.assertEqual(download["sha256"], hashlib.sha256(dmg.read_bytes()).hexdigest())
            self.assertEqual(download["url"],
                             f"{site.url}/nevermore/0.1.0-beta.1/Nevermore-0.1.0-beta.1-macos-universal.dmg")
            entry = site.json("apps.json")["apps"][0]
            self.assertEqual((entry["name"], entry["channels"]), ("Nevermore", ["beta"]))

    def test_a_stable_release_also_moves_an_older_beta(self):
        with StandInSite(self.root / "site") as site:
            beta = self.artifacts("Nevermore-0.1.0-beta.1-macos-universal.dmg")
            self.assertEqual(self.run_script("publish", "v0.1.0-beta.1", str(beta), site_url=site.url).returncode, 0)
            (beta / "macos-dmg" / "Nevermore-0.1.0-beta.1-macos-universal.dmg").unlink()
            stable = self.artifacts("Nevermore-0.1.0-macos-universal.dmg")
            result = self.run_script("publish", "v0.1.0", str(stable), site_url=site.url)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(site.json("nevermore/stable.json")["version"], "0.1.0")
            self.assertEqual(site.json("nevermore/beta.json")["version"], "0.1.0")
            self.assertEqual(site.json("apps.json")["apps"][0]["channels"], ["stable", "beta"])

    def test_a_rerun_with_the_same_dmg_succeeds_but_a_rebuilt_one_is_refused(self):
        # release.yml attaches the DMG to the forge release only after this
        # step succeeds, so the forge never gets a build the site refused.
        name = "Nevermore-0.2.0-macos-universal.dmg"
        artifacts = self.artifacts(name)
        with StandInSite(self.root / "site") as site:
            self.assertEqual(self.run_script("publish", "v0.2.0", str(artifacts), site_url=site.url).returncode, 0)
            published = (self.root / "site" / "nevermore" / "0.2.0" / name).read_bytes()

            again = self.run_script("publish", "v0.2.0", str(artifacts), site_url=site.url)
            self.assertEqual(again.returncode, 0, again.stderr)

            (artifacts / "macos-dmg" / name).write_bytes(b"a rebuild, signed and notarized again")
            writes = list(site.writes)
            rebuilt = self.run_script("publish", "v0.2.0", str(artifacts), site_url=site.url)
            self.assertNotEqual(rebuilt.returncode, 0)
            self.assertIn("already exists with different artifacts", rebuilt.stdout + rebuilt.stderr)
            self.assertEqual(site.writes, writes)
            self.assertEqual((self.root / "site" / "nevermore" / "0.2.0" / name).read_bytes(), published)

    def test_refuses_a_dmg_of_another_version(self):
        artifacts = self.artifacts("Nevermore-0.1.0-macos-universal.dmg")
        with StandInSite(self.root / "site") as site:
            result = self.run_script("publish", "v0.2.0", str(artifacts), site_url=site.url)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not belong to v0.2.0", result.stdout + result.stderr)
            self.assertEqual(site.writes, [])

    def test_refuses_without_a_dmg(self):
        with StandInSite(self.root / "site") as site:
            result = self.run_script("publish", "v0.2.0", str(self.artifacts()), site_url=site.url)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(site.writes, [])

    def test_a_wrong_token_publishes_nothing(self):
        artifacts = self.artifacts("Nevermore-0.2.0-macos-universal.dmg")
        with StandInSite(self.root / "site") as site:
            result = self.run_script("publish", "v0.2.0", str(artifacts), site_url=site.url, token="wrong-token-7f3a")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(site.writes, [])
            self.assertNotIn("wrong-token-7f3a", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
