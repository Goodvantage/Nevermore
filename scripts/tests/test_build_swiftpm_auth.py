import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


BUILD_SCRIPT = Path(__file__).resolve().parents[1] / "build-app.sh"


class BuildSwiftPMAuthenticationTests(unittest.TestCase):
    """Exercise the real assembly script without a compiler or credentials."""

    def swift_calls(self, *, ci=None, universal=False):
        with tempfile.TemporaryDirectory(prefix="NevermoreSwiftPMAuth-") as folder:
            root = Path(folder)
            repository = root / "repository"
            scripts = repository / "scripts"
            scripts.mkdir(parents=True)
            source = Path(os.environ.get("NEVERMORE_BUILD_APP_TEST_SCRIPT", BUILD_SCRIPT))
            shutil.copy(source, scripts / "build-app.sh")
            resolver = scripts / "resolve-sign-identity.sh"
            resolver.write_text("#!/bin/sh\nprintf '%s\\n' '-'\n")
            resolver.chmod(0o700)

            resources = repository / "Resources"
            (resources / "Licenses").mkdir(parents=True)
            with (resources / "Info.plist").open("wb") as output:
                plistlib.dump({"LSMinimumSystemVersion": "26.0"}, output)
            for name in ("Nevermore.icns", "Nevermore.entitlements", "Licenses/LICENSE"):
                (resources / name).write_text("")

            products = root / "products"
            (products / "Sparkle.framework" / "Versions" / "B").mkdir(parents=True)
            (products / "Nevermore").write_text("fake binary")
            log = root / "swift.jsonl"
            tools = root / "tools"
            tools.mkdir()
            fakes = {
                "swift": "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['FAKE_SWIFT_LOG'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "if '--show-bin-path' in sys.argv:\n"
                "    print(os.environ['FAKE_SWIFT_BIN'])\n",
                "codesign": "#!/bin/sh\nexit 0\n",
                "lipo": "#!/bin/sh\n"
                "while [ $# -gt 0 ]; do\n"
                "  if [ \"$1\" = -output ]; then cp \"$FAKE_SWIFT_BIN/Nevermore\" \"$2\"; exit; fi\n"
                "  shift\n"
                "done\nexit 64\n",
            }
            for name, body in fakes.items():
                tool = tools / name
                tool.write_text(body)
                tool.chmod(0o700)

            environment = {
                "PATH": f"{tools}:{Path(sys.executable).parent}:/usr/bin:/bin",
                "FAKE_SWIFT_LOG": str(log),
                "FAKE_SWIFT_BIN": str(products),
                "UNIVERSAL": "1" if universal else "0",
            }
            if ci is not None:
                environment["CI"] = ci
            result = subprocess.run(
                ["/bin/bash", str(scripts / "build-app.sh")], env=environment,
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((repository / "build/Nevermore.app/Contents/MacOS/Nevermore").is_file())
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(len(calls), 4 if universal else 2)
            self.assertEqual(sum("--show-bin-path" in call for call in calls), 2 if universal else 1)
            self.assertTrue(all(call[0] == "build" for call in calls))
            if universal:
                triples = {call[call.index("--triple") + 1] for call in calls}
                self.assertEqual(triples, {"arm64-apple-macosx26.0", "x86_64-apple-macosx26.0"})
            return calls

    def test_ci_host_build_disables_keychain_for_every_swiftpm_call(self):
        for call in self.swift_calls(ci="true"):
            self.assertIn("--disable-keychain", call)

    def test_ci_universal_build_disables_keychain_for_both_architectures(self):
        for call in self.swift_calls(ci="true", universal=True):
            self.assertIn("--disable-keychain", call)

    def test_local_build_keeps_default_credential_lookup(self):
        for call in self.swift_calls():
            self.assertNotIn("--disable-keychain", call)

    def test_false_ci_value_keeps_default_credential_lookup(self):
        for call in self.swift_calls(ci="false"):
            self.assertNotIn("--disable-keychain", call)


if __name__ == "__main__":
    unittest.main()
