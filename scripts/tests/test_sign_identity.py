import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


def resolver_script():
    default = SCRIPTS / "resolve-sign-identity.sh"
    return Path(os.environ.get("NEVERMORE_SIGN_RESOLVER_TEST_SCRIPT", default))


def build_script():
    default = SCRIPTS / "build-app.sh"
    return Path(os.environ.get("NEVERMORE_BUILD_APP_TEST_SCRIPT", default))


# PERSON must win: it sorts first by byte order (C), while a locale-aware
# sort (a user's en_US.UTF-8 or de_CH.UTF-8 Terminal) and hash order both
# put ACCOUNT first, as with "Lukas ..." versus "itunes@..." on a real Mac.
PERSON = ("F" * 40, "Apple Development: Alex Example (AAAAAAAAAA)")
ACCOUNT = ("2" * 40, "Apple Development: adam@example.com (BBBBBBBBBB)")
DEVELOPER_ID = ("3" * 40, "Developer ID Application: Alex Example (CCCCCCCCCC)")
DISTRIBUTION = ("4" * 40, "Apple Distribution: Alex Example (CCCCCCCCCC)")


def listing(*identities):
    """Mimics `security find-identity -v -p codesigning` output."""
    lines = [f'  {index}) {sha1} "{name}"' for index, (sha1, name) in enumerate(identities, 1)]
    lines.append(f"     {len(identities)} valid identities found")
    return "\n".join(lines) + "\n"


