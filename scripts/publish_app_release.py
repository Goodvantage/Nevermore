#!/usr/bin/env python3
# Vendored from Goodvantage/apps.goodvantage.cloud, tools/publish.py
# (https://forge.goodvantage.cloud/Goodvantage/apps.goodvantage.cloud), at
# commit 246b5a8a9b2f, the revision GoodDrive vendors as
# scripts/publish_app_release.py. Do not edit it here: change it upstream,
# then refresh this copy. scripts/apps-site-release.sh runs it for the
# apps-site job in .forgejo/workflows/release.yml. Paths in the docstring
# below, such as docs/PROTOCOL.md, are upstream paths.
#
# Apart from this comment block, the file is byte-identical to upstream.
# To check this copy against an upstream publish.py:
#
#   diff <(sed '2,/^# End of the vendoring note/d' \
#     scripts/publish_app_release.py) publish.py
#
# End of the vendoring note.
"""Publish app releases and the download page to apps.goodvantage.cloud.

The one script every app's CI uses. Python 3.9+ standard library only, so a
CI job needs nothing but python3. The protocol it implements is
docs/PROTOCOL.md; read that before changing anything here.

    publish.py release --app gooddrive --name GoodDrive --version 0.4.1 \\
        --file macos=dist/GoodDrive-0.4.1.dmg \\
        --file android=dist/GoodDrive-0.4.1.apk="Android 8 or later"

    publish.py site site/

The site URL and publishing token come from --site-url / --token or the
environment variables APPS_SITE_URL / APPS_SITE_TOKEN. A release needs that
app's token; the page needs the administrator token. The token is never
printed.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime
import hashlib
import http.client
import json
import os
import re
import ssl
import sys
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional, Tuple

TOOL_VERSION = "2"
USER_AGENT = f"apps-publish/{TOOL_VERSION}"
SCHEMA = 1

# Platform ids from the protocol, with the label used when --file gives none.
PLATFORMS = {
    "macos": "macOS",
    "windows-x64": "Windows (64-bit)",
    "linux-deb-amd64": "Linux (.deb, x86-64)",
    "android": "Android",
}
CHANNELS = ("stable", "beta")

MAX_UPLOAD_BYTES = 2 * 1024 * 1024 * 1024  # the server's client_max_body_size
ATTEMPTS = 4  # one try plus three retries
BACKOFF_SECONDS = (2, 5, 10)
TIMEOUT_SECONDS = 120

APP_ID_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
# Top-level paths the site itself uses; an app with one of these ids would
# collide with the page or the upload API.
RESERVED_APP_IDS = {"assets", "healthz", "index", "favicon"}
# Characters a URL path carries unescaped. "~" is how Debian packages spell
# a prerelease (gooddrive-client_0.5.0~rc.1_amd64.deb).
FILE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+~-]{0,199}")
RESERVED_FILE_NAMES = {"release.json"}
# The catalog's limits on what apps.json shows (catalog/catalog.py), checked
# here before the first upload.
MAX_NAME_CHARS = 200
MAX_DESCRIPTION_CHARS = 1000

_NUM = r"0|[1-9][0-9]*"
_PRE_ID = r"0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*"
SEMVER_RE = re.compile(
    rf"(?P<major>{_NUM})\.(?P<minor>{_NUM})\.(?P<patch>{_NUM})"
    rf"(?:-(?P<pre>(?:{_PRE_ID})(?:\.(?:{_PRE_ID}))*))?"
    r"(?:\+(?P<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
)


class PublishError(Exception):
    """A problem the user has to fix; main() prints it and exits 1."""


# --------------------------------------------------------------------------
# Versions


def parse_version(text) -> Optional[Tuple[int, int, int, tuple]]:
    """Parse a semver string (leading "v" tolerated) into a sortable key.

    Returns (major, minor, patch, prerelease identifiers) or None when the
    input is not a valid Semantic Versioning 2.0.0 string. Build metadata is
    dropped because it does not affect precedence.
    """
    if not isinstance(text, str):
        return None
    if text.startswith("v"):
        text = text[1:]
    match = SEMVER_RE.fullmatch(text)
    if not match:
        return None
    pre = match.group("pre")
    identifiers = tuple(int(p) if p.isdigit() else p for p in pre.split(".")) if pre else ()
    return int(match.group("major")), int(match.group("minor")), int(match.group("patch")), identifiers


def _compare_prerelease(a: tuple, b: tuple) -> int:
    if a == b:
        return 0
    # A version without a prerelease ranks above one with a prerelease.
    if not a:
        return 1
    if not b:
        return -1
    for x, y in zip(a, b):
        if x == y:
            continue
        x_num, y_num = isinstance(x, int), isinstance(y, int)
        if x_num and y_num:
            return -1 if x < y else 1
        if x_num != y_num:
            return -1 if x_num else 1  # numeric identifiers rank lower
        return -1 if x < y else 1
    return -1 if len(a) < len(b) else 1


def compare_versions(a: str, b: str) -> int:
    """Return -1, 0 or 1 by semver precedence. Both must be valid."""
    pa, pb = parse_version(a), parse_version(b)
    if pa is None or pb is None:
        raise PublishError(f"not a semantic version: {a if pa is None else b!r}")
    if pa[:3] != pb[:3]:
        return -1 if pa[:3] < pb[:3] else 1
    return _compare_prerelease(pa[3], pb[3])


def is_newer(candidate, current) -> bool:
    """True if `candidate` takes precedence over `current`.

    An unparsable candidate is never newer; any valid candidate is newer than
    a missing or unparsable current version.
    """
    if parse_version(candidate) is None:
        return False
    if parse_version(current) is None:
        return True
    return compare_versions(candidate, current) > 0


def normalize_version(text: str) -> str:
    """Strip a leading "v" and validate; raises PublishError if invalid."""
    if parse_version(text) is None:
        raise PublishError(f"--version {text!r} is not a semantic version like 0.4.1 or 0.5.0-rc.1")
    return text[1:] if text.startswith("v") else text


def channel_for(version: str) -> str:
    """"beta" for a prerelease (X.Y.Z-anything), otherwise "stable"."""
    parsed = parse_version(version)
    if parsed is None:
        raise PublishError(f"not a semantic version: {version!r}")
    return "beta" if parsed[3] else "stable"


# --------------------------------------------------------------------------
# Artifacts, manifests and the app index


@dataclass(frozen=True)
class Artifact:
    platform: str
    path: Path
    file: str
    size: int
    sha256: str
    label: str


def describe_artifact(spec: str) -> Artifact:
    """Turn a --file PLATFORM=PATH[=LABEL] argument into an Artifact.

    Validates the platform id, the file and its name, and hashes the file.
    PATH cannot contain "=" (everything after a second "=" is the label).
    """
    platform, sep, rest = spec.partition("=")
    if not sep or not rest:
        raise PublishError(f"--file {spec!r}: expected PLATFORM=PATH[=LABEL]")
    if platform not in PLATFORMS:
        raise PublishError(f"--file {spec!r}: unknown platform {platform!r}; use one of {', '.join(PLATFORMS)}")
    raw_path, _, label = rest.partition("=")
    path = Path(raw_path)
    if not path.is_file():
        raise PublishError(f"--file {spec!r}: {raw_path} is not a file")
    name = path.name
    if not FILE_NAME_RE.fullmatch(name) or name in RESERVED_FILE_NAMES:
        raise PublishError(
            f"--file {spec!r}: file name {name!r} must start with a letter or digit and use only "
            "letters, digits and . _ + ~ - (and must not be release.json); rename it before publishing"
        )
    size = path.stat().st_size
    if size > MAX_UPLOAD_BYTES:
        raise PublishError(f"--file {spec!r}: {size} bytes is over the {MAX_UPLOAD_BYTES} byte upload limit")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return Artifact(platform, path, name, size, digest.hexdigest(), label.strip() or PLATFORMS[platform])


def _quote(path: str) -> str:
    return urllib.parse.quote(path, safe="/+")


def build_manifest(*, site_url: str, app: str, name: str, version: str, released_at: str,
                   notes: str, artifacts: List[Artifact]) -> dict:
    """Build the release manifest (schema 1) for `version`."""
    base = site_url.rstrip("/")
    manifest = {
        "schema": SCHEMA,
        "app": app,
        "name": name,
        "channel": channel_for(version),
        "version": version,
        "released_at": released_at,
    }
    if notes:
        manifest["notes"] = notes
    manifest["page_url"] = f"{base}/#{app}"
    manifest["downloads"] = {
        a.platform: {
            "url": f"{base}/{_quote(f'{app}/{version}/{a.file}')}",
            "file": a.file,
            "size": a.size,
            "sha256": a.sha256,
            "label": a.label,
        }
        for a in artifacts
    }
    return manifest


def same_artifacts(existing, downloads):
    old = existing.get("downloads") if isinstance(existing, dict) else None
    if not isinstance(old, dict) or old.keys() != downloads.keys():
        return False
    return all(isinstance(old[p], dict) and
               all(old[p].get(k) == d[k] for k in ("file", "size", "sha256"))
               for p, d in downloads.items())


def register_app(site, *, app: str, name: str, description: Optional[str], channels: List[str],
                 updated_at: str) -> None:
    """Add or update this app's entry in apps.json through the catalog API.

    The site merges the entry under a lock, keeping other apps, unknown
    fields and listed channels, so parallel releases of different apps never
    drop each other. `description=None` keeps the existing description.
    Sending the same registration again changes nothing, so a retry after a
    lost response is safe.
    """
    registration = {"name": name, "channels": channels, "updated_at": updated_at}
    if description is not None:
        registration["description"] = description
    answer = site.post_json(f"_catalog/apps/{app}", registration)
    entry = answer.get("app") if isinstance(answer, dict) else None
    if not isinstance(entry, dict) or entry.get("id") != app:
        raise PublishError(f"the site did not confirm {app} in apps.json")


def to_json_bytes(document: dict) -> bytes:
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


# --------------------------------------------------------------------------
# HTTP


class RedactingWriter:
    """Apply the same secret filtering to every output destination."""

    def __init__(self, stream, secrets):
        self.stream = stream
        self.secrets = sorted({s.strip() for s in secrets if s and s.strip()},
                              key=len, reverse=True)

    def write(self, message):
        for secret in self.secrets:
            message = message.replace(secret, "***")
        return self.stream.write(message)

    def flush(self):
        self.stream.flush()


class Site:
    """Reads public files and writes through /_upload/ with retries."""

    def __init__(self, url: str, token: Optional[str], *, sleep: Callable[[float], None] = time.sleep,
                 log=None) -> None:
        url = _site_url(url)
        parts = urllib.parse.urlsplit(url)
        self.url = url.rstrip("/")
        self._https = parts.scheme == "https"
        self._host = parts.hostname or ""
        self._port = parts.port
        self._prefix = parts.path.rstrip("/")
        self._token = token
        self._sleep = sleep
        self._log = RedactingWriter(log or sys.stderr, [token])

    def upload_url(self, path: str) -> str:
        return f"{self.url}/_upload/{_quote(path)}"

    def get_json(self, path: str):
        """GET a public JSON file. Returns None on 404; raises on bad JSON."""
        status, body = self._request("GET", f"/{_quote(path)}", None, {"Accept": "application/json"},
                                     allow_404=True)
        if status == 404:
            return None
        try:
            document = json.loads(body.decode("utf-8"))
            if document is None:
                raise PublishError(f"{path} on the site is JSON null; expected a manifest object")
            return document
        except (UnicodeDecodeError, ValueError) as exc:
            raise PublishError(f"{path} on the site is not valid JSON") from None

    def post_json(self, path: str, document: dict):
        """POST a JSON document to an API path and return the JSON answer."""
        data = to_json_bytes(document)
        _, body = self._request("POST", f"/{_quote(path)}", lambda: data,
                                {"Content-Type": "application/json", "Content-Length": str(len(data))}, auth=True)
        try:
            return json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise PublishError(f"POST {self._prefix}/{path}: the site answered with invalid JSON") from None

    def put_bytes(self, path: str, data: bytes, content_type: str = "application/json") -> None:
        self._request("PUT", f"/_upload/{_quote(path)}", lambda: data,
                      {"Content-Type": content_type, "Content-Length": str(len(data))}, auth=True)

    def put_file(self, path: str, source: Path, size: int) -> None:
        handles = []

        def body():
            handle = source.open("rb")
            handles.append(handle)
            return handle

        try:
            self._request("PUT", f"/_upload/{_quote(path)}", body,
                          {"Content-Type": "application/octet-stream", "Content-Length": str(size)}, auth=True)
        finally:
            for handle in handles:
                handle.close()

    def _connect(self) -> http.client.HTTPConnection:
        cls = http.client.HTTPSConnection if self._https else http.client.HTTPConnection
        # Large send blocks: artifacts can be up to 2 GiB.
        return cls(self._host, self._port, timeout=TIMEOUT_SECONDS, blocksize=1024 * 1024)

    def _request(self, method: str, path: str, body: Optional[Callable], headers: dict, *,
                 auth: bool = False, allow_404: bool = False) -> Tuple[int, bytes]:
        headers = dict(headers, **{"User-Agent": USER_AGENT})
        if auth:
            headers["Authorization"] = f"Bearer {self._token}"
        else:
            headers["Cache-Control"] = "no-cache"  # ask any cache in front to revalidate
        shown = f"{method} {self._prefix}{path}"
        for attempt in range(1, ATTEMPTS + 1):
            conn = self._connect()
            try:
                conn.request(method, self._prefix + path, body=body() if body else None, headers=headers)
                response = conn.getresponse()
                data = response.read()
                status = response.status
            except (OSError, http.client.HTTPException) as exc:
                if isinstance(exc, getattr(ssl, "SSLCertVerificationError", ())):
                    raise PublishError(f"{shown} failed: {type(exc).__name__}") from None
                problem = type(exc).__name__
            else:
                if 200 <= status < 300 or (allow_404 and status == 404):
                    return status, data
                if status < 500:
                    raise PublishError(f"{shown} failed: HTTP {status}{_hint(status)}")
                problem = f"HTTP {status}"
            finally:
                conn.close()
            if attempt == ATTEMPTS:
                raise PublishError(f"{shown} failed after {ATTEMPTS} attempts: {problem}")
            delay = BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS)) - 1]
            print(f"{shown} failed ({problem}); retry {attempt} of {ATTEMPTS - 1} in {delay}s",
                  file=self._log)
            self._sleep(delay)
        raise AssertionError("unreachable")


def _hint(status: int) -> str:
    if status == 400:
        return " (the site refused the request as invalid)"
    if status == 401:
        return " (the site does not accept APPS_SITE_TOKEN; check the repository's secret)"
    if status == 403:
        return (" (APPS_SITE_TOKEN may not write here: an app's token publishes only that app, and"
                " the download page needs the administrator token)")
    if status == 404:
        return " (the site lacks this API; update it to the current apps.goodvantage.cloud)"
    if status == 409:
        return " (apps.json on the site is malformed; an administrator must repair it)"
    if status == 413:
        return " (the server or the reverse proxy in front of it refuses a body this large)"
    if 300 <= status < 400:
        return " (redirects are not followed; set APPS_SITE_URL to the final https:// URL)"
    return ""


# --------------------------------------------------------------------------
# Commands


def _site_url(value: Optional[str]) -> str:
    url = (value or os.environ.get("APPS_SITE_URL") or "").strip()
    if not url:
        raise PublishError("no site URL: pass --site-url or set APPS_SITE_URL")
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.query or parts.fragment:
        raise PublishError(f"site URL {url!r} must look like https://apps.goodvantage.cloud")
    if parts.scheme == "http" and parts.hostname not in ("127.0.0.1", "::1", "localhost"):
        raise PublishError("site URL requires HTTPS; HTTP is allowed only for loopback hosts")
    return url.rstrip("/")


def _token(value: Optional[str]) -> str:
    token = (value or os.environ.get("APPS_SITE_TOKEN") or "").strip()
    if not token:
        raise PublishError("no upload token: pass --token or set APPS_SITE_TOKEN")
    if any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in token):
        raise PublishError("the upload token contains whitespace or control characters")
    return token


def _text(value: str, option: str, limit: int, allowed: str = "") -> str:
    """Check display text against the catalog's rules; returns it stripped."""
    text = value.strip()
    controls = [ch for ch in text if (ord(ch) < 0x20 and ch not in allowed) or ord(ch) == 0x7F]
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:  # bytes the system could not decode
        raise PublishError(f"{option} is not valid UTF-8 text") from None
    if controls:
        raise PublishError(f"{option} must not contain control characters"
                           + (" other than tabs and line breaks" if allowed else ""))
    if len(text) > limit:
        raise PublishError(f"{option} is {len(text)} characters; the site allows at most {limit}")
    return text


