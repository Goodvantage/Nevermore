"""Runs scripts/notarize.sh against a stub `xcrun notarytool` that replays
canned answers, so the wait loop's decisions can be checked without Apple.

A response file `<subcommand>.<n>` (or `<subcommand>` for every call) holds
the exit status on its first line and the output after it."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "notarize.sh"
SUBMISSION = "2efe2717-52ef-43a5-96dc-0797e4ca1041"

STUB = r"""#!/bin/bash
[ "$1" = notarytool ] || { echo "unexpected: xcrun $*" >&2; exit 97; }
printf '%s\n' "$*" >> "$STUB_DIR/calls"
n=$(grep -c "^notarytool $2 " "$STUB_DIR/calls")
for f in "$STUB_DIR/$2.$n" "$STUB_DIR/$2"; do
  if [ -f "$f" ]; then
    tail -n +2 "$f"
    exit "$(head -n 1 "$f")"
  fi
done
echo "no answer for notarytool $2 call $n" >&2
exit 98
"""


def answer(status, verdict=None):
    body = f'{{"id":"{SUBMISSION}","status":"{verdict}"}}' if verdict else f'{{"id":"{SUBMISSION}","message":"ok"}}'
    return f"{status}\n{body}\n"


class NotarizeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)
        stub = self.dir / "xcrun"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.artifact = self.dir / "Nevermore-notarize.zip"
        self.artifact.write_bytes(b"zip")
        self.respond("submit", answer(0))

    def tearDown(self):
        self.temp.cleanup()

    def respond(self, name, text):
        (self.dir / name).write_text(text)

    def run_script(self):
        env = {
            "PATH": f"{self.dir}:/usr/bin:/bin",
            "STUB_DIR": str(self.dir),
            "NOTARY_KEY_FILE": str(self.dir / "AuthKey.p8"),
            "NOTARY_KEY_ID": "KEY123",
            "NOTARY_ISSUER_ID": "issuer",
            "NOTARY_WAIT_ROUNDS": "3",
        }
        result = subprocess.run(["/bin/bash", str(SCRIPT), str(self.artifact)], env=env, text=True, capture_output=True, timeout=60)
        calls = (self.dir / "calls").read_text().splitlines() if (self.dir / "calls").exists() else []
        return result, [call.split()[1] for call in calls]

    def test_a_wait_that_stops_without_a_verdict_waits_again_while_in_progress(self):
        # notarytool documents no wording for its own --timeout, so the
        # script must not depend on the message to keep waiting.
        self.respond("wait.1", "1\nPolling stopped: the time limit was reached.\n")
        self.respond("info.1", answer(0, "In Progress"))
        self.respond("wait.2", answer(0, "Accepted"))

        result, calls = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["submit", "wait", "info", "wait"])
        self.assertIn("Notarization accepted", result.stdout)

    def test_a_failed_wait_and_status_query_fails_without_resubmitting(self):
        self.respond("wait", "1\nError: HTTP status code: 401. Unable to authenticate.\n")
        self.respond("info", "1\nError: HTTP status code: 401. Unable to authenticate.\n")

        result, calls = self.run_script()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, ["submit", "wait", "info"])
        self.assertIn("notarytool wait failed", result.stderr)

    def test_a_verdict_reached_while_the_wait_failed_is_used(self):
        self.respond("wait.1", "1\nError: connection reset\n")
        self.respond("info.1", answer(0, "Invalid"))
        self.respond("log", "0\n{\"issues\":[{\"message\":\"The binary is not signed.\"}]}\n")

        result, calls = self.run_script()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, ["submit", "wait", "info", "log"])
        self.assertIn("ended Invalid", result.stderr)
        self.assertIn("The binary is not signed.", result.stderr)

    def test_no_verdict_after_every_round_fails_with_the_submission_id(self):
        self.respond("wait", answer(0, "In Progress"))

        result, calls = self.run_script()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, ["submit", "wait", "wait", "wait"])
        self.assertIn(f"no verdict for {SUBMISSION} after 3 rounds", result.stderr)


if __name__ == "__main__":
    unittest.main()
