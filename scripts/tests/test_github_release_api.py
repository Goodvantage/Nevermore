import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from github_release_api import APIError, GitHubReleaseAPI, SafeRedirect
from release_version import compare_versions, parse_version


class VersionTests(unittest.TestCase):
    def test_semver_precedence(self):
        ordered = ["v1.0.0-alpha", "v1.0.0-alpha.1", "v1.0.0-alpha.beta",
                   "v1.0.0-beta", "v1.0.0-beta.2", "v1.0.0-beta.11",
                   "v1.0.0-rc.1", "v1.0.0", "v1.0.1"]
        for a, b in zip(ordered, ordered[1:]):
            self.assertEqual(compare_versions(a, b), -1)
            self.assertEqual(compare_versions(b, a), 1)
        self.assertEqual(compare_versions(ordered[0], ordered[0]), 0)

    def test_invalid_versions(self):
        for tag in ["1.0.0", "v01.0.0", "v1.0.0-01", "v1.0.0-a..b", "v1.0.0+build"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError): parse_version(tag)


class APITests(unittest.TestCase):
    def test_redirect_does_not_leak_credential(self):
        old = Request("https://api.github.com/a", headers={"Authorization": "Bearer secret"})
        handler = SafeRedirect()
        other = handler.redirect_request(old, None, 302, "Found", {}, "https://objects.githubusercontent.com/a")
        self.assertIsNone(other.get_header("Authorization"))
        same = handler.redirect_request(old, None, 302, "Found", {}, "https://api.github.com/b")
        self.assertEqual(same.get_header("Authorization"), "Bearer secret")
        with self.assertRaises(RuntimeError):
            handler.redirect_request(old, None, 302, "Found", {}, "http://example.com/a")

    def test_missing_release_only_swallows_404(self):
        api = GitHubReleaseAPI("Goodvantage/Nevermore", "secret")
        with patch.object(api, "call", side_effect=APIError(404, "read")):
            self.assertIsNone(api.get_release("v1.0.0"))
        with patch.object(api, "call", side_effect=APIError(403, "read")):
            with self.assertRaises(APIError): api.get_release("v1.0.0")

    def test_pagination_and_draft_payload(self):
        api = GitHubReleaseAPI("Goodvantage/Nevermore", "secret")
        with patch.object(api, "call", side_effect=[list(range(100)), [100]]) as call:
            self.assertEqual(len(api.list_assets(3)), 101)
            self.assertIn("page=2", call.call_args.args[1])
        with patch.object(api, "call", return_value={}) as call:
            api.create_draft("v1.0.0-beta.1", "abc", "v1.0.0-beta.1", "notes", True)
            self.assertEqual(call.call_args.args[3]["draft"], True)
            self.assertEqual(call.call_args.args[3]["prerelease"], True)

    def test_diagnostics_do_not_expose_http_error_body(self):
        api = GitHubReleaseAPI("Goodvantage/Nevermore", "secret")
        failure = HTTPError("https://api.github.com/", 403, "secret", {}, io.BytesIO(b"secret"))
        with patch.object(api.opener, "open", side_effect=failure):
            with self.assertRaises(APIError) as raised: api.get_release("v1.0.0")
        self.assertNotIn("secret", str(raised.exception))


if __name__ == "__main__": unittest.main()
