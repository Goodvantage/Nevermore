import os
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


def fixture_script():
    default = Path(__file__).resolve().parents[1] / "check-native-attachments.py"
    return Path(os.environ.get("NEVERMORE_FIXTURE_TEST_SCRIPT", default))


class NativeFixtureProcessTests(unittest.TestCase):
    def test_interruption_terminates_the_owned_application(self):
        with tempfile.TemporaryDirectory(prefix="NevermoreFixtureProcess-") as folder:
            root = Path(folder)
            pid_file = root / "child.pid"
            app = root / "fake-app"
            app.write_text("#!/usr/bin/env python3\nimport os, pathlib, time\n"
                           "pathlib.Path(os.environ['NEVERMORE_CHILD_PID_FILE']).write_text(str(os.getpid()))\n"
                           "while True: time.sleep(1)\n")
            app.chmod(0o700)
            runner = fixture_script()
            process = subprocess.Popen([sys.executable, str(runner), "--app", str(app)],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT,
                                       env={**os.environ, "NEVERMORE_CHILD_PID_FILE": str(pid_file)})
            child = None
            try:
                # The macOS 26 runner spawns processes far more slowly than a
                # local Mac; an early exit reports the runner's own output.
                deadline = time.monotonic() + 60
                while not pid_file.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                if not pid_file.exists():
                    early = "(runner still running)"
                    if process.poll() is not None:
                        try:
                            early = process.communicate(timeout=5)[0].decode(errors="replace")
                        except subprocess.TimeoutExpired:
                            early = "(runner exited; a descendant still holds its output pipe)"
                    self.fail("fixture did not launch its fake application:\n" + early[-4000:])
                child = int(pid_file.read_text())
                process.send_signal(signal.SIGINT)
                output, _ = process.communicate(timeout=15)
                self.assertNotEqual(process.returncode, 0, output.decode(errors="replace"))
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
                if child is not None:
                    try:
                        os.kill(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_thread_startup_failure_terminates_owned_application(self):
        runner = fixture_script()
        spec = importlib.util.spec_from_file_location("native_fixture_test", runner)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real_thread = module.threading.Thread
        real_popen = subprocess.Popen
        child = None

        class FailingReader(real_thread):
            def start(self):
                if self._target.__name__ == "stream":
                    raise RuntimeError("Injected reader startup failure")
                super().start()

        def launch(*args, **kwargs):
            nonlocal child
            process = real_popen(*args, **kwargs)
            child = process
            return process

        with tempfile.TemporaryDirectory(prefix="NevermoreFixtureStartup-") as folder:
            app = Path(folder) / "fake-app"
            app.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n")
            app.chmod(0o700)
            try:
                with patch.object(sys, "argv", [str(runner), "--app", str(app)]), \
                        patch.object(module.threading, "Thread", FailingReader), \
                        patch.object(module.subprocess, "Popen", side_effect=launch):
                    with self.assertRaisesRegex(RuntimeError, "Injected reader startup"):
                        module.main()
                self.assertIsNotNone(child)
                self.assertIsNotNone(child.poll(), "fixture left its application running")
            finally:
                if child is not None:
                    if child.poll() is None:
                        child.kill()
                        child.wait(timeout=5)
                    child.stdout.close()


if __name__ == "__main__":
    unittest.main()
