import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import signal
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "check-native-attachments.py"
PREFIX = "ch.goodvantage.Nevermore.native-fixture."


class NativeUserSessionTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("native_user_session_test", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory(prefix="Nevermore user session ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "fake 'app' $(whoami)"
        self.app.write_text("#!/usr/bin/env python3\n"
                            "print('PASS native attachment fixture completed', flush=True)\n")
        self.app.chmod(0o700)
        self.real_run = subprocess.run
        self.calls = []
        self.plist = None
        self.directory = None
        self.bootstrap_result = 0
        self.bootout_result = 0
        self.run_child = True

    def launchctl(self, command, **_kwargs):
        self.calls.append(command)
        self.assertEqual(command[0], "/bin/launchctl")
        if command[1] == "bootstrap":
            self.directory = Path(command[3]).parent
            with open(command[3], "rb") as source:
                self.plist = plistlib.load(source)
            if self.bootstrap_result:
                return subprocess.CompletedProcess(command, self.bootstrap_result, "", "Injected bootstrap failure")
            if self.run_child:
                wrapper = Path(self.plist["ProgramArguments"][1]).read_text()
                # Never let a broken test recursively launch an actual agent.
                self.assertNotIn("--user-session", wrapper)
                arguments = shlex.split(wrapper.splitlines()[1])
                for flag in self.expected_flags:
                    self.assertIn(flag, arguments)
                with open(self.plist["StandardOutPath"], "w") as output:
                    self.real_run(self.plist["ProgramArguments"],
                                  cwd=self.plist["WorkingDirectory"],
                                  env=self.plist["EnvironmentVariables"],
                                  stdout=output, stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL, timeout=30)
            return subprocess.CompletedProcess(command, 0, "", "")
        self.assertEqual(command[1], "bootout")
        return subprocess.CompletedProcess(command, self.bootout_result, "", "Injected cleanup failure" if self.bootout_result else "")

    def run_main(self, extra=(), *, sleep_error=None, times=None, label=PREFIX + "test"):
        stdout, stderr = io.StringIO(), io.StringIO()
        self.expected_flags = set(extra)
        environment = {"NATIVE_FIXTURE_LABEL": label, "RUNNER_TEMP": str(self.root),
                       "APPS_SITE_TOKEN": "test-secret-must-not-reach-agent"}
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, environment))
            stack.enter_context(patch.object(sys, "argv", [str(SCRIPT), "--app", str(self.app), "--user-session", *extra]))
            stack.enter_context(patch.object(self.module.subprocess, "run", side_effect=self.launchctl))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            if sleep_error is not None:
                stack.enter_context(patch.object(self.module.time, "sleep", side_effect=sleep_error))
            if times is not None:
                stack.enter_context(patch.object(self.module.time, "monotonic", side_effect=times))
            status = self.module.main()
        return status, stdout.getvalue(), stderr.getvalue()

    def test_runs_in_own_gui_domain_without_forwarding_secrets(self):
        status, output, errors = self.run_main(["--polls", "--reactions", "--avatars"])
        self.assertEqual(status, 0, errors + output)
        self.assertEqual(self.calls[0][2], f"gui/{os.getuid()}")
        self.assertEqual(self.plist["LimitLoadToSessionType"], "Aqua")
        self.assertNotIn("UserName", self.plist)
        self.assertEqual(set(self.plist["EnvironmentVariables"]), {"PATH", "HOME", "PYTHONUTF8", "NSUnbufferedIO"})
        self.assertNotIn("test-secret-must-not-reach-agent", str(self.plist))
        self.assertIn("PASS native attachment fixture completed", output)
        self.assertEqual(self.calls[-1][1:], ["bootout", f"gui/{os.getuid()}/{PREFIX}test"])
        self.assertFalse(self.directory.exists())

    def test_child_failure_is_not_success(self):
        self.app.write_text("#!/usr/bin/env python3\nraise SystemExit(7)\n")
        status, output, errors = self.run_main()
        self.assertNotEqual(status, 0, errors + output)
        self.assertIn("exited with status 7", output)
        self.assertEqual(self.calls[-1][1], "bootout")
        self.assertFalse(self.directory.exists())

    def test_bootstrap_failure_is_not_success(self):
        self.bootstrap_result = 5
        status, output, errors = self.run_main()
        self.assertNotEqual(status, 0, output)
        self.assertIn("bootstrap", errors.lower())
        self.assertIn("GUI login", errors)
        self.assertFalse(self.directory.exists())

    def test_cleanup_failure_is_reported_and_files_are_retained(self):
        self.bootout_result = 5
        status, output, errors = self.run_main()
        self.assertNotEqual(status, 0, output)
        self.assertIn("cleanup", errors.lower())
        self.assertTrue(self.directory.exists())

    def test_interruption_unloads_the_owned_agent_and_restores_handlers(self):
        self.run_child = False
        before = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        status, output, errors = self.run_main(sleep_error=InterruptedError("Injected cancellation"))
        self.assertNotEqual(status, 0, output + errors)
        self.assertEqual(self.calls[-1][1], "bootout")
        self.assertFalse(self.directory.exists())
        self.assertEqual(before, {sig: signal.getsignal(sig) for sig in before})

    def test_missing_completion_is_bounded_and_cleans_up(self):
        self.run_child = False
        status, output, errors = self.run_main(times=[0, 1000])
        self.assertNotEqual(status, 0, output + errors)
        self.assertEqual(self.calls[-1][1], "bootout")
        self.assertFalse(self.directory.exists())

    def test_foreign_service_label_is_rejected_before_launch(self):
        status, output, errors = self.run_main(label="com.apple.secinitd")
        self.assertNotEqual(status, 0, output + errors)
        self.assertEqual(self.calls, [])

    def test_save_panel_requires_the_direct_desktop_session(self):
        with self.assertRaises(SystemExit) as error:
            self.run_main(["--save-panel"])
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