class SignIdentityResolutionTests(unittest.TestCase):
    def resolve(self, security_output="", security_status=0, sign_identity=None):
        with tempfile.TemporaryDirectory(prefix="NevermoreSignIdentity-") as folder:
            root = Path(folder)
            (root / "listing.txt").write_text(security_output)
            security = root / "security"
            security.write_text(
                "#!/bin/sh\n"
                '[ "$*" = "find-identity -v -p codesigning" ] || { echo "unexpected: $*" >&2; exit 64; }\n'
                'cat "$FAKE_SECURITY_LISTING"\n'
                'exit "$FAKE_SECURITY_STATUS"\n')
            security.chmod(0o700)
            environment = {"PATH": f"{root}:/usr/bin:/bin", "LC_ALL": "en_US.UTF-8",
                           "FAKE_SECURITY_LISTING": str(root / "listing.txt"),
                           "FAKE_SECURITY_STATUS": str(security_status)}
            if sign_identity is not None:
                environment["SIGN_IDENTITY"] = sign_identity
            return subprocess.run([str(resolver_script())], env=environment,
                                  stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=30)

    def assertResolves(self, result, sha1):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, sha1 + "\n")

    def test_two_apple_development_identities_resolve_to_one_certificate(self):
        # Regression: two valid Apple Development certificates made
        # `codesign --sign "Apple Development"` fail as ambiguous, which
        # aborted scripts/build.sh --install before it installed anything.
        result = self.resolve(listing(ACCOUNT, PERSON))

        self.assertResolves(result, PERSON[0])
        self.assertIn(f'signing with "{PERSON[1]}"', result.stderr)
        self.assertIn(f"{ACCOUNT[0]}  {ACCOUNT[1]}", result.stderr)
        self.assertIn("SIGN_IDENTITY", result.stderr)

    def test_choice_does_not_depend_on_keychain_order(self):
        self.assertResolves(self.resolve(listing(PERSON, ACCOUNT)), PERSON[0])
        self.assertResolves(self.resolve(listing(ACCOUNT, PERSON)), PERSON[0])

    def test_single_identity_signs_quietly_and_ignores_other_kinds(self):
        result = self.resolve(listing(DEVELOPER_ID, DISTRIBUTION, ACCOUNT))

        self.assertResolves(result, ACCOUNT[0])
        self.assertEqual(result.stderr, "")

    def test_same_certificate_in_two_keychains_is_not_ambiguous(self):
        result = self.resolve(listing(PERSON, PERSON))

        self.assertResolves(result, PERSON[0])
        self.assertEqual(result.stderr, "")

    def test_explicit_identity_wins_without_keychain_lookup(self):
        for identity in ("-", DEVELOPER_ID[1], ACCOUNT[0]):
            with self.subTest(identity=identity):
                result = self.resolve(security_status=1, sign_identity=identity)
                self.assertResolves(result, identity)

    def test_missing_apple_development_identity_fails_with_guidance(self):
        result = self.resolve(listing(DEVELOPER_ID))

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("SIGN_IDENTITY", result.stderr)

    def test_keychain_listing_failure_is_reported(self):
        result = self.resolve(listing(PERSON), security_status=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("find-identity failed", result.stderr)


class BuildAppSigningTests(unittest.TestCase):
    """Runs build-app.sh in a scratch copy of the repository with fake swift,
    security and codesign, so the signing path CI skips with SIGN_IDENTITY=-
    still has coverage."""

    # Mirrors codesign's lookup (man codesign, SIGNING IDENTITIES): 40 hex
    # digits name one certificate; anything else is a substring search over
    # certificate names that fails when it matches more than one.
    FAKE_CODESIGN = r'''#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CODESIGN_LOG"
identity=""
while [ $# -gt 0 ]; do
  case "$1" in --sign) identity="$2"; shift ;; esac
  shift
done
case "$identity" in ""|-) exit 0 ;; esac
if printf '%s' "$identity" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
  grep -qi "$identity" "$FAKE_SECURITY_LISTING" && exit 0
  echo "$identity: no identity found" >&2; exit 1
fi
matches=$(grep -cF "\"$identity" "$FAKE_SECURITY_LISTING")
[ "$matches" -eq 1 ] && exit 0
[ "$matches" -gt 1 ] && { echo "$identity: ambiguous" >&2; exit 1; }
echo "$identity: no identity found" >&2; exit 1
'''

    def signing_calls(self, sign_identity=None):
        with tempfile.TemporaryDirectory(prefix="NevermoreBuildSigning-") as folder:
            root = Path(folder)
            repository = root / "repository"
            (repository / "scripts").mkdir(parents=True)
            shutil.copy(build_script(), repository / "scripts" / "build-app.sh")
            shutil.copy(resolver_script(), repository / "scripts" / "resolve-sign-identity.sh")
            for script in (repository / "scripts").iterdir():
                script.chmod(0o700)
            resources = repository / "Resources"
            (resources / "Licenses").mkdir(parents=True)
            shutil.copy(SCRIPTS.parent / "Resources" / "Info.plist", resources / "Info.plist")
            for name in ("Nevermore.icns", "Nevermore.entitlements", "Licenses/LICENSE"):
                (resources / name).write_text("")

            products = root / "products"
            sparkle = products / "Sparkle.framework" / "Versions" / "B"
            for bundle in ("XPCServices/Installer.xpc", "XPCServices/Downloader.xpc", "Updater.app"):
                (sparkle / bundle).mkdir(parents=True)
            (sparkle / "Autoupdate").write_text("")
            (products / "Nevermore").write_text("")

            tools = root / "tools"
            tools.mkdir()
            fakes = {
                "swift": 'case " $* " in *" --show-bin-path "*) printf \'%s\\n\' "$FAKE_SWIFT_BIN" ;; esac\n',
                "security": 'cat "$FAKE_SECURITY_LISTING"\n',
            }
            for name, body in fakes.items():
                (tools / name).write_text("#!/bin/sh\n" + body)
            (tools / "codesign").write_text(self.FAKE_CODESIGN)
            for tool in tools.iterdir():
                tool.chmod(0o700)

            (root / "listing.txt").write_text(listing(ACCOUNT, PERSON, DEVELOPER_ID))
            log = root / "codesign.log"
            environment = {"PATH": f"{tools}:/usr/bin:/bin", "LC_ALL": "en_US.UTF-8",
                           "FAKE_SWIFT_BIN": str(products),
                           "FAKE_SECURITY_LISTING": str(root / "listing.txt"),
                           "FAKE_CODESIGN_LOG": str(log)}
            if sign_identity is not None:
                environment["SIGN_IDENTITY"] = sign_identity
            result = subprocess.run(
                [str(repository / "scripts" / "build-app.sh")],
                env=environment,
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines()[-1],
                             str(repository / "build" / "Nevermore.app"))
            signing = [call for call in log.read_text().splitlines() if "--sign" in call]
            # Four Sparkle helpers, the framework, then the app.
            self.assertEqual(len(signing), 6, signing)
            return signing

    def test_two_apple_development_identities_sign_the_whole_bundle(self):
        for call in self.signing_calls():
            self.assertIn(f"--sign {PERSON[0]} ", call)
            self.assertIn("--options runtime ", call)
            self.assertIn("--timestamp=none ", call)

    def test_ad_hoc_test_build_can_load_its_ad_hoc_sparkle_framework(self):
        for call in self.signing_calls(sign_identity="-"):
            self.assertIn("--sign - ", call)
            self.assertNotIn("--options runtime", call)

    def test_developer_id_keeps_hardened_runtime_and_secure_timestamps(self):
        for call in self.signing_calls(sign_identity=DEVELOPER_ID[1]):
            self.assertIn(f"--sign {DEVELOPER_ID[1]} ", call)
            self.assertIn("--options runtime ", call)
            self.assertIn("--timestamp ", call)
            self.assertNotIn("--timestamp=none", call)


if __name__ == "__main__":
    unittest.main()
