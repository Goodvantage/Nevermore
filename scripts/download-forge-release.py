#!/usr/bin/env python3
"""Retrieve a published release's original Forgejo workflow artifact."""
import io
import hashlib
import json
import os
from pathlib import Path
import sys
from urllib import error, parse, request
import zipfile

from github_release_api import SafeRedirect
from release_version import parse_version

SERVER = "https://forge.goodvantage.cloud"
REPOSITORY = "Goodvantage/Nevermore"
API = f"{SERVER}/api/v1/repos/{REPOSITORY}"


def download(tag, destination, token, opener=None):
    parse_version(tag)
    if not token:
        raise RuntimeError("FORGE_RELEASE_TOKEN is required")
    opener = opener or request.build_opener(SafeRedirect())
    headers = {"Authorization": "token " + token, "User-Agent": "Nevermore-release-mirror"}

    def get(path):
        try:
            with opener.open(request.Request(API + path, headers=headers), timeout=120) as response:
                return response.read()
        except error.HTTPError as exc:
            status = exc.code
            exc.close()
            raise RuntimeError(f"Forgejo release request failed (HTTP {status})") from None

    def get_json(path):
        return json.loads(get(path))

    release = get_json(f"/releases/tags/{parse.quote(tag, safe='')}")
    if (release.get("tag_name") != tag or release.get("name") != tag or release.get("draft") or
            release.get("prerelease") != ("-" in tag)):
        raise RuntimeError("Forgejo release metadata does not match the requested published tag")
    name = f"Nevermore-{tag[1:]}-macos-universal.dmg"
    listed_assets = release.get("assets", [])
    assets = {item["name"]: item for item in listed_assets}
    if len(listed_assets) != 2 or set(assets) != {name, name + ".sha256"}:
        raise RuntimeError("Forgejo release does not have the expected artifacts")

    # The site publishes before Forgejo and keeps each version immutable. Its
    # manifest detects a later rebuild that replaced a run's retained artifact.
    site_url = f"https://apps.goodvantage.cloud/nevermore/{tag[1:]}/release.json"
    try:
        with opener.open(request.Request(site_url), timeout=120) as response:
            manifest = json.loads(response.read())
    except error.HTTPError as exc:
        status = exc.code
        exc.close()
        raise RuntimeError(f"Published site manifest request failed (HTTP {status})") from None
    site_download = manifest.get("downloads", {}).get("macos", {})
    if (manifest.get("schema") != 1 or manifest.get("app") != "nevermore" or
            manifest.get("version") != tag[1:] or manifest.get("notes") != (release.get("body") or "") or
            site_download.get("file") != name or site_download.get("size") != assets[name]["size"]):
        raise RuntimeError("Published site manifest does not match the Forgejo release")

    query = parse.urlencode({"workflow_id": "release.yml", "ref": f"refs/tags/{tag}", "limit": 50})
    runs = get_json(f"/actions/runs?{query}").get("workflow_runs", [])
    candidates = []
    for run in runs:
        if run.get("workflow_id") != "release.yml" or run.get("prettyref") != tag:
            continue
        run_id = run["id"]
        jobs = get_json(f"/actions/runs/{run_id}/jobs")
        if not any(j.get("name") == "Attach the DMG to the forge release" and j.get("status") == "success" for j in jobs):
            continue
        for artifact in get_json(f"/actions/runs/{run_id}/artifacts"):
            if artifact.get("name") == "macos-dmg" and not artifact.get("expired"):
                candidates.append(artifact["id"])
    if len(candidates) != 1:
        raise RuntimeError("Expected one unexpired artifact from a successful Forgejo release job")
    archive = get(f"/actions/artifacts/{candidates[0]}/zip")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        if len(zipped.infolist()) != 2 or set(zipped.namelist()) != set(assets):
            raise RuntimeError("Forgejo workflow artifact contains unexpected files")
        for filename in (name, name + ".sha256"):
            data = zipped.read(filename)
            if len(data) != assets[filename]["size"]:
                raise RuntimeError("Workflow artifact size differs from the Forgejo release")
            if filename == name and hashlib.sha256(data).hexdigest() != site_download.get("sha256"):
                raise RuntimeError("Workflow artifact checksum differs from the published site")
            (destination / filename).write_bytes(data)
    (destination / "release-notes.txt").write_text(release.get("body") or "", encoding="utf-8")


def main():
    if len(sys.argv) != 3:
        raise RuntimeError("Usage: download-forge-release.py TAG DIRECTORY")
    download(sys.argv[1], sys.argv[2], os.environ.get("FORGE_RELEASE_TOKEN"))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # Network errors can contain redirect URLs with temporary credentials.
        detail = str(exc) if type(exc) is RuntimeError else type(exc).__name__
        print(f"Forgejo release download failed: {detail}", file=sys.stderr)
        sys.exit(1)
