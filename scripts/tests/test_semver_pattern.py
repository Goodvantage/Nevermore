"""Checks that the release version grammar in scripts/semver-pattern.sh
accepts exactly what apps.goodvantage.cloud's publisher accepts (minus build
metadata), and that scripts/release.sh hands that grammar to lkm-release."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
PATTERN_FILE = SCRIPTS / "semver-pattern.sh"

VERSIONS = [
    "0.1.0", "1.2.3", "10.20.30", "1.0.0-beta.1", "1.0.0-rc-1", "1.0.0-0a", "1.0.0-alpha.0",
    "1.0.0-x.7.z.92", "01.2.3", "1.02.3", "1.2.03", "1.0.0-01", "1.0.0-beta.01", "1.0.0-.",
    "1.0.0-..", "1.0.0-beta..1", "1.0.0-", "1.0.0-beta.", "1.2", "1.2.3.4", "v1.2.3",
    "1.2.3+build.5", "1.2.3-beta+exp", " 1.2.3", "1.2.3 ", "1.0.0-alpha_1", "",
]


def publisher_semver():
    spec = importlib.util.spec_from_file_location("publish_app_release", SCRIPTS / "publish_app_release.py")
    module = importlib.util.module_from_spec(spec)
    # Python 3.13 and earlier resolve dataclass string annotations through
    # the module registry, just as a normal import would populate it.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.SEMVER_RE


def shell_accepts(version):
    result = subprocess.run(
        ["/bin/bash", "-c", 'source "$1"; [[ "$2" =~ $SEMVER_PATTERN ]]', "check", str(PATTERN_FILE), version],
        stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    if result.returncode not in (0, 1):
        raise AssertionError(result.stderr.decode())
    return result.returncode == 0


class SemverPatternTests(unittest.TestCase):
    def test_the_pattern_matches_the_publishers_grammar_without_build_metadata(self):
        semver = publisher_semver()
        for version in VERSIONS:
            with self.subTest(version=version):
                expected = semver.fullmatch(version) is not None and "+" not in version
                self.assertEqual(shell_accepts(version), expected)

    def test_release_sh_uses_the_pattern(self):
        # release.sh ends by exec'ing $LKM_RELEASE_BIN with its arguments;
        # printenv shows the environment it would hand to lkm-release.
        result = subprocess.run(
            [str(SCRIPTS / "release.sh"), "RELEASE_VERSION_REGEX"],
            env={**os.environ, "LKM_RELEASE_BIN": "printenv"},
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        pattern = subprocess.run(
            ["/bin/bash", "-c", 'source "$1"; printf "%s\\n" "$SEMVER_PATTERN"', "show", str(PATTERN_FILE)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30).stdout
        self.assertEqual(result.stdout, pattern)


if __name__ == "__main__":
    unittest.main()
