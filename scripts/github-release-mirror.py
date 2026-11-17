#!/usr/bin/env python3
"""Publish a release-only, history-free snapshot and its existing artifacts."""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from github_release_api import GitHubReleaseAPI
from release_version import compare_versions, parse_version

REPOSITORY = "Goodvantage/Nevermore"
TAG_LINE = re.compile(r"^Forgejo-Tag: (v[^\s]+)$", re.MULTILINE)
COMMIT_LINE = re.compile(r"^Forgejo-Commit: ([0-9a-f]{40,64})$", re.MULTILINE)


def run_git(args, *, cwd, env=None, input_data=None):
    result = subprocess.run(["git", *args], cwd=cwd, env=env, input=input_data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    # Preserve filename whitespace in NUL-delimited output used for drift checks.
    return result.stdout.decode().rstrip("\n")


def auth_environment(token):
    env = os.environ.copy()
    env.update({"GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
                "GIT_CONFIG_VALUE_0": "AUTHORIZATION: basic " + base64.b64encode(
                    ("x-access-token:" + token).encode()).decode(),
                "GIT_AUTHOR_NAME": "Nevermore Release",
                "GIT_AUTHOR_EMAIL": "release@users.noreply.github.com",
                "GIT_COMMITTER_NAME": "Nevermore Release",
                "GIT_COMMITTER_EMAIL": "release@users.noreply.github.com"})
    return env


def marker(message, pattern, description):
    matches = pattern.findall(message)
    if len(matches) != 1:
        raise RuntimeError(f"GitHub snapshot has invalid {description} metadata")
    return matches[0]


def project_public_tree(source_tree, public_ref, *, cwd, env):
    """Keep GitHub's public-facing license and introduction on release snapshots."""
    index_env = env.copy()
    index_env["GIT_INDEX_FILE"] = str(Path(cwd) / "public-snapshot-index")
    run_git(["read-tree", source_tree], cwd=cwd, env=index_env)
    for path in ("LICENSE", "README.md"):
        entry = run_git(["ls-tree", public_ref, "--", path], cwd=cwd, env=index_env)
        if not entry:
            if run_git(["ls-tree", source_tree, "--", path], cwd=cwd, env=index_env):
                raise RuntimeError(f"GitHub main is missing {path}")
            continue
        metadata, name = entry.split("\t", 1)
        mode, kind, blob = metadata.split()
        if name != path or mode != "100644" or kind != "blob":
            raise RuntimeError(f"GitHub {path} is not a regular file")
        run_git(["update-index", "--add", "--cacheinfo", mode, blob, path], cwd=cwd, env=index_env)
    return run_git(["write-tree"], cwd=cwd, env=index_env)


def latest_public_release(parent, refs, *, cwd, env):
    """Allow normal GitHub edits to public copy while rejecting other drift."""
    for candidate in run_git(["rev-list", "--first-parent", parent], cwd=cwd, env=env).splitlines():
        message = run_git(["show", "-s", "--format=%B", candidate], cwd=cwd, env=env)
        if not TAG_LINE.search(message) or not COMMIT_LINE.search(message):
            continue
        previous = marker(message, TAG_LINE, "tag")
        marker(message, COMMIT_LINE, "commit")
        # Copied release markers on main cannot establish a new baseline.
        # ls-remote supplies the peeled commit for annotated public tags too.
        tag_ref = f"refs/tags/{previous}"
        tagged_commit = refs.get(f"{tag_ref}^{{}}", refs.get(tag_ref))
        if tagged_commit is None:
            raise RuntimeError("GitHub release metadata refers to a missing published tag")
        if tagged_commit != candidate:
            # Public copy edits can legitimately copy an existing release's
            # markers, but cannot replace it as the baseline. A missing tag
            # above must fail closed, never fall back to an older release.
            continue
        changed = run_git(["diff", "--name-only", "-z", candidate, parent], cwd=cwd, env=env)
        if set(filter(None, changed.split("\0"))) - {"LICENSE", "README.md"}:
            raise RuntimeError("GitHub main contains changes outside LICENSE and README.md")
        return previous
    raise RuntimeError("GitHub snapshot has invalid published tag metadata")


def publish_snapshot(source, tag, token, repo=REPOSITORY, *, remote_url=None,
                     allow_license_bootstrap=False):
    """Return the public commit. GitHub only receives the source tree, never its history."""
    parse_version(tag)
    if not tag.startswith("v"):
        raise ValueError("release tag must start with v")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid GitHub repository")
    commit = run_git(["rev-parse", "--verify", f"{tag}^{{commit}}"], cwd=source)
    tree = run_git(["rev-parse", "--verify", f"{commit}^{{tree}}"], cwd=source)
    env = auth_environment(token)
    with tempfile.TemporaryDirectory(prefix="nevermore-github-") as tmp:
        run_git(["init", "--bare", "--quiet", tmp], cwd=source, env=env)
        run_git(["fetch", "--quiet", "--no-tags", str(source), commit], cwd=tmp, env=env)
        remote = remote_url or f"https://github.com/{repo}.git"
        refs = run_git(["ls-remote", "--heads", "--tags", remote], cwd=tmp, env=env)
        refs = dict(line.split("\t", 1)[::-1] for line in refs.splitlines() if line)
        head_ref = "refs/heads/main"
        tag_ref = f"refs/tags/{tag}"
        if head_ref in refs:
            run_git(["fetch", "--quiet", "--no-tags", remote, f"+{head_ref}:refs/heads/main"], cwd=tmp, env=env)
        if tag_ref in refs:
            run_git(["fetch", "--quiet", "--no-tags", remote, f"+{tag_ref}:{tag_ref}"], cwd=tmp, env=env)
            public_commit = run_git(["rev-parse", f"{tag_ref}^{{commit}}"], cwd=tmp, env=env)
            public_tree = run_git(["rev-parse", f"{public_commit}^{{tree}}"], cwd=tmp, env=env)
            message = run_git(["show", "-s", "--format=%B", public_commit], cwd=tmp, env=env)
            if (public_tree != tree and
                    public_tree != project_public_tree(tree, public_commit, cwd=tmp, env=env)):
                raise RuntimeError("Existing GitHub tag conflicts with Forgejo source")
            if (marker(message, TAG_LINE, "tag") != tag or
                    marker(message, COMMIT_LINE, "commit") != commit):
                raise RuntimeError("Existing GitHub tag conflicts with Forgejo source")
            if head_ref not in refs:
                raise RuntimeError("GitHub tag exists but main is missing")
            run_git(["merge-base", "--is-ancestor", public_commit, head_ref], cwd=tmp, env=env)
            return public_commit
        parent = None
        bootstrap = False
        if head_ref in refs:
            parent = refs[head_ref]
            message = run_git(["show", "-s", "--format=%B", parent], cwd=tmp, env=env)
            if (allow_license_bootstrap and not TAG_LINE.search(message) and
                    not any(ref.startswith("refs/tags/") for ref in refs)):
                parents = run_git(["rev-list", "--parents", "-n", "1", parent], cwd=tmp, env=env).split()
                listing = run_git(["ls-tree", parent], cwd=tmp, env=env)
                license_blob = run_git(["rev-parse", f"{commit}:LICENSE"], cwd=tmp, env=env)
                if len(parents) != 1 or listing != f"100644 blob {license_blob}\tLICENSE":
                    raise RuntimeError("Initial GitHub branch is not the expected license-only root commit")
                bootstrap = True
            else:
                previous = latest_public_release(parent, refs, cwd=tmp, env=env)
                if compare_versions(tag, previous) <= 0:
                    raise RuntimeError("Refusing to move GitHub main backwards or reuse a version")
        if parent and not bootstrap:
            tree = project_public_tree(tree, parent, cwd=tmp, env=env)
        message = f"Release {tag}\n\nForgejo-Tag: {tag}\nForgejo-Commit: {commit}\n"
        args = ["commit-tree", tree]
        if parent:
            args.extend(["-p", parent])
        public_commit = run_git(args, cwd=tmp, env=env, input_data=message.encode())
        # An atomic non-force push either advances main and creates the tag together,
        # or fails if another publisher changed either ref.
        run_git(["push", "--quiet", "--atomic", remote,
                 f"{public_commit}:{head_ref}", f"{public_commit}:{tag_ref}"], cwd=tmp, env=env)
        return public_commit


def validate_artifacts(tag, artifact_dir):
    version = tag[1:]
    name = f"Nevermore-{version}-macos-universal.dmg"
    dmg = Path(artifact_dir) / name
    checksum = Path(artifact_dir) / (name + ".sha256")
    data = dmg.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    checksum_data = checksum.read_bytes()
    if checksum_data.decode("utf-8").strip() != f"{digest}  {name}":
        raise RuntimeError("Artifact checksum does not match the DMG")
    return {name: data, checksum.name: checksum_data}


def publish_release(api, tag, commit, notes, artifacts):
    prerelease = "-" in tag
    name = tag
    release = api.get_release(tag)
    if release is None:
        release = api.create_draft(tag, commit, name, notes, prerelease)
    if (release.get("tag_name") != tag or release.get("name") != name or
            release.get("body", "") != notes or release.get("prerelease") != prerelease):
        raise RuntimeError("Existing GitHub release metadata conflicts with Forgejo")
    existing = api.list_assets(release["id"])
    by_name = {}
    for asset in existing:
        if asset["name"] in by_name:
            raise RuntimeError("Duplicate GitHub release asset")
        by_name[asset["name"]] = asset
    if set(by_name) - set(artifacts):
        raise RuntimeError("Existing GitHub release has unexpected assets")
    for name, data in artifacts.items():
        if name not in by_name:
            if not release.get("draft"):
                raise RuntimeError("Published GitHub release is missing an asset")
            by_name[name] = api.upload_asset(release["id"], name, data)
        remote = api.download_asset(by_name[name]["id"])
        if len(remote) != len(data) or hashlib.sha256(remote).digest() != hashlib.sha256(data).digest():
            raise RuntimeError(f"Existing GitHub asset differs: {name}")
    if release.get("draft"):
        api.publish(release["id"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("notes", type=Path)
    parser.add_argument("--allow-license-bootstrap", action="store_true",
                        help="allow a single license-only root commit when bootstrapping")
    args = parser.parse_args()
    token = os.environ.get("MIRROR_TOKEN_GITHUB")
    if not token:
        raise RuntimeError("MIRROR_TOKEN_GITHUB is required")
    parse_version(args.tag)
    artifacts = validate_artifacts(args.tag, args.artifacts)
    notes = args.notes.read_text(encoding="utf-8").rstrip("\n")
    source = Path(run_git(["rev-parse", "--show-toplevel"], cwd=Path.cwd())).resolve()
    commit = publish_snapshot(source, args.tag, token,
                              allow_license_bootstrap=args.allow_license_bootstrap)
    publish_release(GitHubReleaseAPI(REPOSITORY, token), args.tag, commit, notes, artifacts)
    print(f"Published {args.tag} to https://github.com/{REPOSITORY}/releases/tag/{args.tag}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"GitHub mirror failed: {exc}", file=sys.stderr)
        sys.exit(1)
