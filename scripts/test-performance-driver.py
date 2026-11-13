#!/usr/bin/env python3
"""No GUI: exercise the driver with owned fake child processes."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
import urllib.request
import urllib.error

DRIVER = Path(__file__).with_name("check-performance.py")


class PerformanceDriverTests(unittest.TestCase):
    def fake_child(self, root, timeout=False):
        child = root / "fake-child"
        # Only this fake app resolves its root + driver nonce. A malicious
        # reported external path must never be interpreted by the driver.
        external = root / f"NevermorePerformance-{uuid.uuid4()}"
        external.mkdir()
        (external / "sentinel").write_text("keep")
        code = """#!/usr/bin/env python3
import json, os, shutil, sys, time, urllib.request, uuid
from pathlib import Path
ROOT = Path(ROOT_VALUE)
if '--performance-cleanup' in sys.argv:
    nonce = sys.argv[sys.argv.index('--performance-cleanup') + 1]
    (ROOT / 'cleanup-nonce').write_text(nonce)
    fixture = ROOT / ('owned-' + nonce)
    if fixture.exists(): shutil.rmtree(fixture)
    sys.exit(0)
if '--performance-seed' in sys.argv:
    nonce = sys.argv[sys.argv.index('--performance-seed') + 1]
    (ROOT / 'selected-nonce').write_text(nonce)
    (ROOT / ('owned-' + nonce)).mkdir()
    print(json.dumps({'event':'seed_complete', 'milliseconds':1}), flush=True)
    sys.exit(0)
nonce = sys.argv[sys.argv.index('--performance-fixture-id') + 1]
(ROOT / 'selected-nonce').write_text(nonce)
(ROOT / 'pid').write_text(str(os.getpid()))
(ROOT / ('owned-' + nonce)).mkdir(exist_ok=True)
print(json.dumps({'event':'fixture_directory','path':EXTERNAL_VALUE}), flush=True)
if '--performance-cached-launch' in sys.argv:
    print(json.dumps({'event':'first_interactive'}), flush=True)
    print(json.dumps({'event':'result','configuration':'Release','cached_fixture':True,'cached_launch_since_main_ms':1}), flush=True)
    sys.exit(0)
if TIMEOUT_VALUE: time.sleep(30)
origin = sys.argv[sys.argv.index('--performance-loopback-origin') + 1]
for i in range(10):
    body = json.dumps({'channel_id':'performance-feedback','client_id':str(uuid.uuid4()),'content':'<p>Feedback fixture %d</p>' % i,'files':[]}).encode()
    with urllib.request.urlopen(urllib.request.Request(origin + '/api/method/raven.api.raven_message.send_message_with_attachments', data=body, headers={'Content-Type':'application/json'})) as response: response.read()
print(json.dumps({'event':'first_interactive'}), flush=True)
print(json.dumps({'event':'result','configuration':'Release','queued_send_UI_feedback':{'count':5,'p95':1},'queued_send_perform_click_action_observation':{'count':5,'p95':107},'queued_send_perform_click_total':{'count':5,'p95':107.05},'synthetic_button_pre_action':{'count':5,'p95':0.05},'targets':{'scroll_60Hz':'unmeasured'}}), flush=True)
"""
        code = code.replace("ROOT_VALUE", repr(str(root))).replace("EXTERNAL_VALUE", repr(str(external))).replace("TIMEOUT_VALUE", repr(timeout))
        child.write_text(code)
        child.chmod(0o700)
        return child, external

    def assert_owned_cleanup(self, root, external):
        selected = (root / "selected-nonce").read_text()
        self.assertEqual((root / "cleanup-nonce").read_text(), selected)
        self.assertEqual(str(uuid.UUID(selected)).upper(), selected)
        self.assertFalse((root / ("owned-" + selected)).exists())
        self.assertEqual((external / "sentinel").read_text(), "keep")

    def test_loopback_contract_rejects_credentials_routes_and_replays(self):
        spec = importlib.util.spec_from_file_location("performance_driver_fixture", DRIVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with module.LoopbackFixture() as fixture:
            with self.assertRaises(urllib.error.HTTPError) as denied:
                urllib.request.urlopen(urllib.request.Request(fixture.origin + "/api/resource/Raven%20Channel/performance-feedback", headers={"Authorization": "synthetic-denied"}))
            denied.exception.close()
            with self.assertRaises(urllib.error.HTTPError) as missing: urllib.request.urlopen(fixture.origin + "/unexpected")
            missing.exception.close()
            body = json.dumps({"channel_id": "performance-feedback", "client_id": str(uuid.uuid4()), "content": "<p>Feedback fixture 0</p>", "files": []}).encode()
            request = urllib.request.Request(fixture.origin + "/api/method/raven.api.raven_message.send_message_with_attachments", data=body, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request) as response:
                row = json.load(response)["message"][0]
                self.assertEqual(row["owner"], "performance-fixture@example.invalid")
            with self.assertRaises(urllib.error.HTTPError) as replayed: urllib.request.urlopen(request)
            replayed.exception.close()
            self.assertEqual(len(fixture.sends), 1)

    def run_driver(self, child, deadline):
        # Generous wall-clock budget: the macOS 26 runner spawns processes far
        # more slowly than a local Mac. A timeout reports the driver's stderr.
        try:
            return subprocess.run([str(DRIVER), "--binary", str(child), "--idle-seconds", "0", "--timeout", str(deadline)], capture_output=True, text=True, timeout=deadline + 120)
        except subprocess.TimeoutExpired as expired:
            stderr = expired.stderr.decode(errors="replace") if isinstance(expired.stderr, bytes) else (expired.stderr or "")
            stdout = expired.stdout.decode(errors="replace") if isinstance(expired.stdout, bytes) else (expired.stdout or "")
            self.fail("driver did not finish; stderr so far:\n" + stderr[-4000:] + "\nstdout so far:\n" + stdout[-2000:])

    def test_result_ignores_external_path_and_cleans_selected_nonce(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child, external = self.fake_child(root)
            result = self.run_driver(child, deadline=90)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["measurements"]["targets"]["scroll_60Hz"], "unmeasured")
            self.assertEqual(report["measurements"]["cached_relaunch_spawn_to_interactive"]["count"], 5)
            self.assertEqual(report["measurements"]["loopback_fixture"]["unique_send_posts"], 10)
            self.assertEqual(report["measurements"]["queued_send_UI_feedback"]["p95"], 1)
            self.assertEqual(report["measurements"]["queued_send_perform_click_action_observation"]["p95"], 107)
            self.assertEqual(report["measurements"]["queued_send_perform_click_total"]["p95"], 107.05)
            self.assertEqual(report["measurements"]["synthetic_button_pre_action"]["p95"], 0.05)
            self.assert_owned_cleanup(root, external)

    def test_timeout_terminates_only_owned_child_and_cleans_selected_nonce(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child, external = self.fake_child(root, timeout=True)
            result = self.run_driver(child, deadline=1)
            self.assertEqual(result.returncode, 1)
            self.assertIn("deadline", result.stderr)
            with self.assertRaises(ProcessLookupError): os.kill(int((root / "pid").read_text()), 0)
            self.assert_owned_cleanup(root, external)


if __name__ == "__main__": unittest.main()
