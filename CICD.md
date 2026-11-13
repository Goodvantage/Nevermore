# CI/CD — Nevermore

Nevermore lives on the Goodvantage forge,
[forge.goodvantage.cloud/Goodvantage/Nevermore](https://forge.goodvantage.cloud/Goodvantage/Nevermore),
and its workflows run on Forgejo Actions from `.forgejo/workflows/`.

## Workflows

| Workflow | Trigger | Runner | Jobs |
|---|---|---|---|
| `ci.yml` — Native Mac checks | push to main, PR, manual | `macos-arm64` + `xcode-current` (mac-mini-1) | Xcode/SDK check, browser-auth self-check, `swift test`, release build, native attachment check, packaging lint |
| `zai-code-review.yml` — GLM 5.3 PR Review | PR events | `pr-review` | automated review (deep GLM + MiMo fast + StepFun fallback) |
| `release.yml` — Release | `v*` tag | mac-mini-1, then `ubuntu-latest` | test the tag, build, sign, notarize and staple the DMG; attach it to the forge release; publish it on apps.goodvantage.cloud |

## Secrets and variables

- Organization secret `ZAI_API_KEY` (required; the review skips without
  it). `MIMO_API_KEY` (fast tier) and `STEPFUN_API_KEY` (fallback) are
  optional; an empty value turns that tier off.
- Organization variable `XCODE_DEVELOPER_DIR` picks the Xcode the macOS
  job uses; without it the job finds one under `/Applications`.
- CI needs no build secrets: it signs ad hoc. These unsigned test builds
  keep the app sandbox but omit Hardened Runtime, whose Team-ID-based
  library validation rejects an ad-hoc Sparkle framework. Builds signed
  with Apple Development or Developer ID retain Hardened Runtime.

## Releases

`scripts/release.sh X.Y.Z --push` bumps `Resources/Info.plist`, tags
`vX.Y.Z` and pushes; the tag runs `release.yml`
(`docs/implementation/OPERATIONS.md` has the details). It needs these
repository secrets, the same Apple credentials GoodDrive uses:

| Secret | Value |
|---|---|
| `MACOS_SIGN_P12_BASE64` | base64 of the Goodvantage "Developer ID Application" certificate and key (.p12) |
| `MACOS_SIGN_P12_PASSWORD` | that .p12's export password |
| `NOTARY_KEY_P8_BASE64` | base64 of the App Store Connect API key (.p8, Developer role, team key) |
| `NOTARY_KEY_ID` | that key's Key ID |
| `NOTARY_ISSUER_ID` | the team's Issuer ID |
| `APPS_SITE_TOKEN` | Nevermore's publishing token for apps.goodvantage.cloud; without it the site step skips with a notice |

Variables, all optional: `APPLE_TEAM_ID` (default `RY935S6RFA`; the
signing identity must belong to it), `APPS_SITE_URL` (default
`https://apps.goodvantage.cloud`), `XCODE_DEVELOPER_DIR`.

The macOS job imports the certificate into a temporary keychain and
removes it, the decoded keys and the build trees when it ends, whatever
the outcome: mac-mini-1 is shared and persistent. A version published on
the site is immutable; re-run the `apps-site` job only for a version no
newer release has replaced.

When a release run fails, re-run its failed jobs, not the whole workflow.
A rebuild is signed and notarized anew, so it is a different file, which
the site refuses for a version it already serves. The forge release
waits for the site job, so the forge keeps the same build as the site.

## Notes

- mac-mini-1 runs jobs directly on the host as the runner account, so
  the macOS job never runs for pull requests from forks, and it removes
  its build trees when it finishes. It needs Xcode 26 or later (the
  macOS 26 SDK). SwiftPM builds with explicit per-arch triples so
  availability matches the packaged app's deployment target.
- SwiftPM runs with `--disable-keychain` in CI, including the app's
  universal build (`CI=true` in `build-app.sh`). All dependencies are
  public, and a LaunchDaemon cannot answer SwiftPM credential prompts.
  The signing keychain used by `codesign` is unaffected.
- The native fixture uses `--user-session`: App Sandbox initialization
  traps before main in the system bootstrap. An owned Aqua LaunchAgent
  runs the complete fixture in the runner's GUI login instead. Background
  agents avoid the startup trap but cannot exercise keyboard focus reliably.
  The runner account must be logged into an unlocked graphical session;
  no UID change, sandbox exemption or CI credentials are passed to the agent.
  The driver bounds the run and unloads its agent; the workflow's final
  cleanup also unloads it if the Python parent was killed. Run the external
  Save As check directly on your Mac with `--save-panel`, not this CI mode.
- The runner is a system LaunchDaemon, so its default keychain is the
  read-only System keychain. The five tests that save tokens to the
  Keychain report themselves as skipped there (`TestKeychain` in
  `Tests/RavenProtocolTests`); run `swift test` on your Mac to cover them.
- Forgejo has no Dependabot: bump the pinned dependencies in
  `Package.swift`/`Package.resolved` and the workflows' action SHAs
  deliberately.
- `scripts/build.sh` is the lkm-build entry point (`--clean`, `--debug`,
  `--run`, `--install`, `--zip`, `--dmg`); it delegates assembly to
  `scripts/build-app.sh` and needs the engine from
  https://github.com/L-K-M/release-tool installed.
- `scripts/publish_app_release.py` is vendored from the site's
  repository (`tools/publish.py`); change it there, then refresh the
  copy as its header describes.
- `scripts/check-live-contracts.py` targets a live Raven server and
  stays out of CI by design.
- The review workflow posts findings as PR comments; a green "GLM 5.3
  PR Review" check means the run finished, not that it found nothing.