def _released_at(value: Optional[str]) -> str:
    if value is None:
        moment = datetime.datetime.now(datetime.timezone.utc)
    else:
        text = value.strip()
        try:
            moment = datetime.datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text)
        except ValueError:
            raise PublishError(f"--released-at {value!r} is not an ISO 8601 time like 2026-10-12T10:00:00Z") from None
        if moment.tzinfo is None:
            raise PublishError(f"--released-at {value!r} needs a time zone, for example a trailing Z for UTC")
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_notes(path: Optional[str]) -> str:
    if not path:
        return ""
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise PublishError(f"--notes-file {path}: {exc}") from None


def cmd_release(args, sleep, out, err) -> int:
    # Validate everything before the first request so a typo never leaves a
    # half-published release behind.
    app = args.app
    if not APP_ID_RE.fullmatch(app) or app in RESERVED_APP_IDS:
        raise PublishError(f"--app {app!r} must be a lowercase id like gooddrive (a-z, 0-9, -) and not a reserved name")
    name = _text(args.name, "--name", MAX_NAME_CHARS)
    if not name:
        raise PublishError("--name must not be empty")
    version = normalize_version(args.version)
    channel = channel_for(version)
    if not args.file:
        raise PublishError("give at least one --file PLATFORM=PATH[=LABEL]")
    artifacts = [describe_artifact(spec) for spec in args.file]
    platforms = [a.platform for a in artifacts]
    for platform in sorted({p for p in platforms if platforms.count(p) > 1}):
        raise PublishError(f"platform {platform} is given more than once")
    files = [a.file for a in artifacts]
    for file in sorted({f for f in files if files.count(f) > 1}):
        raise PublishError(f"two --file arguments share the file name {file}; each artifact needs its own name")
    released_at = _released_at(args.released_at)
    notes = _read_notes(args.notes_file)
    site_url = _site_url(args.site_url)
    token = None if args.dry_run else _token(args.token)
    description = (_text(args.description, "--description", MAX_DESCRIPTION_CHARS, "\t\n")
                   if args.description is not None else None)

    manifest = build_manifest(site_url=site_url, app=app, name=name, version=version,
                              released_at=released_at, notes=notes, artifacts=artifacts)
    manifest_bytes = to_json_bytes(manifest)
    site = Site(site_url, token, sleep=sleep, log=err)

    if args.dry_run:
        print("Dry run: nothing is uploaded. The release would publish, in this order:", file=err)
        print(f"  GET {site_url}/{app}/{version}/release.json  (check existing artifacts)", file=err)
        for a in artifacts:
            print(f"  PUT {site.upload_url(f'{app}/{version}/{a.file}')}  ({a.size} bytes, sha256 {a.sha256})", file=err)
        print(f"  PUT {site.upload_url(f'{app}/{version}/release.json')}", file=err)
        if channel == "stable":
            print(f"  GET {site_url}/{app}/beta.json  (to decide whether beta.json moves to {version})", file=err)
        print(f"  POST {site_url}/_catalog/apps/{app}  (add or update {app} in apps.json)", file=err)
        if channel == "stable":
            print(f"  PUT {site.upload_url(f'{app}/beta.json')}  (only if {version} is newer than the current beta)",
                  file=err)
        print(f"  PUT {site.upload_url(f'{app}/{channel}.json')}", file=err)
        out.write(manifest_bytes.decode("utf-8"))
        return 0

    # Publish order from docs/PROTOCOL.md: artifacts, release.json, the app's
    # catalog entry, and the channel manifest last, so clients never see a
    # manifest whose files are missing. A failure at any step stops before
    # the channel manifests move.
    existing = site.get_json(f"{app}/{version}/release.json")
    matches = existing is not None and same_artifacts(existing, manifest["downloads"])
    if existing is not None and not matches and not args.force:
        raise PublishError(f"{app}/{version} already exists with different artifacts; "
                           "publish a new version or pass --force")
    if not matches:
        for a in artifacts:
            print(f"Uploading {a.file} ({a.size} bytes)", file=err)
            site.put_file(f"{app}/{version}/{a.file}", a.path, a.size)
        site.put_bytes(f"{app}/{version}/release.json", manifest_bytes)

    update_beta = False
    channels = [channel]
    if channel == "stable":
        current_beta = site.get_json(f"{app}/beta.json")
        beta_version = current_beta.get("version") if isinstance(current_beta, dict) else None
        update_beta = is_newer(version, beta_version)
        if update_beta or current_beta is not None:
            channels.append("beta")

    register_app(site, app=app, name=name, description=description, channels=channels,
                 updated_at=released_at)
    if update_beta:
        print(f"Pointing the beta channel at {version}", file=err)
        site.put_bytes(f"{app}/beta.json", manifest_bytes)
    site.put_bytes(f"{app}/{channel}.json", manifest_bytes)
    print(f"Published {name} {version} to the {channel} channel", file=err)
    out.write(manifest_bytes.decode("utf-8"))
    return 0


