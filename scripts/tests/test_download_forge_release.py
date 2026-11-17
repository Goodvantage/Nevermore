import importlib.util
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from urllib import error
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('forge_download', SCRIPTS / 'download-forge-release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
TAG = 'v0.1.0-beta.4'
NAME = 'Nevermore-0.1.0-beta.4-macos-universal.dmg'


class FakeOpener:
    def __init__(self):
        self.release = {'tag_name': TAG, 'name': TAG, 'draft': False, 'prerelease': True,
                        'body': 'notes', 'assets': [{'name': n, 'size': 8} for n in (NAME, NAME + '.sha256')]}
        self.runs = [{'id': 1, 'workflow_id': 'release.yml', 'prettyref': TAG}]
        self.jobs = [{'name': 'Attach the DMG to the forge release', 'status': 'success'}]
        self.artifacts = [{'id': 2, 'name': 'macos-dmg', 'expired': False}]
        self.manifest = {'schema': 1, 'app': 'nevermore', 'version': TAG[1:], 'notes': 'notes',
                         'downloads': {'macos': {'file': NAME, 'size': 8,
                                                  'sha256': hashlib.sha256(b'artifact').hexdigest()}}}
        self.calls = []
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            z.writestr(NAME, b'artifact')
            z.writestr(NAME + '.sha256', b'artifact')
        self.archive = data.getvalue()
    def open(self, req, timeout):
        self.calls.append(req)
        url = req.full_url
        if url.startswith('https://apps.goodvantage.cloud/'): value = self.manifest
        elif '/releases/tags/' in url: value = self.release
        elif '/actions/runs?' in url: value = {'workflow_runs': self.runs}
        elif url.endswith('/jobs'): value = self.jobs
        elif url.endswith('/runs/1/artifacts'): value = self.artifacts
        elif url.endswith('/artifacts/2/zip'): return io.BytesIO(self.archive)
        else: raise AssertionError(url)
        return io.BytesIO(json.dumps(value).encode())


class ForgeReleaseTests(unittest.TestCase):
    def test_original_artifact_for_published_release_is_downloaded(self):
        opener = FakeOpener()
        with tempfile.TemporaryDirectory() as temp:
            module.download(TAG, temp, 'secret', opener)
            self.assertEqual((Path(temp) / 'release-notes.txt').read_text(), 'notes')
            self.assertEqual((Path(temp) / NAME).read_bytes(), b'artifact')
            for req in opener.calls:
                expected = 'token secret' if req.full_url.startswith(module.API) else None
                self.assertEqual(req.get_header('Authorization'), expected)

    def test_draft_and_ambiguous_or_expired_artifacts_are_rejected(self):
        for mutation in ('draft', 'duplicate', 'expired', 'wrong_size', 'unpublished', 'wrong_digest'):
            opener = FakeOpener()
            if mutation == 'draft': opener.release['draft'] = True
            if mutation == 'duplicate': opener.artifacts.append(dict(opener.artifacts[0]))
            if mutation == 'expired': opener.artifacts[0]['expired'] = True
            if mutation == 'wrong_size': opener.release['assets'][0]['size'] = 9
            if mutation == 'unpublished': opener.jobs[0]['status'] = 'failure'
            if mutation == 'wrong_digest': opener.manifest['downloads']['macos']['sha256'] = '0' * 64
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temp, self.assertRaises(RuntimeError):
                module.download(TAG, temp, 'secret', opener)

    def test_http_error_does_not_expose_url_or_response(self):
        class Failure:
            def open(self, req, timeout):
                raise error.HTTPError(req.full_url, 403, 'private token', {}, io.BytesIO())

        with tempfile.TemporaryDirectory() as temp, self.assertRaises(RuntimeError) as raised:
            module.download(TAG, temp, 'secret', Failure())
        self.assertEqual(str(raised.exception), 'Forgejo release request failed (HTTP 403)')


if __name__ == '__main__': unittest.main()
