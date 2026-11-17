import importlib.util
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("mirror", SCRIPTS / "github-release-mirror.py")
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        git(self.source, "init", "-q")
        git(self.source, "config", "user.name", "Test")
        git(self.source, "config", "user.email", "test@example.invalid")
        (self.source / "LICENSE").write_text("license\n")
        (self.source / "app").write_text("first\n")
        git(self.source, "add", ".")
        git(self.source, "commit", "-qm", "internal secret history")
        git(self.source, "tag", "v0.1.0-beta.4")
        self.remote = self.root / "remote.git"
        git(self.root, "init", "--bare", "-q", str(self.remote))

    def snapshot(self, tag, **kwargs):
        return mirror.publish_snapshot(self.source, tag, "test-token", remote_url=str(self.remote), **kwargs)

    def new_tag(self, tag):
        (self.source / "app").write_text(tag)
        git(self.source, "add", "app")
        git(self.source, "commit", "-qm", "another private commit")
        git(self.source, "tag", tag)

    def test_snapshot_has_source_tree_and_no_forge_history(self):
        public = self.snapshot("v0.1.0-beta.4")
        self.assertEqual(git(self.source, "rev-parse", "v0.1.0-beta.4^{tree}"),
                         git(self.remote, "rev-parse", public + "^{tree}"))
        self.assertEqual(git(self.remote, "rev-list", "--count", public), "1")
        self.assertNotIn("private", git(self.remote, "log", "--format=%B", public))
        self.assertEqual(self.snapshot("v0.1.0-beta.4"), public)
        self.new_tag("v0.1.0-beta.5")
        newer = self.snapshot("v0.1.0-beta.5")
        self.assertEqual(git(self.remote, "rev-list", "--count", newer), "2")
        self.assertEqual(self.snapshot("v0.1.0-beta.4"), public)
        self.assertEqual(git(self.remote, "rev-parse", "refs/heads/main"), newer)

    def test_older_unpublished_release_cannot_roll_back_main(self):
        self.new_tag("v0.1.0-beta.5")
        self.snapshot("v0.1.0-beta.5")
        with self.assertRaisesRegex(RuntimeError, "backwards"):
            self.snapshot("v0.1.0-beta.4")

    def test_conflicting_existing_tag_is_rejected(self):
        self.snapshot("v0.1.0-beta.4")
        (self.source / "app").write_text("different")
        git(self.source, "add", "app")
        git(self.source, "commit", "-qm", "change")
        git(self.source, "tag", "-f", "v0.1.0-beta.4")
        with self.assertRaisesRegex(RuntimeError, "conflicts"):
            self.snapshot("v0.1.0-beta.4")

    def test_public_license_and_readme_survive_next_release_and_retries(self):
        first = self.snapshot("v0.1.0-beta.4")
        checkout = self.root / "public"
        git(self.root, "clone", "-q", "-b", "main", str(self.remote), str(checkout))
        git(checkout, "config", "user.name", "Test")
        git(checkout, "config", "user.email", "test@example.invalid")
        (checkout / "LICENSE").write_text("public license\n")
        (checkout / "README.md").write_text("public introduction\n")
        git(checkout, "add", "LICENSE", "README.md")
        git(checkout, "commit", "-qm", "Update public information")
        git(checkout, "push", "-q", "origin", "main")

        self.new_tag("v0.1.0-beta.5")
        second = self.snapshot("v0.1.0-beta.5", allow_license_bootstrap=True)
        self.assertEqual(git(self.remote, "show", f"{second}:LICENSE"), "public license")
        self.assertEqual(git(self.remote, "show", f"{second}:README.md"), "public introduction")
        self.assertEqual(git(self.remote, "show", f"{second}:app"), "v0.1.0-beta.5")
        self.assertEqual(self.snapshot("v0.1.0-beta.5"), second)
        self.assertEqual(self.snapshot("v0.1.0-beta.4"), first)

    def test_unrelated_changes_on_public_main_are_rejected(self):
        self.snapshot("v0.1.0-beta.4")
        checkout = self.root / "public"
        git(self.root, "clone", "-q", "-b", "main", str(self.remote), str(checkout))
        git(checkout, "config", "user.name", "Test")
        git(checkout, "config", "user.email", "test@example.invalid")
        (checkout / "app").write_text("unexpected public change")
        git(checkout, "add", "app")
        git(checkout, "commit", "-qm", "Change app")
        git(checkout, "push", "-q", "origin", "main")
        self.new_tag("v0.1.0-beta.5")
        with self.assertRaisesRegex(RuntimeError, "outside LICENSE and README"):
            self.snapshot("v0.1.0-beta.5")

    def public_checkout(self):
        checkout = self.root / "public"
        git(self.root, "clone", "-q", "-b", "main", str(self.remote), str(checkout))
        git(checkout, "config", "user.name", "Test")
        git(checkout, "config", "user.email", "test@example.invalid")
        return checkout

    def test_copied_release_markers_cannot_hide_public_code_changes(self):
        self.snapshot("v0.1.0-beta.4")
        checkout = self.public_checkout()
        (checkout / "app").write_text("unexpected public change")
        git(checkout, "add", "app")
        source_commit = git(self.source, "rev-parse", "HEAD")
        git(checkout, "commit", "-qm",
            f"Copy release metadata\n\nForgejo-Tag: v0.1.0-beta.4\nForgejo-Commit: {source_commit}\n")
        git(checkout, "push", "-q", "origin", "main")
        before = git(self.remote, "rev-parse", "refs/heads/main")
        self.new_tag("v0.1.0-beta.5")
        with self.assertRaisesRegex(RuntimeError, "outside LICENSE and README"):
            self.snapshot("v0.1.0-beta.5")
        self.assertEqual(git(self.remote, "rev-parse", "refs/heads/main"), before)
        self.assertNotIn("v0.1.0-beta.5", git(self.remote, "tag", "--list").splitlines())

    def test_unpublished_markers_cannot_relax_release_ordering(self):
        self.new_tag("v0.1.0-beta.5")
        self.snapshot("v0.1.0-beta.5")
        checkout = self.public_checkout()
        (checkout / "README.md").write_text("public introduction\n")
        git(checkout, "add", "README.md")
        source_commit = git(self.source, "rev-parse", "HEAD")
        git(checkout, "commit", "-qm",
            f"Invent a release baseline\n\nForgejo-Tag: v0.0.1\nForgejo-Commit: {source_commit}\n")
        git(checkout, "push", "-q", "origin", "main")
        before = git(self.remote, "rev-parse", "refs/heads/main")
        with self.assertRaisesRegex(RuntimeError, "published tag"):
            self.snapshot("v0.1.0-beta.4")
        self.assertEqual(git(self.remote, "rev-parse", "refs/heads/main"), before)
        self.assertNotIn("v0.1.0-beta.4", git(self.remote, "tag", "--list").splitlines())

    def test_missing_previous_public_tag_is_rejected(self):
        first = self.snapshot("v0.1.0-beta.4")
        git(self.remote, "tag", "-d", "v0.1.0-beta.4")
        self.new_tag("v0.1.0-beta.5")
        with self.assertRaisesRegex(RuntimeError, "published tag"):
            self.snapshot("v0.1.0-beta.5")
        self.assertEqual(git(self.remote, "rev-parse", "refs/heads/main"), first)
        self.assertEqual(git(self.remote, "tag", "--list"), "")

    def test_missing_latest_tag_cannot_fall_back_to_an_older_release(self):
        first = self.snapshot("v0.1.0-beta.4")
        git(self.source, "tag", "v0.1.0-beta.5")
        second = self.snapshot("v0.1.0-beta.5")
        git(self.remote, "tag", "-d", "v0.1.0-beta.5")
        # Equal source trees must not make a deleted latest tag invisible.
        git(self.source, "tag", "v0.1.0-beta.4.5")
        with self.assertRaisesRegex(RuntimeError, "published tag"):
            self.snapshot("v0.1.0-beta.4.5")
        self.assertEqual(git(self.remote, "rev-parse", "refs/heads/main"), second)
        self.assertEqual(git(self.remote, "rev-parse", "refs/tags/v0.1.0-beta.4"), first)
        self.assertNotIn("v0.1.0-beta.4.5", git(self.remote, "tag", "--list").splitlines())

    def test_documentation_edits_can_copy_release_markers(self):
        first = self.snapshot("v0.1.0-beta.4")
        checkout = self.public_checkout()
        (checkout / "LICENSE").write_text("public license\n")
        (checkout / "README.md").write_text("public introduction\n")
        git(checkout, "add", "LICENSE", "README.md")
        source_commit = git(self.source, "rev-parse", "HEAD")
        git(checkout, "commit", "-qm",
            f"Update public information\n\nForgejo-Tag: v0.1.0-beta.4\nForgejo-Commit: {source_commit}\n")
        git(checkout, "push", "-q", "origin", "main")
        self.new_tag("v0.1.0-beta.5")
        second = self.snapshot("v0.1.0-beta.5")
        self.assertEqual(git(self.remote, "show", f"{second}:LICENSE"), "public license")
        self.assertEqual(git(self.remote, "show", f"{second}:README.md"), "public introduction")
        self.assertEqual(git(self.remote, "rev-parse", "refs/tags/v0.1.0-beta.4"), first)
        self.assertEqual(self.snapshot("v0.1.0-beta.5"), second)

    def test_annotated_previous_public_tag_is_verified(self):
        first = self.snapshot("v0.1.0-beta.4")
        git(self.remote, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "tag", "-fa", "v0.1.0-beta.4", "-m", "Published release", first)
        tag_object = git(self.remote, "rev-parse", "refs/tags/v0.1.0-beta.4")
        self.assertNotEqual(tag_object, first)
        self.new_tag("v0.1.0-beta.5")
        second = self.snapshot("v0.1.0-beta.5")
        self.assertEqual(git(self.remote, "rev-parse", "refs/heads/main"), second)
        self.assertEqual(git(self.remote, "rev-parse", "refs/tags/v0.1.0-beta.4"), tag_object)
        self.assertEqual(self.snapshot("v0.1.0-beta.4"), first)

    def test_leading_whitespace_in_public_path_cannot_bypass_drift_check(self):
        self.snapshot("v0.1.0-beta.4")
        checkout = self.public_checkout()
        (checkout / " LICENSE").write_text("unexpected public file\n")
        git(checkout, "add", " LICENSE")
        git(checkout, "commit", "-qm", "Add a different file with a similar name")
        git(checkout, "push", "-q", "origin", "main")
        before = git(self.remote, "rev-parse", "refs/heads/main")
        self.new_tag("v0.1.0-beta.5")
        with self.assertRaisesRegex(RuntimeError, "outside LICENSE and README"):
            self.snapshot("v0.1.0-beta.5")
        self.assertEqual(git(self.remote, "rev-parse", "refs/heads/main"), before)
        self.assertNotIn("v0.1.0-beta.5", git(self.remote, "tag", "--list").splitlines())

    def test_license_only_bootstrap_must_be_explicit(self):
        initial = self.root / "initial"
        initial.mkdir()
        git(initial, "init", "-q", "-b", "main")
        git(initial, "config", "user.name", "Test")
        git(initial, "config", "user.email", "test@example.invalid")
        (initial / "LICENSE").write_text("license\n")
        git(initial, "add", "LICENSE")
        git(initial, "commit", "-qm", "Initial commit")
        git(initial, "push", "-q", str(self.remote), "main")
        with self.assertRaisesRegex(RuntimeError, "metadata"):
            self.snapshot("v0.1.0-beta.4")
        public = self.snapshot("v0.1.0-beta.4", allow_license_bootstrap=True)
        self.assertEqual(git(self.remote, "rev-list", "--count", public), "2")


