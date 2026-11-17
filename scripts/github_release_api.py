"""Minimal GitHub release API; credentials never enter URLs or diagnostics."""
import json
import re
from urllib import error, parse, request


class APIError(RuntimeError):
    def __init__(self, status, operation):
        super().__init__(f"GitHub {operation} failed (HTTP {status})")
        self.status = status


class SafeRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if parse.urlsplit(newurl).scheme != "https":
            raise RuntimeError("GitHub returned a non-HTTPS redirect")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and parse.urlsplit(req.full_url).netloc != parse.urlsplit(newurl).netloc:
            redirected.remove_header("Authorization")
        return redirected


class GitHubReleaseAPI:
    def __init__(self, repo, token):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("Invalid GitHub repository")
        self.repo = repo
        self.token = token
        self.opener = request.build_opener(SafeRedirect())

    def call(self, operation, url, method="GET", payload=None, binary=False, accept="application/vnd.github+json"):
        headers = {"Authorization": "Bearer " + self.token, "Accept": accept,
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Nevermore-release-mirror"}
        if payload is not None:
            headers["Content-Type"] = "application/octet-stream" if binary else "application/json"
            if not binary:
                payload = json.dumps(payload).encode("utf-8")
        req = request.Request(url, data=payload, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=120) as response:
                content = response.read()
        except error.HTTPError as exc:
            status = exc.code
            exc.close()
            raise APIError(status, operation) from None
        except error.URLError as exc:
            raise RuntimeError(f"GitHub {operation} failed: network error") from exc
        if binary:
            return content
        return json.loads(content)

    def get_release(self, tag):
        url = f"https://api.github.com/repos/{self.repo}/releases/tags/{parse.quote(tag, safe='')}"
        try:
            return self.call("read release", url)
        except APIError as exc:
            if exc.status == 404:
                return None
            raise

    def create_draft(self, tag, target_commit, name, body, prerelease):
        return self.call("create draft", f"https://api.github.com/repos/{self.repo}/releases", "POST",
                         {"tag_name": tag, "target_commitish": target_commit, "name": name,
                          "body": body, "draft": True, "prerelease": prerelease})

    def list_assets(self, release_id):
        result = []
        page = 1
        while True:
            items = self.call("list assets", f"https://api.github.com/repos/{self.repo}/releases/{release_id}/assets?per_page=100&page={page}")
            result.extend(items)
            if len(items) < 100:
                return result
            page += 1

    def download_asset(self, asset_id):
        return self.call("download asset", f"https://api.github.com/repos/{self.repo}/releases/assets/{asset_id}",
                         binary=True, accept="application/octet-stream")

    def upload_asset(self, release_id, name, data):
        url = f"https://uploads.github.com/repos/{self.repo}/releases/{release_id}/assets?name={parse.quote(name, safe='')}"
        # The request is binary but GitHub's response is JSON.
        raw = self.call("upload asset", url, "POST", data, binary=True)
        return json.loads(raw)

    def publish(self, release_id):
        return self.call("publish release", f"https://api.github.com/repos/{self.repo}/releases/{release_id}",
                         "PATCH", {"draft": False})