def _site_files(root: Path) -> List[Tuple[str, Path]]:
    if not (root / "index.html").is_file():
        raise PublishError(f"{root} has no index.html; is this the site directory?")
    files, refused = [], []
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        if any(part.startswith(".") for part in rel.parts) or not path.is_file():
            continue
        name = rel.as_posix()
        # Top-level JSON and directories other than assets/ belong to app
        # releases; the page must never overwrite them.
        if (len(rel.parts) == 1 and name.endswith(".json")) or (len(rel.parts) > 1 and rel.parts[0] != "assets"):
            refused.append(name)
        files.append((name, path))
    if refused:
        raise PublishError("the site may only contain top-level page files and assets/; refusing "
                           + ", ".join(refused))
    # index.html last, so a new page never references assets not yet uploaded.
    return sorted(files, key=lambda item: (item[0] == "index.html", item[0]))


def cmd_site(args, sleep, out, err) -> int:
    root = Path(args.dir)
    files = _site_files(root)
    site = Site(_site_url(args.site_url), _token(args.token), sleep=sleep, log=err)
    for name, path in files:
        print(f"Uploading {name}", file=err)
        site.put_file(name, path, path.stat().st_size)
    print(f"Published {len(files)} site files to {site.url}", file=err)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="publish.py", description=__doc__.split("\n\n")[0])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--site-url", help="site root, e.g. https://apps.goodvantage.cloud (env APPS_SITE_URL)")
    common.add_argument("--token", help="upload token (env APPS_SITE_TOKEN); prefer the environment in CI")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")
    sub.required = True

    release = sub.add_parser("release", parents=[common], help="publish a new app version")
    release.add_argument("--app", required=True, help="lowercase app id, e.g. gooddrive")
    release.add_argument("--name", required=True, help="display name, e.g. GoodDrive")
    release.add_argument("--description", help="one-line description for the download page (kept if omitted)")
    release.add_argument("--version", required=True, help="semantic version, e.g. 0.4.1 or 0.5.0-rc.1")
    release.add_argument("--notes-file", help="plain-text release notes")
    release.add_argument("--released-at", help="ISO 8601 release time (default: now)")
    release.add_argument("--file", action="append", metavar="PLATFORM=PATH[=LABEL]",
                         help=f"an artifact to publish; PLATFORM is one of {', '.join(PLATFORMS)}")
    release.add_argument("--force", action="store_true", help="allow replacing changed version artifacts")
    release.add_argument("--dry-run", action="store_true", help="print the plan and manifest, upload nothing")

    site = sub.add_parser("site", parents=[common], help="upload the static download page")
    site.add_argument("dir", help="directory with index.html and assets/")
    return parser


def _main(argv: Optional[List[str]] = None, sleep: Callable[[float], None] = time.sleep) -> int:
    args = build_parser().parse_args(argv)
    out, err = sys.stdout, sys.stderr
    try:
        if args.command == "release":
            return cmd_release(args, sleep, out, err)
        return cmd_site(args, sleep, out, err)
    except PublishError as exc:
        message = str(exc)
        for secret in {args.token, os.environ.get("APPS_SITE_TOKEN")}:
            if secret and secret.strip():
                message = message.replace(secret.strip(), "***")
        print(f"error: {message}", file=err)
        return 1


def main(argv: Optional[List[str]] = None, sleep: Callable[[float], None] = time.sleep) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    secrets = [os.environ.get("APPS_SITE_TOKEN")]
    for i, arg in enumerate(argv):
        if arg == "--token" and i + 1 < len(argv):
            secrets.append(argv[i + 1])
        elif arg.startswith("--token="):
            secrets.append(arg.partition("=")[2])
    with contextlib.redirect_stdout(RedactingWriter(sys.stdout, secrets)), \
            contextlib.redirect_stderr(RedactingWriter(sys.stderr, secrets)):
        return _main(argv, sleep)


if __name__ == "__main__":
    sys.exit(main())