class FakeAPI:
    def __init__(self):
        self.release = None
        self.assets = {}
    def get_release(self, tag): return self.release
    def create_draft(self, tag, target_commit, name, body, prerelease):
        self.release = dict(id=1, tag_name=tag, name=name, body=body, prerelease=prerelease, draft=True)
        return self.release
    def list_assets(self, release_id):
        return [dict(name=name, id=name) for name in self.assets]
    def upload_asset(self, release_id, name, data):
        self.assets[name] = data
        return dict(name=name, id=name)
    def download_asset(self, asset_id): return self.assets[asset_id]
    def publish(self, release_id): self.release["draft"] = False


class ReleaseTests(unittest.TestCase):
    def test_artifact_checksum_must_match_before_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            name = "Nevermore-0.1.0-beta.4-macos-universal.dmg"
            dmg = Path(directory) / name
            checksum = Path(directory) / (name + ".sha256")
            dmg.write_bytes(b"release")
            checksum.write_text(hashlib.sha256(b"release").hexdigest() + "  " + name + "\n")
            self.assertEqual(mirror.validate_artifacts("v0.1.0-beta.4", directory)[name], b"release")
            dmg.write_bytes(b"different")
            with self.assertRaisesRegex(RuntimeError, "checksum"):
                mirror.validate_artifacts("v0.1.0-beta.4", directory)

    def test_draft_is_verified_then_published_and_retry_is_idempotent(self):
        api = FakeAPI()
        artifacts = {"app.dmg": b"dmg", "app.dmg.sha256": b"sha"}
        mirror.publish_release(api, "v0.1.0-beta.4", "commit", "notes", artifacts)
        self.assertFalse(api.release["draft"])
        self.assertTrue(api.release["prerelease"])
        mirror.publish_release(api, "v0.1.0-beta.4", "commit", "notes", artifacts)
        api.assets["app.dmg"] = b"different"
        with self.assertRaisesRegex(RuntimeError, "differs"):
            mirror.publish_release(api, "v0.1.0-beta.4", "commit", "notes", artifacts)

    def test_published_release_with_missing_asset_is_not_modified(self):
        api = FakeAPI()
        api.create_draft("v1.0.0", "commit", "v1.0.0", "notes", False)
        api.release["draft"] = False
        with self.assertRaisesRegex(RuntimeError, "missing"):
            mirror.publish_release(api, "v1.0.0", "commit", "notes", {"app.dmg": b"data"})
        self.assertEqual(api.assets, {})

    def test_release_metadata_conflict_is_rejected(self):
        api = FakeAPI()
        api.create_draft("v1.0.0", "commit", "v1.0.0", "other notes", False)
        with self.assertRaisesRegex(RuntimeError, "metadata"):
            mirror.publish_release(api, "v1.0.0", "commit", "notes", {})


if __name__ == "__main__": unittest.main()
